--!strict
--[[
	Schema nodes are frozen tables tagged with a PRIVATE marker key. Because the key is a
	unique table rather than a string, a user's plain struct field named "kind" or "type"
	can never be mistaken for a node.
]]

local Types = require(script.Parent.Types)

local MARKER = table.freeze({})

local SchemaNode = {}

function SchemaNode.new(kind: string, params: { [string]: any }): Types.Schema
	local node: { [any]: any } = params
	node[MARKER] = kind
	return table.freeze(node)
end

-- Returns the node's kind ("integer", "struct", ...) or nil if `value` is not a node.
function SchemaNode.kind(value: unknown): string?
	if type(value) ~= "table" then
		return nil
	end
	local kind = rawget(value :: any, MARKER)
	return if type(kind) == "string" then kind else nil
end

return SchemaNode
