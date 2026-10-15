local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, contains, notContains, truthy =
	TestKit.describe, TestKit.it, TestKit.eq, TestKit.contains, TestKit.notContains, TestKit.truthy

local lib = Loader.new()
local Printer = lib.require("Printer")
local Preview = lib.require("Preview")
local Throttle = lib.require("Throttle")
local Schema = lib.require("Schema")
local t = Schema.t

-- `nil` can't be stored in an overrides table, so NONE marks a field to remove.
local NONE = {}

local function event(overrides: { [string]: any }?): any
	local e: { [string]: any } = {
		kind = "violation",
		remote = "Attack",
		transport = "RemoteEvent",
		userId = 123,
		playerName = "PlayerName",
		violation = "Schema",
		reason = "targetId: expected integer, got string",
		payloadPreview = '{ extra = true, targetId = "5" }',
		t = 0,
		serverId = "test",
		mode = "enforce",
	}
	for k, v in overrides or {} do
		e[k] = if v == NONE then nil else v
	end
	return e
end

-- A Printer wired to a fake clock and an output that records lines.
local function harness(settings: { level: string?, payloads: boolean?, studio: boolean? }?)
	local s = settings or {}
	local now = 0
	local lines: { { level: string, text: string } } = {}
	local function record(level: string)
		return function(text: string)
			table.insert(lines, { level = level, text = text })
		end
	end
	local state = { level = s.level or "violations", payloads = s.payloads }
	local printer = Printer.new({
		isStudio = if s.studio == nil then true else s.studio,
		settings = function()
			return state.level, state.payloads
		end,
		clock = function()
			return now
		end,
		output = { info = record("info"), warn = record("warn"), error = record("error") },
	})
	return printer, lines, function(seconds: number)
		now += seconds
	end, state
end

