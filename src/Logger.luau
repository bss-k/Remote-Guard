--!strict
--[[
	Collects events and hands them to sinks.

	emit(event):
	  1. freezes the event and stores it in a ring buffer (default 200, oldest dropped);
	  2. calls each sink's write({ event }) in its own thread, inside pcall.

	A failing sink is reported through `onSinkError` (the Printer throttles it) and never
	affects gameplay or other sinks. Each write starts in a new thread, so a sink that
	yields (HTTP, DataStore) can never make emit, or the remote handler, yield.

	write takes an ARRAY so batching sinks can plug in later without an interface change.
	-- PHASE 4: processors / batching sinks plug in here.
]]

local DevError = require(script.Parent.DevError)
local Types = require(script.Parent.Types)

type Event = Types.Event
type Sink = Types.Sink

export type Options = {
	capacity: number?,
	onSinkError: ((sinkName: string, message: string) -> ())?,
	spawn: ((fn: () -> ()) -> ())?, -- default task.spawn; injectable for tests
}

export type Logger = {
	emit: (self: Logger, event: Event) -> (),
	addSink: (self: Logger, sink: Sink) -> (),
	removeSink: (self: Logger, name: string) -> boolean,
	getRecent: (self: Logger, n: number?) -> { Event },
}

local SEVERITY_RANK = { info = 1, warning = 2, error = 3 }
local KIND_SEVERITY = { call = "info", violation = "warning", handlerError = "error" }

local Logger = {}

function Logger.severity(event: Event): string
	return KIND_SEVERITY[event.kind] or "error"
end

local function checkSink(sink: unknown): Sink
	if type(sink) ~= "table" then
		DevError.raise(nil, "addSink expects a sink table { name, write, minSeverity? }, got " .. typeof(sink))
	end
	local s = sink :: any
	if type(s.name) ~= "string" or s.name == "" then
		DevError.raise(nil, "sink.name must be a non-empty string")
	elseif type(s.write) ~= "function" then
		DevError.raise(nil, 'sink "' .. s.name .. '" needs a write(events) function')
	elseif s.minSeverity ~= nil and SEVERITY_RANK[s.minSeverity] == nil then
		DevError.raise(nil, 'sink "' .. s.name .. '": minSeverity must be "info", "warning" or "error"')
	end
	return s
end

function Logger.new(options: Options?): Logger
	local opts: Options = options or {}
	local capacity = opts.capacity or 200
	local onSinkError = opts.onSinkError or function() end
	local spawn = opts.spawn or function(fn: () -> ())
		task.spawn(fn)
	end

	local buffer: { Event } = {}
	local nextSlot = 1 -- where the next event goes
	local count = 0
	local sinks: { Sink } = {}

	local logger = {}

	function logger.emit(_self: Logger, event: Event)
		local frozen = if table.isfrozen(event) then event else table.freeze(event)
		buffer[nextSlot] = frozen
		nextSlot = nextSlot % capacity + 1
		count = math.min(count + 1, capacity)

		local rank = SEVERITY_RANK[Logger.severity(frozen)]
		local batch = { frozen }
		for _, sink in table.clone(sinks) do -- clone: a sink may remove itself
			if sink.minSeverity == nil or rank >= SEVERITY_RANK[sink.minSeverity] then
				spawn(function()
					local ok, err = pcall(sink.write, batch)
					if not ok then
						onSinkError(sink.name, tostring(err))
					end
				end)
			end
		end
	end

	function logger.addSink(_self: Logger, sink: Sink)
		local checked = checkSink(sink)
		for _, existing in sinks do
			if existing.name == checked.name then
				DevError.raise(nil, 'a sink named "' .. checked.name .. '" is already added; remove it first')
			end
		end
		table.insert(sinks, checked)
	end

	function logger.removeSink(_self: Logger, name: string): boolean
		for i, sink in sinks do
			if sink.name == name then
				table.remove(sinks, i)
				return true
			end
		end
		return false
	end

	-- The most recent events, oldest first. `n` defaults to everything kept.
	function logger.getRecent(_self: Logger, n: number?): { Event }
		local take = math.clamp(math.floor(n or count), 0, count)
		local out = table.create(take)
		for i = take, 1, -1 do
			local slot = (nextSlot - i - 1) % capacity + 1
			table.insert(out, buffer[slot])
		end
		return out
	end

	return (logger :: any) :: Logger
end

return Logger
