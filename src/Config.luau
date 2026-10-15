--!strict
--[[
	Global defaults, config validation and per-remote resolution.

	Three-state rule for every optional per-remote property:
		nil   -> use the Guard.config default
		false -> off
		value -> on, with these settings

	All problems raise developer errors via DevError, which the public API re-raises at
	the user's own line.
]]

local DevError = require(script.Parent.DevError)
local Format = require(script.Parent.Format)
local Schema = require(script.Parent.Schema)
local SchemaNode = require(script.Parent.SchemaNode)
local Types = require(script.Parent.Types)

type GlobalConfig = Types.GlobalConfig
type ResolvedConfig = Types.ResolvedConfig

local REMOTE_KEYS = { "schema", "rate", "mode", "log", "name", "checks", "strikes" }
local GLOBAL_KEYS = { "mode", "rate", "globalRate", "printLevel", "printPayloads", "log", "bypass", "strikes" }
local PRINT_LEVELS = { all = true, violations = true, errors = true, off = true }

local Config = {}

function Config.defaults(): GlobalConfig
	return {
		mode = "shadow",
		rate = false, -- opt-in
		globalRate = false, -- opt-in
		printLevel = "violations",
		printPayloads = nil, -- nil = follow the Studio/live profile
		log = true,
		bypass = nil,
		strikes = false, -- PHASE 2
	}
end

local function isPositive(n: unknown): boolean
	return type(n) == "number" and n > 0 and n ~= math.huge -- also rejects NaN
end

local function makeSet(list: { string }): { [any]: boolean }
	local set = {}
	for _, key in list do
		set[key] = true
	end
	return set
end

local REMOTE_KEY_SET = makeSet(REMOTE_KEYS)
local GLOBAL_KEY_SET = makeSet(GLOBAL_KEYS)

-- Parses a rate value (number shorthand or { perSecond = n }) into perSecond or false.
-- `fail` raises with the right prefix (remote or Guard.config).
local function parseRate(value: unknown, key: string, fail: (string) -> never): number | false
	if value == false then
		return false
	elseif isPositive(value) then
		return value :: number
	elseif type(value) == "table" and getmetatable(value :: any) == nil then
		local rate = value :: { [any]: any }
		if rate.burst ~= nil then
			fail(key .. ".burst was removed; use perSecond (a full bucket holds one second of calls)")
		end
		for k in rate do
			if k ~= "perSecond" then
				fail(key .. "." .. DevError.unknownKey(k, { "perSecond" }))
			end
		end
		if not isPositive(rate.perSecond) then
			fail(key .. ".perSecond must be a positive number, got " .. Format.value(rate.perSecond))
		end
		return rate.perSecond
	end
	return fail(key .. " must be a positive number, { perSecond = number } or false, got " .. Format.value(value))
end

local function checkMode(value: unknown, fail: (string) -> never)
	if value ~= "shadow" and value ~= "enforce" then
		fail('mode must be "shadow" or "enforce", got ' .. Format.value(value))
	end
end

-- Validates Guard.config and returns a normalized copy (nil -> default, rates -> perSecond).
function Config.validateGlobal(global: unknown): GlobalConfig
	local fail = DevError.raiseGlobal
	if type(global) ~= "table" then
		fail("Guard.config must be a table, got " .. typeof(global))
	end
	local g = global :: { [any]: any }
	for key in g do
		if not GLOBAL_KEY_SET[key] then
			fail(DevError.unknownKey(key, GLOBAL_KEYS))
		end
	end
	local defaults = Config.defaults()
	local out: { [string]: any } = {}
	for _, key in GLOBAL_KEYS do
		out[key] = if g[key] == nil then (defaults :: any)[key] else g[key]
	end

	checkMode(out.mode, fail)
	out.rate = parseRate(out.rate, "rate", fail)
	out.globalRate = parseRate(out.globalRate, "globalRate", fail)
	if not PRINT_LEVELS[out.printLevel] then
		fail('printLevel must be "all", "violations", "errors" or "off", got ' .. Format.value(out.printLevel))
	end
	if out.printPayloads ~= nil and type(out.printPayloads) ~= "boolean" then
		fail("printPayloads must be true, false or nil, got " .. Format.value(out.printPayloads))
	end
	if type(out.log) ~= "boolean" then
		fail("log must be a boolean, got " .. Format.value(out.log))
	end
	if out.bypass ~= nil and type(out.bypass) ~= "function" then
		fail("bypass must be a function (player) -> boolean or nil, got " .. typeof(out.bypass))
	end
	if out.strikes ~= false then
		fail("strikes are not available yet (they arrive in a later version); leave strikes = false")
	end
	return out :: any
