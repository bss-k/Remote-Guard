local task = require("@lune/task")
local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, truthy, contains, throws =
	TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.contains, TestKit.throws

local lib = Loader.new()
local Logger = lib.require("Logger")
local Printer = lib.require("Printer")
local Console = lib.require("Sinks/Console")

local function event(i: number, kind: string?): any
	return {
		kind = kind or "violation",
		remote = "Attack",
		transport = "RemoteEvent",
		userId = i,
		playerName = "P" .. i,
		violation = "Schema",
		reason = "bad " .. i,
		t = i,
		serverId = "test",
		mode = "enforce",
	}
end

-- Runs sink writes immediately (no threads) so assertions see their effects.
local function syncSpawn(fn: () -> ())
	fn()
end

local function recordingSink(name: string, minSeverity: string?)
	local received = {}
	return {
		name = name,
		minSeverity = minSeverity,
		write = function(events)
			for _, e in events do
				table.insert(received, e)
			end
		end,
	},
		received
end

describe("Logger", function()
	it("keeps a bounded ring buffer, oldest first", function()
		local logger = Logger.new({ capacity = 3, spawn = syncSpawn })
		for i = 1, 5 do
			logger:emit(event(i))
		end
		local recent = logger:getRecent()
		eq(#recent, 3)
		eq(recent[1].userId, 3)
		eq(recent[3].userId, 5)
		local last = logger:getRecent(2)
		eq(#last, 2)
		eq(last[1].userId, 4)
		eq(#logger:getRecent(100), 3, "n larger than the buffer")
		eq(#Logger.new():getRecent(), 0, "empty logger")
	end)

	it("defaults to 200 events", function()
		local logger = Logger.new({ spawn = syncSpawn })
		for i = 1, 250 do
			logger:emit(event(i))
		end
		eq(#logger:getRecent(), 200)
		eq(logger:getRecent(1)[1].userId, 250)
	end)

	it("passes events to sinks as an array and freezes them", function()
		local logger = Logger.new({ spawn = syncSpawn })
		local sink, received = recordingSink("Rec")
		logger:addSink(sink)
		logger:emit(event(1))
		eq(#received, 1)
		truthy(table.isfrozen(received[1]), "event is frozen")
	end)

	it("isolates a failing sink and reports it", function()
		local errors = {}
		local logger = Logger.new({
			spawn = syncSpawn,
			onSinkError = function(name, message)
				table.insert(errors, name .. ": " .. message)
			end,
		})
		logger:addSink({
			name = "Broken",
			write = function()
				error("disk full", 0)
			end,
		})
		local sink, received = recordingSink("Rec")
		logger:addSink(sink)
		logger:emit(event(1))
		logger:emit(event(2))
		eq(#received, 2, "other sinks still run")
		eq(errors[1], "Broken: disk full")
		eq(#logger:getRecent(), 2)
	end)

	it("never yields, even if a sink does", function()
		local logger = Logger.new() -- real task.spawn
		local finished = false
		logger:addSink({
			name = "Slow",
			write = function()
				task.wait(0.05)
				finished = true
			end,
		})
		local thread = coroutine.create(function()
			logger:emit(event(1))
		end)
		coroutine.resume(thread)
		eq(coroutine.status(thread), "dead", "emit returned without yielding")
		eq(finished, false)
		task.wait(0.1)
		eq(finished, true, "the sink still completed in its own thread")
	end)

	it("filters by minSeverity", function()
		local logger = Logger.new({ spawn = syncSpawn })
		local sink, received = recordingSink("ErrorsOnly", "error")
		logger:addSink(sink)
		logger:emit(event(1, "call"))
		logger:emit(event(2, "violation"))
		logger:emit(event(3, "handlerError"))
		eq(#received, 1)
		eq(received[1].kind, "handlerError")
	end)

	it("removeSink stops delivery and reports whether it existed", function()
		local logger = Logger.new({ spawn = syncSpawn })
		local sink, received = recordingSink("Rec")
		logger:addSink(sink)
		eq(logger:removeSink("Rec"), true)
		eq(logger:removeSink("Rec"), false)
		logger:emit(event(1))
		eq(#received, 0)
	end)

	it("rejects malformed and duplicate sinks", function()
		local logger = Logger.new()
		throws(function()
			logger:addSink({ name = "X" } :: any)
		end, 'sink "X" needs a write(events) function')
		throws(function()
			logger:addSink({ name = "X", write = print, minSeverity = "debug" } :: any)
		end, "minSeverity must be")
		logger:addSink({ name = "X", write = print })
		throws(function()
			logger:addSink({ name = "X", write = print })
		end, 'a sink named "X" is already added')
	end)
end)

describe("Console sink", function()
	local function setup(level: string?)
		local now = 0
		local lines = {}
		local pending: { () -> () } = {}
		local printer = Printer.new({
			isStudio = true,
			settings = function()
				return level or "violations", nil
			end,
			clock = function()
				return now
			end,
			output = {
				info = function(text)
					table.insert(lines, text)
				end,
				warn = function(text)
					table.insert(lines, text)
				end,
				error = function(text)
					table.insert(lines, text)
				end,
			},
		})
		local logger = Logger.new({
			spawn = syncSpawn,
			onSinkError = function(name, message)
				printer:sinkError(name, message)
			end,
		})
		logger:addSink(Console.new({
			printer = printer,
			delay = function(_, fn)
				table.insert(pending, fn)
			end,
		}))
		return logger, lines, pending, function(seconds: number)
			now += seconds
		end
	end

	it("prints events through the Printer", function()
		local logger, lines = setup()
		logger:emit(event(1))
		eq(#lines, 1)
		contains(lines[1], "[RemoteGuard] Schema violation | Attack | P1 (1)")
	end)

	it("schedules one flush so repeat summaries appear without further prints", function()
		local logger, lines, pending, advance = setup()
		for _ = 1, 5 do
			logger:emit(event(1))
		end
		eq(#lines, 1)
		eq(#pending, 1, "exactly one flush scheduled")
		advance(10)
		pending[1]()
		eq(#lines, 2)
		contains(lines[2], "x5 in 10s")
	end)

	it("printLevel off silences the Console but events are still recorded", function()
		local logger, lines = setup("off")
		logger:emit(event(1))
		eq(#lines, 0)
		eq(#logger:getRecent(), 1)
	end)

	it("can be removed by name", function()
		local logger, lines = setup()
		eq(logger:removeSink(Console.NAME), true)
		logger:emit(event(1))
		eq(#lines, 0)
	end)

	it("a throwing sink produces one throttled warning", function()
		local logger, lines = setup()
		logger:addSink({
			name = "Http",
			write = function()
				error("503", 0)
			end,
		})
		logger:emit(event(1))
		logger:emit(event(2))
		local sinkLines = 0
		for _, line in lines do
			if string.find(line, 'Sink "Http" failed: 503', 1, true) then
				sinkLines += 1
			end
		end
		eq(sinkLines, 1)
	end)
end)
