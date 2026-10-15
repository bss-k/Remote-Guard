local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq = TestKit.describe, TestKit.it, TestKit.eq

local FIXTURE = "tests/fixtures/loader"

describe("loader", function()
	it("loads the real library root from src/", function()
		local Guard = Loader.new().require()
		eq(type(Guard), "table")
		eq(Guard.version, "0.1.0-dev")
	end)

	it("resolves script.X, script.Parent.X and script.Parent.Parent.X", function()
		local root = Loader.new({ root = FIXTURE, rootName = "Fixture" }).require()
		eq(root.name, "Fixture")
		eq(root.leaf, "leaf")
		eq(root.deep, "deep+leaf")
		eq(root.nestedParentName, "Fixture")
	end)

	it("loads submodules by path and caches them per loader", function()
		local loader = Loader.new({ root = FIXTURE })
		eq(loader.require("Nested/Deep"), loader.require("Nested/Deep"))
		local other = Loader.new({ root = FIXTURE })
		TestKit.truthy(loader.require("Leaf") ~= other.require("Leaf"), "separate loaders share no state")
	end)

	it("reports missing members with Roblox's wording", function()
		TestKit.throws(function()
			Loader.new({ root = FIXTURE }).require("Missing")
		end, "Missing is not a valid member of")
	end)

	it("fails loudly on cyclic requires", function()
		TestKit.throws(function()
			Loader.new({ root = FIXTURE }).require("Cycle")
		end, "cyclic require")
	end)

	it("exposes injected globals and leaves `game` nil by default", function()
		local fakeGame = {}
		local withGame = Loader.new({ root = FIXTURE, globals = { game = fakeGame } }).require("Globals")
		eq(withGame.game, fakeGame)
		TestKit.truthy(withGame.hasTask, "task library injected")
		eq(Loader.new({ root = FIXTURE }).require("Globals").game, nil)
	end)
end)
