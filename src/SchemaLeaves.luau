--!strict
--[[
	Compilers for leaf schema kinds (no nested schemas). Each takes a node and returns a
	check closure; everything that can be computed up front (labels, lookup sets, messages)
	is computed here, once, so the per-call closure only compares values.

	Check signature: (value, depth) -> (ok, message?, path?)
	Leaves never return a path; containers in SchemaCompiler prepend theirs.
]]

local Format = require(script.Parent.Format)
local Types = require(script.Parent.Types)

export type Check = (value: any, depth: number) -> (boolean, string?, string?)

export type Compiled = {
	check: Check,
	describe: string, -- short label, used in union reasons ("integer | string")
	optional: boolean, -- accepts nil; used for args arity
	redaction: Types.Redaction?,
}

export type Context = {
	path: string, -- schema path for developer errors ("schema.items[*]")
	sensitive: boolean, -- inside t.sensitive: never echo values in reasons
	top: boolean,
	seen: { [any]: boolean },
	compile: (schema: unknown, ctx: Context) -> Compiled, -- compiles a child schema
}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function leaf(check: Check, describe: string): Compiled
	return { check = check, describe = describe, optional = false, redaction = nil }
end

-- Chooses, once, how the actual value is shown after "got".
local function valueFormatter(ctx: Context): (unknown) -> string
	if ctx.sensitive then
		return function()
			return "<redacted>"
		end
	end
	return Format.value
end

local Leaves = {}

local function compileNumber(node: any, ctx: Context, label: string): Compiled
	local min: number?, max: number? = node.min, node.max
	local integer = label == "integer"
	local got = valueFormatter(ctx)
	local typeMessage = "expected " .. label .. ", got "
	local finiteMessage = "expected finite " .. label .. ", got "
	local rangeMessage = "expected "
		.. label
		.. (if min and max
			then string.format(" in [%s, %s]", Format.number(min), Format.number(max))
			elseif min then " >= " .. Format.number(min)
			elseif max then " <= " .. Format.number(max)
			else "")
		.. ", got "

	return leaf(function(value)
		if type(value) ~= "number" then
			return false, typeMessage .. typeof(value)
		elseif not isFinite(value) then
			return false, finiteMessage .. got(value)
		elseif integer and value ~= math.floor(value) then
			return false, typeMessage .. got(value)
		elseif (min and value < min) or (max and value > max) then
			return false, rangeMessage .. got(value)
		end
		return true
	end, label)
end

function Leaves.number(node: any, ctx: Context): Compiled
	return compileNumber(node, ctx, "number")
end

function Leaves.integer(node: any, ctx: Context): Compiled
	return compileNumber(node, ctx, "integer")
end

function Leaves.string(node: any, _ctx: Context): Compiled
	local maxLen: number, pattern: string? = node.maxLen, node.pattern
	local lengthMessage = string.format("expected string of at most %d bytes, got ", maxLen)
	local patternMessage = if pattern then "expected string matching pattern " .. Format.quote(pattern, 64) else ""

	-- String contents are never echoed back, so sensitive strings need no special case.
	return leaf(function(value)
		if type(value) ~= "string" then
			return false, "expected string, got " .. typeof(value)
		elseif #value > maxLen then
			return false, lengthMessage .. #value .. " bytes"
		elseif pattern then
			local ok, found = pcall(string.find, value, pattern)
			if not ok or found == nil then
				return false, patternMessage
			end
		end
		return true
	end, "string")
end

function Leaves.boolean(_node: any, _ctx: Context): Compiled
	return leaf(function(value)
		if type(value) ~= "boolean" then
			return false, "expected boolean, got " .. typeof(value)
		end
		return true
	end, "boolean")
end

function Leaves.literal(node: any, ctx: Context): Compiled
	local expected = node.value
	local label = Format.value(expected)
	local got = valueFormatter(ctx)
	return leaf(function(value)
		if value ~= expected then
			return false,
				"expected " .. label .. ", got " .. (if typeof(value) == typeof(expected)
					then got(value)
					else typeof(value))
		end
		return true
	end, label)
end

function Leaves.enum(node: any, ctx: Context): Compiled
	local set: { [any]: boolean } = {}
	local shown: { string } = {}
	for i, value in node.values do
		set[value] = true
		if i <= 6 then
			table.insert(shown, Format.value(value))
		end
	end
	local message = "expected one of " .. table.concat(shown, ", ") .. (if #node.values > 6 then ", ..." else "")
	local got = valueFormatter(ctx)
	return leaf(function(value)
		if set[value] ~= true then
			local kind = typeof(value)
			local isPrimitive = kind == "string" or kind == "number" or kind == "boolean"
			return false, message .. ", got " .. (if isPrimitive then got(value) else kind)
		end
		return true
	end, "enum")
end

local function vectorCheck(value: any): (boolean, string?)
	if typeof(value) ~= "Vector3" then
		return false, "expected Vector3, got " .. typeof(value)
	elseif not (isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)) then
		return false, "expected Vector3 with finite components"
	end
	return true
end

function Leaves.vector3(_node: any, _ctx: Context): Compiled
	return leaf(vectorCheck, "Vector3")
end

function Leaves.unitVector3(node: any, _ctx: Context): Compiled
	local tolerance: number = node.tolerance
	local message = "expected unit Vector3 (|magnitude - 1| <= " .. Format.number(tolerance) .. "), got magnitude "
	return leaf(function(value)
		local ok, reason = vectorCheck(value)
		if not ok then
			return false, reason
		end
		local x, y, z = value.X, value.Y, value.Z
		local magnitude = math.sqrt(x * x + y * y + z * z)
		if math.abs(magnitude - 1) > tolerance then
			return false, message .. string.format("%.4g", magnitude)
		end
		return true
	end, "unit Vector3")
end

function Leaves.instance(node: any, _ctx: Context): Compiled
	local className: string?, ancestor: Instance? = node.className, node.descendantOf
	local classMessage = if className then "expected Instance of class " .. className .. ", got " else ""
	local ancestorMessage = if ancestor then "expected Instance inside " .. ancestor.Name else ""
	return leaf(function(value)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance, got " .. typeof(value)
		end
		-- Destroyed instances have a nil Parent; reading it never errors. Only the DataModel
		-- itself is legitimately parentless.
		if value.Parent == nil and value.ClassName ~= "DataModel" then
			return false, "expected Instance that has not been destroyed"
		elseif className and not value:IsA(className) then
			return false, classMessage .. value.ClassName
		elseif ancestor and not value:IsDescendantOf(ancestor) then
			return false, ancestorMessage
		end
		return true
	end, if className then className else "Instance")
end

return Leaves
