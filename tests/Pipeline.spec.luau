local task = require("@lune/task")
local Fakes = require("./Fakes")
local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, truthy, contains, notContains =
	TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.contains, TestKit.notContains

local lib = Loader.new()
local Config = lib.require("Config")
local Pipeline = lib.require("Pipeline")
local RateLimiter = lib.require("RateLimiter")
local t = lib.require("Schema").t

type Options = {
	global: { [string]: any }?,
	limiter: any?,
	logCalls: boolean?,
}

-- Builds a pipeline exactly as Guard.wrap will (resolve -> compile -> build) and connects it
-- to a mock transport. Returns a `fire(player, ...)` function and what it recorded.
local function setup(config: any, handler: any, options: Options?)
	local opts: Options = options or {}
	local global = Config.defaults()
	for k, v in opts.global or {} do
		(global :: any)[k] = v
	end
	local resolved = Config.resolve(config, Config.validateGlobal(global), "Attack")
	local validator, info
	if resolved.schema then
		validator, info = Config.compileSchema(resolved.schema, resolved.name)
	end
	local logger = Fakes.logger()
	local internal = {}
	local onCall, names = Pipeline.build(resolved, handler, {
		limiter = opts.limiter or RateLimiter.new({
			clock = function()
				return 0
			end,
		}),
		logger = logger,
		remoteName = resolved.name,
		transportName = "Mock",
		key = {},
		validator = validator,
		schemaInfo = info,
		serverId = "server-1",
		now = function()
			return 42
		end,
		logCalls = function()
			return opts.logCalls == true
		end,
		onInternalError = function(message, traceback)
			table.insert(internal, { message = message, traceback = traceback })
		end,
	})
	local transport = Fakes.transport("Attack")
	Fakes.MockAdapter.connect(transport, onCall)
	local function fire(player: any, ...: any)
		Fakes.fire(transport, player, ...)
	end
	return fire, logger.events, names, internal
end

-- A handler that records every call's arguments.
local function recorder()
	local calls = {}
	return function(player, ...)
		table.insert(calls, { player = player, args = table.pack(...) })
	end, calls
end

-- A limiter that fails the test if any stage touches it.
local untouchable = setmetatable({}, {
	__index = function()
		error("limiter should not be used")
	end,
})

local alice = Fakes.player("Alice", 1)

