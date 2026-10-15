--!strict
--[[
	RemoteGuard: a drop-in, server-side guard for Roblox remotes.

		Guard.event(remote, handler)
		Guard.event(remote, { schema = { id = t.integer(1, 100) }, rate = 5, mode = "enforce" }, handler)

	Not a network library: it does no serialization or batching. It sits in front of your
	handlers and decides which calls get through. Every call passes one pipeline:
	adapter -> [bypass] -> [rate] -> [globalRate] -> [schema] -> handler (xpcall).

	Roblox services are only touched lazily (first wrap / first print), never at require.
]]

local Config = require(script.Config)
local Console = require(script.Sinks.Console)
local DevError = require(script.DevError)
local Logger = require(script.Logger)
local Pipeline = require(script.Pipeline)
local Printer = require(script.Printer)
local RateLimiter = require(script.RateLimiter)
local RemoteEventAdapter = require(script.Adapters.RemoteEvent)
local Schema = require(script.Schema)
local Types = require(script.Types)

export type Schema = Types.Schema
export type RemoteConfig = Types.RemoteConfig
export type GlobalConfig = Types.GlobalConfig
export type Event = Types.Event
export type Sink = Types.Sink
export type Adapter = Types.Adapter
export type Connection = Types.Connection

local THROTTLE_WINDOW = 10
local PRINT_LEVELS = { all = true, violations = true, errors = true, off = true }

local Guard = {}

Guard.version = Types.VERSION
Guard.t = Schema.t
-- Global defaults. Change fields before wrapping; they are validated on every wrap.
Guard.config = Config.defaults()
Guard.adapters = table.freeze({ RemoteEvent = RemoteEventAdapter })

-- Lazily resolved Roblox environment --------------------------------------------

local isStudioCached: boolean? = nil
local function isStudio(): boolean
	if isStudioCached == nil then
		isStudioCached = game:GetService("RunService"):IsStudio()
	end
	return isStudioCached :: boolean
end

local function serverId(): string
	return if game.JobId ~= "" then game.JobId else "studio"
end

-- Logging ------------------------------------------------------------------------

local printer = Printer.new({
	isStudio = isStudio,
	throttleWindow = THROTTLE_WINDOW,
	settings = function()
		-- Read live; an invalid value falls back to the default instead of going silent.
		local level = Guard.config.printLevel
		local payloads = Guard.config.printPayloads
		return if PRINT_LEVELS[level] then level else "violations",
			if type(payloads) == "boolean" then payloads else nil
	end,
})

local logger = Logger.new({
	onSinkError = function(name: string, message: string)
		printer:sinkError(name, message)
	end,
})

local consoleSink = Console.new({ printer = printer, flushDelay = THROTTLE_WINDOW })
logger:addSink(consoleSink)

Guard.sinks = table.freeze({ Console = consoleSink })

-- Accepts both Guard.logger.addSink(sink) and Guard.logger:addSink(sink).
local function loggerMethod<A, R>(fn: (any, A) -> R): (...any) -> R
	return function(...: any): R
		local first, second = ...
		local arg = if first == Guard.logger then second else first
		return DevError.boundary(2, fn, logger, arg)
	end
end

Guard.logger = table.freeze({
	addSink = loggerMethod(logger.addSink),
	removeSink = loggerMethod(logger.removeSink),
	getRecent = loggerMethod(logger.getRecent),
})

-- Wrapping -----------------------------------------------------------------------

local limiter = RateLimiter.new()
-- Weak keys: a destroyed, never-disconnected remote does not stay alive because of us.
local registry: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local playerRemovingConnected = false

local function connectPlayerRemoving()
	if playerRemovingConnected then
		return
	end
	playerRemovingConnected = true
	game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
		limiter:removePlayer(player)
	end)
end

local function checkAdapter(adapter: unknown)
	local a = adapter :: any
	if
		type(a) ~= "table"
		or type(a.name) ~= "string"
		or type(a.validate) ~= "function"
		or type(a.connect) ~= "function"
		or type(a.getName) ~= "function"
	then
		DevError.raise(nil, "invalid adapter: expected { name, validate, connect, getName } (see docs/adapters.md)")
	end
end

local function wrap(transport: unknown, adapter: Adapter, config: RemoteConfig?, handler: unknown): Connection
	checkAdapter(adapter)
	local valid, why = adapter.validate(transport)
	if not valid then
		DevError.raise(nil, string.format("invalid transport for the %s adapter: %s", adapter.name, why or "rejected"))
	end
	local transportName = adapter.getName(transport)
	if registry[transport] then
		DevError.raise(
			transportName,
			"this "
				.. adapter.name
				.. " is already wrapped; call Disconnect() on the first connection before wrapping it again"
		)
	end

	local resolved = Config.resolve(config, Config.validateGlobal(Guard.config), transportName)
	Config.checkHandler(handler, resolved.name)
	local validator, schemaInfo = nil, nil
	if resolved.schema then
		validator, schemaInfo = Config.compileSchema(resolved.schema, resolved.name)
	end

	connectPlayerRemoving()
	local key = table.freeze({}) -- unique bucket key, so two remotes with the same Name never share buckets
	local onCall = Pipeline.build(resolved, handler :: (Player, ...any) -> (), {
		limiter = limiter,
		logger = logger,
		remoteName = resolved.name,
		transportName = adapter.name,
		key = key,
		validator = validator,
		schemaInfo = schemaInfo,
		serverId = serverId(),
		logCalls = function()
			return Guard.config.printLevel == "all"
		end,
		onInternalError = function(message: string, traceback: string)
			printer:internalError(message, traceback)
		end,
	})

	local inner = adapter.connect(transport, onCall)
	registry[transport] = true

	local connected = true
	local connection = {}
	function connection.Disconnect(_self: Connection)
		if not connected then
			return
		end
		connected = false
		inner:Disconnect()
		registry[transport] = nil
		limiter:removeKey(key)
	end
	return connection :: Connection
end

-- Generic entry point: guards any transport through its adapter.
function Guard.wrap(
	transport: any,
	adapter: Adapter,
	config: RemoteConfig?,
	handler: (Player, ...any) -> ()
): Connection
	return DevError.boundary(2, wrap, transport, adapter, config, handler)
end

-- Guards a RemoteEvent. `config` may be omitted: Guard.event(remote, handler).
function Guard.event(
	remote: RemoteEvent,
	config: RemoteConfig | ((Player, ...any) -> ()) | nil,
	handler: ((Player, ...any) -> ())?
): Connection
	if handler == nil and type(config) == "function" then
		handler, config = config, nil
	end
	return DevError.boundary(2, wrap, remote, RemoteEventAdapter, config :: RemoteConfig?, handler)
end

-- Unstable, for tests and debugging only.
Guard._internal = table.freeze({
	countBuckets = function(): number
		return limiter:countBuckets()
	end,
})

return Guard
