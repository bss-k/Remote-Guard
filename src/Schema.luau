--!strict
--[[
	Schema combinators (exposed as Guard.t) and the internal compile entry point.

	Combinators only check their own arguments and build frozen nodes. All structural work
	(normalizing plain tables, nested checks, closures) happens once in SchemaCompiler.
]]

local SchemaCompiler = require(script.Parent.SchemaCompiler)
local SchemaNode = require(script.Parent.SchemaNode)
local Types = require(script.Parent.Types)

type Schema = Types.Schema

local new = SchemaNode.new

-- Raised from inside a combinator: level 3 points at the user's `t.x(...)` call.
local function devError(name: string, message: string): never
	error(string.format("[RemoteGuard] t.%s: %s", name, message), 3)
end

local function isFinite(n: unknown): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isCount(n: unknown): boolean
	return isFinite(n) and (n :: number) >= 0 and (n :: number) == math.floor(n :: number)
end

local function isLiteral(value: unknown): boolean
	return type(value) == "string" or type(value) == "boolean" or isFinite(value)
end

local function checkBounds(name: string, min: unknown, max: unknown)
	if min ~= nil and not isFinite(min) then
		devError(name, "min must be a finite number or nil, got " .. tostring(min))
	end
	if max ~= nil and not isFinite(max) then
		devError(name, "max must be a finite number or nil, got " .. tostring(max))
	end
	if min ~= nil and max ~= nil and (min :: number) > (max :: number) then
		devError(name, string.format("min (%s) must not be greater than max (%s)", tostring(min), tostring(max)))
	end
end

local function checkList(name: string, list: unknown, what: string): { any }
	if type(list) ~= "table" or getmetatable(list :: any) ~= nil then
		devError(name, "expected a list of " .. what .. ", got " .. typeof(list))
	end
	local items = list :: { any }
	local count = 0
	for _ in items do
		count += 1
	end
	if count == 0 then
		devError(name, "needs at least one " .. string.sub(what, 1, -2))
	elseif count ~= #items then
		devError(name, "expected a list (array) of " .. what)
	end
	return items
end

local t = {}

function t.number(min: number?, max: number?): Schema
	checkBounds("number", min, max)
	return new("number", { min = min, max = max })
end

function t.integer(min: number?, max: number?): Schema
	checkBounds("integer", min, max)
	return new("integer", { min = min, max = max })
end

function t.string(maxLen: number?, pattern: string?): Schema
	if maxLen ~= nil and not isCount(maxLen) then
		devError("string", "maxLen must be a non-negative integer, got " .. tostring(maxLen))
	end
	if pattern ~= nil then
		if type(pattern) ~= "string" then
			devError("string", "pattern must be a string, got " .. typeof(pattern))
		end
		local ok, err = pcall(string.find, "", pattern)
		if not ok then
			devError("string", "invalid pattern " .. string.format("%q", pattern) .. ": " .. tostring(err))
		end
	end
	return new("string", { maxLen = maxLen or 256, pattern = pattern })
end

function t.boolean(): Schema
	return new("boolean", {})
end

-- Escape hatch for a deliberately flexible value: accepts anything, including nil, and
-- checks nothing (no type, size or depth limits). Validate it yourself in the handler.
function t.any(): Schema
	return new("any", {})
end

function t.literal(value: string | number | boolean): Schema
	if not isLiteral(value) then
		devError("literal", "value must be a string, boolean or finite number, got " .. typeof(value))
	end
	return new("literal", { value = value })
end

function t.enum(values: { string | number | boolean }): Schema
	local items = checkList("enum", values, "values")
	for i, value in items do
		if not isLiteral(value) then
			devError("enum", string.format("value %d must be a string, boolean or finite number", i))
		end
	end
	return new("enum", { values = table.clone(items) })
end

function t.vector3(): Schema
	return new("vector3", {})
end

function t.unitVector3(tolerance: number?): Schema
	if tolerance ~= nil and not (isFinite(tolerance) and (tolerance :: number) >= 0) then
		devError("unitVector3", "tolerance must be a non-negative number, got " .. tostring(tolerance))
	end
	return new("unitVector3", { tolerance = tolerance or 0.01 })
end

function t.instance(className: string?, descendantOf: Instance?): Schema
	if className ~= nil and (type(className) ~= "string" or className == "") then
		devError("instance", "className must be a non-empty string or nil")
	end
	if descendantOf ~= nil and typeof(descendantOf) ~= "Instance" then
		devError("instance", "descendantOf must be an Instance or nil, got " .. typeof(descendantOf))
	end
	return new("instance", { className = className, descendantOf = descendantOf })
end

function t.optional(schema: Schema): Schema
	if schema == nil then
		devError("optional", "expected a schema, got nil")
	end
	return new("optional", { schema = schema })
end

function t.array(elementSchema: Schema, maxLen: number?): Schema
	if elementSchema == nil then
		devError("array", "expected an element schema, got nil")
	end
	if maxLen ~= nil and not isCount(maxLen) then
		devError("array", "maxLen must be a non-negative integer, got " .. tostring(maxLen))
	end
	return new("array", { schema = elementSchema, maxLen = maxLen or 100 })
end

function t.struct(fields: { [string]: Schema }, options: { strict: boolean? }?): Schema
	if type(fields) ~= "table" or SchemaNode.kind(fields) ~= nil then
		devError("struct", "fields must be a plain table of name = schema, got " .. typeof(fields))
	end
	local strict = true
	if options ~= nil then
		if type(options) ~= "table" then
			devError("struct", "options must be a table, got " .. typeof(options))
		end
		for key, value in options :: any do
			if key ~= "strict" then
				devError("struct", "unknown option " .. tostring(key) .. " (valid: strict)")
			elseif type(value) ~= "boolean" then
				devError("struct", "options.strict must be a boolean")
			end
		end
		strict = options.strict ~= false
	end
	return new("struct", { fields = table.clone(fields), strict = strict })
end

function t.union(schemas: { Schema }): Schema
	return new("union", { schemas = table.clone(checkList("union", schemas, "schemas")) })
end

function t.args(...: Schema): Schema
	local count = select("#", ...)
	local schemas = { ... }
	for i = 1, count do
		if schemas[i] == nil then
			devError("args", string.format("argument %d is nil (use t.optional(...) for optional arguments)", i))
		end
	end
	return new("args", { schemas = schemas })
end

function t.sensitive(schema: Schema): Schema
	if schema == nil then
		devError("sensitive", "expected a schema, got nil")
	end
	return new("sensitive", { schema = schema })
end

local Schema = {}

Schema.t = table.freeze(t)

-- INTERNAL. Runs once at wrap time. Raises a plain message (no prefix) on a malformed
-- schema; Config adds the remote name and the caller's line.
function Schema.compile(schema: Schema): (Types.Validator, Types.SchemaInfo)
	return SchemaCompiler.compile(schema)
end

return Schema
