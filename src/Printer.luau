--!strict
--[[
	Turns events into readable output lines.

		[RemoteGuard] Schema violation | Attack | PlayerName (123)
		  → targetId: expected integer, got string
		  → payload: { targetId = "5", extra = true }

	The formatting functions are pure (data in, string out). `Printer.new` adds the
	stateful parts: printLevel filtering, the Studio/live payload profile, and throttling of
	identical lines. Output functions, clock and settings are injected, so nothing here
	touches Roblox services.
]]

local Format = require(script.Parent.Format)
local Throttle = require(script.Parent.Throttle)
local Types = require(script.Parent.Types)

type Event = Types.Event
type PrintLevel = Types.PrintLevel

export type Output = {
	info: (text: string) -> (),
	warn: (text: string) -> (),
	error: (text: string) -> (), -- must not stop the server
}

export type Options = {
	isStudio: boolean | () -> boolean, -- a function is called lazily (no RunService at require)
	-- Read on every print, so Guard.config changes apply immediately.
	settings: () -> (PrintLevel, boolean?), -- printLevel, printPayloads
	clock: (() -> number)?,
	throttleWindow: number?,
	output: Output?,
}

export type Printer = {
	event: (self: Printer, event: Event) -> (),
	internalError: (self: Printer, message: string, traceback: string?) -> (),
	sinkError: (self: Printer, sinkName: string, message: string) -> (),
	flush: (self: Printer) -> (),
	hasPending: (self: Printer) -> boolean,
}

local ISSUES_URL = "https://github.com/bss-k/Remote-Guard/issues"
local ARROW = "  → "

local TITLES = {
	Schema = "Schema violation",
	RateLimit = "Rate limit exceeded",
	GlobalRateLimit = "Global rate limit exceeded",
	Check = "Check failed",
}

-- How permissive printLevel must be for each kind of line: all = 3 ... off = 0.
local LEVEL_RANK = { all = 3, violations = 2, errors = 1, off = 0 }
local KIND_NEEDS = { call = 3, violation = 2, handlerError = 1 }
local ERROR_NEEDS = 1

local Printer = {}

local function indent(text: string, prefix: string): string
	return prefix .. string.gsub(text, "\n", "\n" .. prefix)
end

function Printer.header(event: Event): string
	local title = if event.kind == "violation"
		then TITLES[event.violation :: string] or "Violation"
		elseif event.kind == "handlerError" then "Handler error"
		else "Call"
	if event.kind == "violation" and event.mode == "shadow" then
		title ..= " (shadow: call allowed)"
	end
	return string.format(
		"[RemoteGuard] %s | %s | %s (%s)",
		title,
		event.remote,
		event.playerName,
		Format.number(event.userId)
	)
end

function Printer.format(event: Event, showPayload: boolean): string
	local lines = { Printer.header(event) }
	if event.reason then
		table.insert(lines, indent(event.reason, ARROW))
	end
	if showPayload and event.payloadPreview then
		table.insert(lines, ARROW .. "payload: " .. event.payloadPreview)
	end
	if event.traceback then
		table.insert(lines, indent(event.traceback, "      "))
	end
	return table.concat(lines, "\n")
end

function Printer.formatSummary(summary: Throttle.Summary): string
	return string.format("%s x%d in %ss", summary.label, summary.count, Format.number(summary.window))
end

function Printer.formatInternal(message: string, traceback: string?): string
	local text = "[RemoteGuard] Internal error: " .. message
	if traceback then
		text ..= "\n" .. indent(traceback, "      ")
	end
	return text .. "\nThis is a RemoteGuard bug, please report at " .. ISSUES_URL
end

function Printer.formatSinkError(sinkName: string, message: string): string
	return string.format('[RemoteGuard] Sink "%s" failed: %s', sinkName, message)
end

-- Studio shows payloads; live servers omit them unless printPayloads = true.
function Printer.showPayload(isStudio: boolean, printPayloads: boolean?): boolean
	if printPayloads ~= nil then
		return printPayloads
	end
	return isStudio
end

function Printer.allows(level: PrintLevel, need: number): boolean
	return (LEVEL_RANK[level] or 0) >= need
end

local function defaultOutput(): Output
	return {
		info = print,
		warn = warn,
		error = function(text: string)
			-- An error in its own thread prints red with a stack but never stops the caller.
			task.spawn(error, text, 0)
		end,
	}
end

function Printer.new(options: Options): Printer
	local output = options.output or defaultOutput()
	local throttle = Throttle.new({ clock = options.clock, window = options.throttleWindow })
	local printer = {}

	-- Prints summaries for throttle windows that have closed ("on the next print").
	function printer.flush(_self: Printer)
		local level = options.settings()
		for _, summary in throttle:takeExpired() do
			if level ~= "off" then
				output.warn(Printer.formatSummary(summary))
			end
		end
	end

	function printer.hasPending(_self: Printer): boolean
		return throttle:hasPending()
	end

	function printer.event(self: Printer, event: Event)
		self:flush()
		local level, printPayloads = options.settings()
		if not Printer.allows(level, KIND_NEEDS[event.kind] or ERROR_NEEDS) then
			return
		end
		local header = Printer.header(event)
		local key = table.concat({ header, event.violation or "", event.reason or "" }, "\0")
		if not throttle:hit(key, header) then
			return
		end
		local studio = options.isStudio
		local isStudio = if type(studio) == "function" then studio() else studio
		local text = Printer.format(event, Printer.showPayload(isStudio, printPayloads))
		if event.kind == "call" then
			output.info(text)
		else
			output.warn(text)
		end
	end

	function printer.internalError(self: Printer, message: string, traceback: string?)
		self:flush()
		if not Printer.allows((options.settings()), ERROR_NEEDS) then
			return
		end
		if throttle:hit("internal\0" .. message, "[RemoteGuard] Internal error: " .. message) then
			output.error(Printer.formatInternal(message, traceback))
		end
	end

	-- Throttled per sink (not per message), so a sink failing in varied ways stays quiet.
	function printer.sinkError(self: Printer, sinkName: string, message: string)
		self:flush()
		if not Printer.allows((options.settings()), ERROR_NEEDS) then
			return
		end
		if throttle:hit("sink\0" .. sinkName, Printer.formatSinkError(sinkName, "repeated failures")) then
			output.warn(Printer.formatSinkError(sinkName, message))
		end
	end

	return (printer :: any) :: Printer
end

return Printer
