--[[
	Lune test entry point. From the repo root: `lune run tests`

	Runs every `tests/*.spec.luau` file in alphabetical order and exits non-zero on any failure.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local TestKit = require("@self/TestKit")

local specs = {}
for _, entry in fs.readDir("tests") do
	if string.sub(entry, -10) == ".spec.luau" then
		table.insert(specs, string.sub(entry, 1, -6))
	end
end
table.sort(specs)

for _, spec in specs do
	local ok, err = pcall(require, "@self/" .. spec)
	if not ok then
		-- A spec that fails to load counts as a failure instead of hiding the rest of the suite.
		TestKit.it(spec .. " (load)", function()
			error(err, 0)
		end)
	end
end

if not TestKit.summary() then
	process.exit(1)
end
