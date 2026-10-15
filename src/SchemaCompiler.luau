--!strict
--[[
	Turns a schema definition into nested check closures, once, at wrap time.

	This module dispatches on node kind and normalizes plain-table shorthand (a table of
	string keys is a strict struct). The per-kind work lives in SchemaLeaves and
	SchemaContainers. Per call, only the returned closures run.
]]

local Format = require(script.Parent.Format)
local SchemaContainers = require(script.Parent.SchemaContainers)
local SchemaLeaves = require(script.Parent.SchemaLeaves)
local SchemaNode = require(script.Parent.SchemaNode)
local Types = require(script.Parent.Types)

type Compiled = SchemaLeaves.Compiled
type Context = SchemaLeaves.Context

local SchemaCompiler = {}

-- Compile-time errors carry the schema path; Config adds the remote name and caller line.
local function devError(ctx: Context, message: string): never
	error(ctx.path .. ": " .. message, 0)
end

-- A plain table without the marker is shorthand for a strict struct of string keys.
local function normalize(value: { [any]: any }, ctx: Context): Types.Schema
	if getmetatable(value) ~= nil then
		devError(ctx, "expected a schema, got a table with a metatable")
	end
	for key in value do
		if type(key) == "number" then
			devError(
				ctx,
				"a plain list is not a schema; use t.array(schema) for a list or t.args(a, b) for positional arguments"
			)
		elseif type(key) ~= "string" then
			devError(ctx, "struct keys must be strings, got " .. typeof(key))
		end
	end
	return SchemaNode.new("struct", { fields = value, strict = true })
end

local function compileAny(schema: unknown, ctx: Context): Compiled
	local kind = SchemaNode.kind(schema)
	local node: any = schema
	if kind == nil then
		if type(schema) == "function" then
			devError(ctx, "expected a schema, got a function (combinators must be called, e.g. t.integer())")
		elseif type(schema) ~= "table" then
			devError(ctx, "expected a schema, got " .. typeof(schema))
		end
		node = normalize(schema :: any, ctx)
		kind = "struct"
	end
	if ctx.seen[schema] then
		devError(ctx, "schema contains itself")
	end
	ctx.seen[schema] = true
	local compiler = (SchemaContainers :: any)[kind] or (SchemaLeaves :: any)[kind]
	local compiled = compiler(node, ctx)
	ctx.seen[schema] = nil
	return compiled
end

function SchemaCompiler.compile(schema: Types.Schema): (Types.Validator, Types.SchemaInfo)
	local compiled = compileAny(schema, {
		path = "schema",
		sensitive = false,
		top = true,
		seen = {},
		compile = compileAny,
	})
	local check = compiled.check
	local function validator(value: unknown, depth: number?): (boolean, string?)
		local ok, message, path = check(value, depth or 0)
		if ok then
			return true, nil
		end
		return false, Format.withPath(path, message or "invalid value")
	end
	return validator :: Types.Validator, { args = SchemaNode.kind(schema) == "args", redaction = compiled.redaction }
end

return SchemaCompiler
