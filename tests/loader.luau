--[[
	Test loader: runs the library's Roblox-style source under Lune, unchanged.

	src/ uses idiomatic `require(script.Parent.X)`. Lune has no DataModel, so this loader:

	  1. Walks a source folder with Rojo's rules and builds a tree of lightweight "script"
	     nodes (`init.luau` turns a folder into a module, `X.luau` becomes a child named X).
	  2. Loads each module with `luau.load`, giving it an environment where `script` is its
	     node, `require` accepts nodes, `task` is Lune's task library, and any extra globals
	     the test passes (e.g. a fake `game`) are visible.

	Each `Loader.new()` has its own module cache, so every test can start from clean state.
	See tests/README.md.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

type NodeData = {
	name: string,
	path: string?, -- nil for plain folders
	parent: any,
	children: { [string]: any },
}

-- Node -> data lives outside the node so a module can never read or forge loader internals.
local nodeData: { [any]: NodeData } = setmetatable({}, { __mode = "k" }) :: any

local nodeMeta = {}

function nodeMeta.__index(node: any, key: string): any
	local data = nodeData[node]
	if key == "Name" then
		return data.name
	elseif key == "Parent" then
		return data.parent
	end
	local child = data.children[key]
	if child == nil then
		-- Same wording as Roblox, so a typo in a require fails the same way in both places.
		error(string.format("%s is not a valid member of %s", tostring(key), data.name), 2)
	end
	return child
end

function nodeMeta.__tostring(node: any): string
	return nodeData[node].name
end

local function newNode(name: string, path: string?, parent: any): any
	local node = setmetatable({}, nodeMeta)
	nodeData[node] = { name = name, path = path, parent = parent, children = {} }
	if parent ~= nil then
		nodeData[parent].children[name] = node
	end
	return node
end

local function buildDirectory(dirPath: string, name: string, parent: any): any
	local initPath = dirPath .. "/init.luau"
	local node = newNode(name, if fs.isFile(initPath) then initPath else nil, parent)
	local entries = fs.readDir(dirPath)
	table.sort(entries)
	for _, entry in entries do
		local entryPath = dirPath .. "/" .. entry
		if fs.isDir(entryPath) then
			buildDirectory(entryPath, entry, node)
		elseif entry ~= "init.luau" and string.sub(entry, -5) == ".luau" then
			newNode(string.sub(entry, 1, -6), entryPath, node)
		end
	end
	return node
end

export type Options = {
	root: string?, -- source folder, default "src"
	rootName: string?, -- name of the root module, default "RemoteGuard"
	globals: { [string]: any }?, -- extra globals for every module, e.g. { game = fakeGame }
}

export type Loader = {
	require: (relative: string?) -> any,
}

local Loader = {}

function Loader.new(options: Options?): Loader
	local opts: Options = options or {}
	-- The root gets a parent so `script.Parent` at the top level behaves like a real container.
	local container = newNode("ServerScriptService", nil, nil)
	local root = buildDirectory(opts.root or "src", opts.rootName or "RemoteGuard", container)
	local cache: { [any]: any } = {}
	local loading: { [any]: boolean } = {}

	local function requireNode(node: any): any
		local data = nodeData[node]
		if data == nil then
			error("loader: require expects a module script, got " .. typeof(node), 2)
		end
		if cache[node] ~= nil then
			return cache[node]
		end
		local path = data.path
		if path == nil then
			error("loader: " .. data.name .. " is a folder, not a module", 2)
		end
		if loading[node] then
			-- Roblox reports this too; failing loudly here keeps the two environments in sync.
			error("loader: cyclic require of " .. path, 2)
		end

		local env: { [string]: any } = { script = node, require = requireNode, task = task }
		for key, value in opts.globals or {} do
			env[key] = value
		end

		loading[node] = true
		local ok, result = pcall(function()
			return luau.load(fs.readFile(path), { debugName = path, environment = env })()
		end)
		loading[node] = nil
		if not ok then
			error(result, 0)
		end
		if result == nil then
			error("loader: " .. path .. " did not return a value", 2)
		end
		cache[node] = result
		return result
	end

	local loader = {}

	-- `loader.require()` returns the root module; `loader.require("Adapters/RemoteEvent")` a submodule.
	function loader.require(relative: string?): any
		local node = root
		if relative ~= nil then
			for part in string.gmatch(relative, "[^/]+") do
				node = node[part]
			end
		end
		return requireNode(node)
	end

	return loader
end

return Loader