describe("Pipeline", function()
	describe("stage list", function()
		it("an empty config has no stages and passes the original arguments", function()
			local handler, calls = recorder()
			local fire, events, names = setup({}, handler, { limiter = untouchable })
			eq(#names, 0)
			fire(alice, 1, "two", nil)
			eq(#calls, 1)
			eq(calls[1].player, alice)
			eq(calls[1].args.n, 3)
			eq(calls[1].args[2], "two")
			eq(#events, 0)
		end)

		it("includes only enabled stages, cheapest first", function()
			local _, _, names = setup({ rate = 5, schema = { id = t.integer() } }, function() end, {
				global = {
					globalRate = 30,
					bypass = function()
						return false
					end,
				},
			})
			eq(table.concat(names, ","), "bypass,rate+globalRate,schema")
			local _, _, rateOnly = setup({ rate = 5 }, function() end)
			eq(table.concat(rateOnly, ","), "rate")
			local _, _, globalOnly = setup({}, function() end, { global = { globalRate = 30 } })
			eq(table.concat(globalOnly, ","), "globalRate")
			local _, _, off = setup({ rate = false }, function() end, { global = { rate = 10 } })
			eq(#off, 0, "per-remote false turns a global default off")
		end)
	end)

	describe("enforce vs shadow", function()
		it("enforce drops the call and logs one event", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() }, mode = "enforce" }, handler)
			fire(alice, { id = "5" })
			eq(#calls, 0)
			eq(#events, 1)
			eq(events[1].reason, "id: expected integer, got string")
		end)

		it("shadow logs and still runs the handler with the raw data", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() } }, handler)
			local raw = { id = "5" }
			fire(alice, raw)
			eq(#calls, 1)
			eq(calls[1].args[1], raw)
			eq(events[1].mode, "shadow")
		end)

		it("shadow keeps running stages so every violation is logged", function()
			local handler, calls = recorder()
			local fire, events = setup({ rate = 1, schema = { id = t.integer() } }, handler)
			fire(alice, { id = 1 })
			fire(alice, { id = "x" }) -- over the rate AND bad schema
			eq(#calls, 2)
			eq(#events, 2)
			eq(events[1].violation, "RateLimit")
			eq(events[2].violation, "Schema")
		end)

		it("enforce stops at the first failing stage", function()
			local handler, calls = recorder()
			local fire, events = setup({ rate = 1, schema = { id = t.integer() }, mode = "enforce" }, handler)
			fire(alice, { id = 1 })
			fire(alice, { id = "x" })
			eq(#calls, 1)
			eq(#events, 1)
			eq(events[1].violation, "RateLimit")
			eq(events[1].reason, "exceeded 1 calls/s")
		end)

		it("reports global limit failures with their own type", function()
			local fire, events = setup({ rate = 10 }, function() end, { global = { globalRate = 1, mode = "enforce" } })
			fire(alice)
			fire(alice)
			eq(events[1].violation, "GlobalRateLimit")
		end)
	end)

	describe("event fields", function()
		it("fills every field", function()
			local fire, events = setup({ name = "Swing", schema = { id = t.integer() } }, function() end)
			fire(alice, { id = "5", extra = true })
			local e = events[1]
			eq(e.kind, "violation")
			eq(e.remote, "Swing")
			eq(e.transport, "Mock")
			eq(e.userId, 1)
			eq(e.playerName, "Alice")
			eq(e.violation, "Schema")
			eq(e.reason, "id: expected integer, got string")
			eq(e.payloadPreview, '{ extra = true, id = "5" }')
			eq(e.t, 42)
			eq(e.serverId, "server-1")
			eq(e.mode, "shadow")
		end)

		it("redacts sensitive values in the payload preview", function()
			local fire, events = setup({ schema = { pin = t.sensitive(t.integer(0, 9)) } }, function() end)
			fire(alice, { pin = 1234 })
			eq(events[1].payloadPreview, "{ pin = <redacted> }")
			notContains(events[1].reason, "1234")
		end)

		it("log = false enforces silently", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() }, mode = "enforce", log = false }, handler)
			fire(alice, {})
			eq(#calls, 0)
			eq(#events, 0)
		end)

		it("emits call events for accepted calls when asked", function()
			local fire, events = setup({}, function() end, { logCalls = true })
			fire(alice, 1)
			eq(#events, 1)
			eq(events[1].kind, "call")
			eq(events[1].payloadPreview, "1")
		end)
	end)

	describe("arguments", function()
		it("a single schema expects exactly one argument and passes it as data", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() }, mode = "enforce" }, handler)
			fire(alice, { id = 1 })
			eq(calls[1].args.n, 1)
			eq(calls[1].args[1].id, 1)
			fire(alice, { id = 1 }, "extra")
			eq(events[1].reason, "expected 1 argument, got 2")
			fire(alice)
			eq(events[2].reason, "expected 1 argument, got 0")
			fire(alice, nil)
			eq(events[3].reason, "expected table, got nil")
		end)

		it("t.args passes positional arguments through", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = t.args(t.integer(), t.string(32)), mode = "enforce" }, handler)
			fire(alice, 7, "hi")
			eq(calls[1].args.n, 2)
			eq(calls[1].args[2], "hi")
			fire(alice, 7, "hi", true)
			eq(events[1].reason, "expected 2 arguments, got 3")
			eq(events[1].payloadPreview, '(7, "hi", true)')
		end)
	end)

	describe("handler", function()
		it("captures errors with a traceback and keeps working", function()
			local count = 0
			local fire, events = setup({}, function(_, value)
				count += 1
				if value == "boom" then
					error("handler exploded")
				end
			end)
			fire(alice, "boom")
			fire(alice, "fine")
			eq(count, 2)
			eq(#events, 1)
			eq(events[1].kind, "handlerError")
			contains(events[1].reason, "handler exploded")
			truthy(#events[1].traceback > 0, "traceback captured")
			contains(events[1].traceback, "Pipeline.spec")
		end)

		it("supports handlers that yield", function()
			local done = false
			local fire, events = setup({}, function()
				task.wait(0.01)
				done = true
			end)
			fire(alice)
			task.wait(0.05)
			eq(done, true)
			eq(#events, 0)
		end)

		it("skips the handler if the player already left", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() } }, handler)
			local bob = Fakes.player("Bob", 2)
			bob.Parent = nil
			fire(bob, { id = 1 })
			eq(#calls, 0)
			eq(#events, 0)
		end)
	end)

	describe("bypass", function()
		it("skips rate and schema for bypassed players", function()
			local handler, calls = recorder()
			local fire, events = setup({ rate = 1, schema = { id = t.integer() }, mode = "enforce" }, handler, {
				global = {
					bypass = function(player)
						return player.Name == "Admin"
					end,
				},
			})
			local admin = Fakes.player("Admin", 9)
			for _ = 1, 5 do
				fire(admin, "not even a table")
			end
			eq(#calls, 5)
			eq(#events, 0)
			fire(alice, "bad")
			eq(#calls, 5, "non-bypassed players are still checked")
		end)

		it("a throwing bypass is reported and the call is checked normally", function()
			local handler, calls = recorder()
			local fire, events = setup({ schema = { id = t.integer() }, mode = "enforce" }, handler, {
				global = {
					bypass = function()
						error("oops")
					end,
				},
			})
			fire(alice, { id = 1 })
			eq(#calls, 1)
			eq(events[1].kind, "handlerError")
			contains(events[1].reason, "bypass function errored")
		end)
	end)

	describe("internal errors", function()
		local broken = {
			consume = function()
				error("limiter bug")
			end,
		}

		it("are reported and fail closed in enforce mode", function()
			local handler, calls = recorder()
			local fire, _, _, internal = setup({ rate = 5, mode = "enforce" }, handler, { limiter = broken })
			fire(alice)
			eq(#calls, 0)
			eq(#internal, 1)
			contains(internal[1].message, "limiter bug")
		end)

		it("fail open in shadow mode", function()
			local handler, calls = recorder()
			local fire, _, _, internal = setup({ rate = 5 }, handler, { limiter = broken })
			fire(alice)
			eq(#calls, 1)
			eq(#internal, 1)
		end)
	end)
end)