describe("Printer", function()
	describe("formats", function()
		it("violation with reason and payload", function()
			eq(
				Printer.format(event(), true),
				"[RemoteGuard] Schema violation | Attack | PlayerName (123)\n"
					.. "  → targetId: expected integer, got string\n"
					.. '  → payload: { extra = true, targetId = "5" }'
			)
		end)

		it("marks shadow-mode violations as allowed", function()
			contains(Printer.format(event({ mode = "shadow" }), false), "Schema violation (shadow: call allowed) |")
		end)

		it("titles every violation type", function()
			contains(Printer.header(event({ violation = "RateLimit" })), "Rate limit exceeded | Attack")
			contains(Printer.header(event({ violation = "GlobalRateLimit" })), "Global rate limit exceeded")
			contains(Printer.header(event({ violation = "Check" })), "Check failed")
		end)

		it("handler errors include the message and the full traceback", function()
			local text = Printer.format(
				event({
					kind = "handlerError",
					violation = NONE,
					reason = "Script:10: attempt to index nil",
					traceback = "Script:10\nScript:20",
					payloadPreview = NONE,
				}),
				true
			)
			eq(
				text,
				"[RemoteGuard] Handler error | Attack | PlayerName (123)\n"
					.. "  → Script:10: attempt to index nil\n"
					.. "      Script:10\n"
					.. "      Script:20"
			)
		end)

		it("internal errors ask for a bug report", function()
			local text = Printer.formatInternal("oops", "trace")
			contains(text, "[RemoteGuard] Internal error: oops")
			contains(text, "This is a RemoteGuard bug, please report at https://github.com/bss-k/Remote-Guard/issues")
		end)
	end)

	describe("printLevel", function()
		local function countFor(level: string): (number, number)
			local printer, lines = harness({ level = level })
			printer:event(event({ kind = "call", violation = NONE, reason = NONE }))
			printer:event(event())
			printer:event(event({ kind = "handlerError", violation = NONE, reason = "boom" }))
			printer:internalError("bug")
			printer:sinkError("Http", "down")
			local warns = 0
			for _, line in lines do
				if line.level ~= "info" then
					warns += 1
				end
			end
			return #lines, warns
		end

		it("all prints everything, calls with print", function()
			local total, warns = countFor("all")
			eq(total, 5)
			eq(warns, 4)
		end)

		it("violations skips accepted calls", function()
			eq(countFor("violations"), 4)
		end)

		it("errors keeps only handler, internal and sink errors", function()
			eq(countFor("errors"), 3)
		end)

		it("off prints nothing", function()
			eq(countFor("off"), 0)
		end)

		it("prints with warn, and internal bugs at error level", function()
			local printer, lines = harness()
			printer:event(event())
			printer:internalError("bug")
			eq(lines[1].level, "warn")
			eq(lines[2].level, "error")
		end)
	end)

	describe("studio vs live profile", function()
		it("studio shows payloads", function()
			local printer, lines = harness({ studio = true })
			printer:event(event())
			contains(lines[1].text, "payload:")
		end)

		it("live omits payloads unless printPayloads = true", function()
			local printer, lines, _, state = harness({ studio = false })
			printer:event(event())
			notContains(lines[1].text, "payload:")
			state.payloads = true
			printer:event(event({ remote = "Other" }))
			contains(lines[2].text, "payload:")
		end)

		it("printPayloads = false hides payloads in Studio", function()
			local printer, lines = harness({ studio = true, payloads = false })
			printer:event(event())
			notContains(lines[1].text, "payload:")
		end)
	end)

	describe("throttle", function()
		it("prints identical lines once, then a summary when the window closes", function()
			local printer, lines, advance = harness()
			for _ = 1, 47 do
				printer:event(event())
			end
			eq(#lines, 1)
			advance(10)
			printer:flush()
			eq(#lines, 2)
			eq(lines[2].text, "[RemoteGuard] Schema violation | Attack | PlayerName (123) x47 in 10s")
		end)

		it("prints the summary on the next print after the window", function()
			local printer, lines, advance = harness()
			printer:event(event())
			printer:event(event())
			advance(11)
			printer:event(event({ remote = "Emote" }))
			eq(#lines, 3)
			contains(lines[2].text, "x2 in 10s")
			contains(lines[3].text, "| Emote |")
		end)

		it("keys by player, remote and reason", function()
			local printer, lines = harness()
			printer:event(event())
			printer:event(event({ userId = 456, playerName = "Other" }))
			printer:event(event({ reason = "different" }))
			printer:event(event({ remote = "Emote" }))
			eq(#lines, 4)
		end)

		it("no summary when nothing was suppressed", function()
			local printer, lines, advance = harness()
			printer:event(event())
			advance(10)
			printer:flush()
			eq(#lines, 1)
		end)

		it("throttles sink errors per sink", function()
			local printer, lines = harness()
			printer:sinkError("Http", "timeout")
			printer:sinkError("Http", "refused")
			eq(#lines, 1)
			eq(lines[1].text, '[RemoteGuard] Sink "Http" failed: timeout')
		end)

		it("Throttle handles a clock going backwards", function()
			local now = 100
			local throttle = Throttle.new({
				clock = function()
					return now
				end,
			})
			truthy(throttle:hit("k", "label"))
			now = 50
			truthy(throttle:hit("k", "label"), "backwards clock reopens the window")
		end)
	end)
end)

describe("Preview", function()
	it("formats tables with stable key order", function()
		eq(Preview.value({ targetId = "5", extra = true }), '{ extra = true, targetId = "5" }')
		eq(Preview.value({ 1, 2, 3 }), "{ 1, 2, 3 }")
		eq(Preview.value({ 10, 20, name = "x" }), '{ 10, 20, name = "x" }')
		eq(Preview.value({ ["odd key"] = 1, [true] = 2 }), '{ ["odd key"] = 1, [true] = 2 }')
		eq(Preview.value({}), "{}")
		eq(Preview.value(nil), "nil")
		eq(Preview.value(0 / 0), "NaN")
	end)

	it("limits depth to 3", function()
		eq(Preview.value({ a = { b = { c = { d = 1 } } } }), "{ a = { b = { c = {...} } } }")
	end)

	it("is safe on cycles and metatables", function()
		local cyclic: any = { name = "loop" }
		cyclic.self = cyclic
		eq(Preview.value(cyclic), '{ name = "loop", self = <cycle> }')
		local tricky = setmetatable({ a = 1 }, {
			__tostring = function()
				error("should not be called")
			end,
			__index = function()
				error("should not be called")
			end,
		})
		eq(Preview.value(tricky), "{ a = 1 }")
	end)

	it("prints unprintable values by type and escapes strings", function()
		eq(Preview.value({ print }), "{ function }")
		eq(Preview.value("a\nb"), '"a\\10b"')
	end)

	it("truncates long output to about 200 characters", function()
		local big = {}
		for i = 1, 1000 do
			big[i] = string.rep("x", 30)
		end
		local text = Preview.value(big)
		truthy(#text <= 200, "length " .. #text)
		eq(string.sub(text, -3), "...")
	end)

	it("redacts sensitive paths", function()
		local _, info = Schema.compile({
			pin = t.sensitive(t.integer()),
			items = t.array({ secret = t.sensitive(t.string()), id = t.integer() }),
			name = t.string(),
		})
		local text = Preview.arguments(
			table.pack({
				pin = 1234,
				name = "bob",
				items = { { secret = "hunter2", id = 1 } },
			}),
			{ fields = { [1] = info.redaction } }
		)
		eq(text, '{ items = { { id = 1, secret = <redacted> } }, name = "bob", pin = <redacted> }')
		notContains(text, "hunter2")
		notContains(text, "1234")
	end)

	it("previews multiple arguments", function()
		eq(Preview.arguments(table.pack(1, "a", nil)), '(1, "a", nil)')
		local _, info = Schema.compile(t.args(t.integer(), t.sensitive(t.string())))
		eq(Preview.arguments(table.pack(1, "secret"), info.redaction), "(1, <redacted>)")
	end)
end)