end

-- Merges one remote's config with the validated global config.
-- `defaultName` is the transport's name, used when config.name is not set.
function Config.resolve(remoteConfig: unknown, global: GlobalConfig, defaultName: string): ResolvedConfig
	local name = defaultName
	if type(remoteConfig) == "table" and type((remoteConfig :: any).name) == "string" then
		name = (remoteConfig :: any).name
	end
	local function fail(message: string): never
		DevError.raise(name, message)
	end

	if remoteConfig == nil then
		remoteConfig = {}
	elseif SchemaNode.kind(remoteConfig) ~= nil then
		fail("the config argument is a schema; pass it as { schema = ... }")
	elseif type(remoteConfig) ~= "table" or getmetatable(remoteConfig :: any) ~= nil then
		fail("config must be a table, got " .. typeof(remoteConfig))
	end
	local c = remoteConfig :: { [any]: any }
	for key in c do
		if not REMOTE_KEY_SET[key] then
			fail(DevError.unknownKey(key, REMOTE_KEYS))
		end
	end

	if c.name ~= nil and (type(c.name) ~= "string" or c.name == "") then
		fail("name must be a non-empty string, got " .. Format.value(c.name))
	end
	if c.mode ~= nil then
		checkMode(c.mode, fail)
	end
	if c.log ~= nil and type(c.log) ~= "boolean" then
		fail("log must be a boolean, got " .. Format.value(c.log))
	end
	if c.schema ~= nil and c.schema ~= false and type(c.schema) ~= "table" then
		fail("schema must be a schema (e.g. { id = t.integer() }) or false, got " .. typeof(c.schema))
	end
	if c.checks ~= nil and c.checks ~= false then
		fail("checks are not available yet (they arrive in a later version); remove the checks key")
	end
	if c.strikes ~= nil and c.strikes ~= false then
		fail("strikes are not available yet (they arrive in a later version); remove the strikes key")
	end

	return {
		name = name,
		mode = if c.mode ~= nil then c.mode else global.mode,
		schema = if c.schema then c.schema else false,
		rate = if c.rate ~= nil then parseRate(c.rate, "rate", fail) else global.rate :: number | false,
		-- Global features have no per-remote override yet; they come straight from Guard.config.
		globalRate = global.globalRate :: number | false,
		bypass = global.bypass or false,
		checks = false, -- PHASE 3
		strikes = false, -- PHASE 2
		log = if c.log ~= nil then c.log else global.log,
	}
end

-- Compiles the schema, turning a malformed definition into a developer error.
function Config.compileSchema(schema: Types.Schema, remoteName: string): (Types.Validator, Types.SchemaInfo)
	local ok, validator, info = pcall(Schema.compile, schema)
	if not ok then
		-- Compile messages already start with the schema path ("schema.items[*]: ...").
		DevError.raise(remoteName, tostring(validator))
	end
	return validator, info
end

function Config.checkHandler(handler: unknown, remoteName: string)
	if type(handler) ~= "function" then
		DevError.raise(
			remoteName,
			"missing handler: expected a function (player, ...) as the last argument, got " .. typeof(handler)
		)
	end
end

return Config
