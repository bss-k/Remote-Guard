--!strict
-- script.Parent.Parent climbs out of Nested/ to the fixture root, like Adapters/X does in src/.
local Leaf = require(script.Parent.Parent.Leaf)

return { sibling = "deep+" .. Leaf.value }
