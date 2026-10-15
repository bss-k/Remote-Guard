--!strict
--[[
	Collapses repeated identical lines. The first hit for a key prints and opens a window;
	further hits inside the window are counted, not printed. When the window has closed,
	`takeExpired` returns one summary per key that had repeats ("x47 in 10s").

	No loops or timers: windows are closed lazily on the next hit / takeExpired call.
	Pure module; the clock is injectable.
]]

export type Summary = { label: string, count: number, window: number }

type Window = { started: number, count: number, label: string }

export type Throttle = {
	hit: (self: Throttle, key: string, label: string) -> boolean,
	takeExpired: (self: Throttle) -> { Summary },
	hasPending: (self: Throttle) -> boolean,
}

local Throttle = {}

function Throttle.new(options: { clock: (() -> number)?, window: number? }?): Throttle
	local clock = (options and options.clock) or os.clock
	local windowLength = (options and options.window) or 10
	local windows: { [string]: Window } = {}

	local throttle = {}

	-- Returns true if this line should print now.
	function throttle.hit(_self: Throttle, key: string, label: string): boolean
		local now = clock()
		local current = windows[key]
		-- A clock that goes backwards also closes the window rather than freezing it.
		if current and now >= current.started and now - current.started < windowLength then
			current.count += 1
			return false
		end
		windows[key] = { started = now, count = 1, label = label }
		return true
	end

	-- Removes closed windows and returns summaries for those that suppressed repeats.
	function throttle.takeExpired(_self: Throttle): { Summary }
		local now = clock()
		local summaries: { Summary } = {}
		for key, current in windows do
			if now < current.started or now - current.started >= windowLength then
				windows[key] = nil
				if current.count > 1 then
					table.insert(summaries, { label = current.label, count = current.count, window = windowLength })
				end
			end
		end
		table.sort(summaries, function(a, b)
			return a.label < b.label
		end)
		return summaries
	end

	-- True while any window holds suppressed repeats (lets a sink schedule a flush).
	function throttle.hasPending(_self: Throttle): boolean
		for _, current in windows do
			if current.count > 1 then
				return true
			end
		end
		return false
	end

	return (throttle :: any) :: Throttle
end

return Throttle
