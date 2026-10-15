--!strict
--[[
	Compilers for container schema kinds (optional, sensitive, array, struct, union, args).
	Each precomputes path segments, key sets and messages, then returns a check closure that
	calls its children's closures. Children are compiled through `ctx.compile`, which
	SchemaCompiler provides, so this module never re-walks the definition per call.

	Per-call work is bounded: depth is capped at 8, arrays stop after maxLen + 1 keys, and
	strict structs stop at the first unknown key.
]]

local Format = require(script.Parent.Format)
local SchemaLeaves = require(script.Parent.SchemaLeaves)
local Types = require(script.Parent.Types)

type Check = SchemaLeaves.Check
type Compiled = SchemaLeaves.Compiled
type Context = SchemaLeaves.Context

local MAX_DEPTH = 8

-- Compile-time errors carry the schema path; Config adds the remote name and caller line.
local function devError(ctx: Context, message: string): never
	error(ctx.path .. ": " .. message, 0)
end

local function child(ctx: Context, suffix: string, sensitive: boolean?): Context
	return {
		path = ctx.path .. suffix,
		sensitive = sensitive or ctx.sensitive,
		top = false,
		seen = ctx.seen,
		compile = ctx.compile,
	}
end

-- Shared table checks for array and struct. Returns the child depth, or nil + reason.
local function enterTable(value: any, depth: number, label: string): (number?, string?)
	if type(value) ~= "table" then
		return nil, "expected " .. label .. ", got " .. typeof(value)
	elseif getmetatable(value) ~= nil then
		return nil, "expected " .. label .. ", got table with a metatable"
	elseif depth + 1 > MAX_DEPTH then
		return nil, string.format("table nested deeper than %d levels", MAX_DEPTH)
	end
	return depth + 1
end

local Containers = {}

function Containers.optional(node: any, ctx: Context): Compiled
	local inner = ctx.compile(node.schema, child(ctx, ""))
	local check = inner.check
	return {
		check = function(value, depth)
			if value == nil then
				return true
			end
			return check(value, depth)
		end,
		describe = inner.describe .. "?",
		optional = true,
		redaction = inner.redaction,
	}
end

function Containers.sensitive(node: any, ctx: Context): Compiled
	local inner = ctx.compile(node.schema, child(ctx, "", true))
	return { check = inner.check, describe = inner.describe, optional = inner.optional, redaction = true }
end

function Containers.array(node: any, ctx: Context): Compiled
	local element = ctx.compile(node.schema, child(ctx, "[*]"))
	local check, maxLen = element.check, node.maxLen :: number
	local tooLong = string.format("expected array of at most %d elements", maxLen)
	return {
		check = function(value, depth)
			local inner, reason = enterTable(value, depth, "array")
			if inner == nil then
				return false, reason
			end
			-- Bounded: stops after maxLen + 1 keys no matter how big the table is.
			local count, highest = 0, 0
			for key in next, value do
				count += 1
				if count > maxLen then
					return false, tooLong
				elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
					return false, "expected array, got table with key " .. Format.keySegment(key)
				end
				highest = math.max(highest, key)
			end
			if highest ~= count then
				return false, "expected array without gaps"
			end
			for i = 1, count do
				local ok, message, path = check(value[i], inner)
				if not ok then
					return false, message, "[" .. i .. "]" .. (path or "")
				end
			end
			return true
		end,
		describe = "array",
		optional = false,
		redaction = if element.redaction then { each = element.redaction } else nil,
	}
end

function Containers.struct(node: any, ctx: Context): Compiled
	local keys: { string } = {}
	for key in node.fields do
		if type(key) ~= "string" then
			devError(ctx, "struct keys must be strings, got " .. typeof(key))
		end
		table.insert(keys, key)
	end
	table.sort(keys) -- stable field order, so the first reported failure is deterministic

	local known: { [any]: boolean } = {}
	local fields: { { key: string, segment: string, check: Check } } = {}
	local redactions: { [any]: Types.Redaction }? = nil
	for _, key in keys do
		local segment = Format.keySegment(key)
		local compiled = ctx.compile(node.fields[key], child(ctx, segment))
		known[key] = true
		table.insert(fields, { key = key, segment = segment, check = compiled.check })
		if compiled.redaction then
			redactions = redactions or {}
			redactions[key] = compiled.redaction
		end
	end

	local strict = node.strict ~= false
	return {
		check = function(value, depth)
			local inner, reason = enterTable(value, depth, "table")
			if inner == nil then
				return false, reason
			end
			for _, field in fields do
				local ok, message, path = field.check(rawget(value, field.key), inner)
				if not ok then
					return false, message, field.segment .. (path or "")
				end
			end
			if strict then
				-- Bounded: every key is known (at most #fields) or we return on the first unknown one.
				for key in next, value do
					if not known[key] then
						return false, "unexpected key", Format.keySegment(key)
					end
				end
			end
			return true
		end,
		describe = "table",
		optional = false,
		redaction = if redactions then { fields = redactions } else nil,
	}
end

function Containers.union(node: any, ctx: Context): Compiled
	local checks: { Check } = {}
	local labels: { string } = {}
	local redacted = false
	for i, schema in node.schemas do
		local compiled = ctx.compile(schema, child(ctx, "(union option " .. i .. ")"))
		table.insert(checks, compiled.check)
		table.insert(labels, compiled.describe)
		redacted = redacted or compiled.redaction ~= nil
	end
	local message = "expected " .. table.concat(labels, " | ") .. ", got "
	return {
		check = function(value, depth)
			for _, check in checks do
				if check(value, depth) then
					return true
				end
			end
			return false, message .. typeof(value)
		end,
		describe = table.concat(labels, " | "),
		optional = false,
		-- Any sensitive option redacts the whole value: we can't tell which option matched.
		redaction = if redacted then true else nil,
	}
end

function Containers.args(node: any, ctx: Context): Compiled
	if not ctx.top then
		devError(ctx, "t.args(...) can only be used as the whole schema, not nested inside another schema")
	end
	local checks: { Check } = {}
	local segments: { string } = {}
	local redactions: { [any]: Types.Redaction }? = nil
	local required = 0
	for i, schema in node.schemas do
		local segment = "argument " .. i
		local compiled = ctx.compile(schema, child(ctx, "(" .. segment .. ")"))
		checks[i], segments[i] = compiled.check, segment
		if not compiled.optional then
			required = i -- trailing optional arguments may be omitted
		end
		if compiled.redaction then
			redactions = redactions or {}
			redactions[i] = compiled.redaction
		end
	end
	local max = #checks
	local function plural(n: number): string
		return if n == 1 then "1 argument" else n .. " arguments"
	end
	local expected = if required == max then plural(max) else string.format("%d to %s", required, plural(max))
	return {
		check = function(packed, _depth)
			local n = if type(packed) == "table" then rawget(packed, "n") else nil
			if type(n) ~= "number" then
				return false, "expected packed arguments"
			elseif n < required or n > max then
				return false, "expected " .. expected .. ", got " .. n
			end
			for i, check in checks do
				local ok, message, path = check(packed[i], 0)
				if not ok then
					return false, message, segments[i] .. (path or "")
				end
			end
			return true
		end,
		describe = "arguments",
		optional = false,
		redaction = if redactions then { fields = redactions } else nil,
	}
end

return Containers
