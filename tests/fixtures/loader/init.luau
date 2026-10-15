--!strict
-- Loader fixture: mirrors the shape of src/ to prove Roblox-style requires resolve.
local Nested = require(script.Nested)
local Leaf = require(script.Leaf)

return {
	name = script.Name,
	leaf = Leaf.value,
	deep = Nested.fromDeep,
	nestedParentName = Nested.parentName,
}
