--!strict
--[[
	The default sink: prints events to the Output window through the Printer.

	Registered by default; remove it with Guard.logger.removeSink("Console").

	When the Printer is holding back repeats, this sink schedules one delayed flush so the
	"x47 in 10s" summary appears even if nothing else is printed afterwards.
]]

local Printer = require(script.Parent.Parent.Printer)
local Types = require(script.Parent.Parent.Types)

export type Options = {
	printer: Printer.Printer,
	flushDelay: number?, -- seconds; match the Printer's throttle window
	delay: ((seconds: number, fn: () -> ()) -> ())?, -- default task.delay
}

local Console = {}

Console.NAME = "Console"

function Console.new(options: Options): Types.Sink
	local printer = options.printer
	local flushDelay = options.flushDelay or 10
	local delay = options.delay or function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end
	local flushScheduled = false

	local function scheduleFlush()
		if flushScheduled or not printer:hasPending() then
			return
		end
		flushScheduled = true
		delay(flushDelay, function()
			flushScheduled = false
			printer:flush()
			scheduleFlush() -- windows opened meanwhile still need their summary
		end)
	end

	return {
		name = Console.NAME,
		write = function(events: { Types.Event })
			for _, event in events do
				printer:event(event)
			end
			scheduleFlush()
		end,
	}
end

return Console
