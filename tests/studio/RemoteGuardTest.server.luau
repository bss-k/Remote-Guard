--[[
	RemoteGuard Studio integration test (server half).

	Covers what Lune cannot: real OnServerEvent wiring, real network serialization.
	Build with `rojo build tests/studio/test.project.json -o RemoteGuardTest.rbxl`, open it,
	press Play, and read the Output window. The client half is RemoteGuardTest.client.luau.

	Every temporary instance and connection is cleaned up in `cleanup()`, which runs even if
	the test errors.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Guard = require(ServerScriptService.RemoteGuard)
local t = Guard.t

local TAG = "[RemoteGuardStudioTest]"
local TIMEOUT = 30

local created: { Instance } = {}
local connections: { { Disconnect: (any) -> () } } = {}
local results: { { name: string, ok: boolean, detail: string } } = {}

local function check(name: string, ok: boolean, detail: string?)
	table.insert(results, { name = name, ok = ok, detail = detail or "" })
end

local function newRemote(name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = "RemoteGuardTest_" .. name
	table.insert(created, remote)
	return remote
end

local function cleanup()
	for _, connection in connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	for _, instance in created do
		pcall(function()
			instance:Destroy()
		end)
	end
	pcall(Guard.logger.removeSink, "StudioTestRecorder")
end

local function run()
	-- Record every event for our remotes.
	local events = {}
	Guard.logger.addSink({
		name = "StudioTestRecorder",
		write = function(batch)
			for _, event in batch do
				table.insert(events, event)
			end
		end,
	})

	local attack = newRemote("Attack")
	local emote = newRemote("Emote")
	local done = newRemote("Done")

	-- Guarded: schema + rate 5 + enforce. targetId 13 makes the handler error on purpose.
	local received: { number } = {}
	table.insert(
		connections,
		Guard.event(attack, {
			name = "Attack",
			schema = { targetId = t.integer(1, 1000) },
			rate = 5,
			mode = "enforce",
		}, function(_player, data)
			table.insert(received, data.targetId)
			if data.targetId == 13 then
				error("deliberate handler error for targetId 13")
			end
		end)
	)

	-- Shorthand: plain remote + pcall + logging.
	local emoteArgs = nil
	table.insert(
		connections,
		Guard.event(emote, function(_player, ...)
			emoteArgs = table.pack(...)
		end)
	)

	-- Developer errors, checked on the server before any client traffic.
	local okTwice, errTwice = pcall(Guard.event, attack, {}, function() end)
	check(
		"wrapping the same remote twice errors",
		not okTwice and string.find(tostring(errTwice), "already wrapped") ~= nil,
		tostring(errTwice)
	)
	local scratch = newRemote("Scratch")
	local okBurst, errBurst = pcall(Guard.event, scratch, { rate = { perSecond = 5, burst = 10 } }, function() end)
	check(
		"burst key errors",
		not okBurst and string.find(tostring(errBurst), "burst was removed") ~= nil,
		tostring(errBurst)
	)

	-- The client signals when it has sent everything. Test infrastructure, so not guarded.
	local finished = false
	table.insert(
		connections,
		done.OnServerEvent:Connect(function()
			finished = true
		end)
	)

	-- Parent last, so the guards are in place before the client can see the remotes.
	attack.Parent = ReplicatedStorage
	emote.Parent = ReplicatedStorage
	done.Parent = ReplicatedStorage

	print(TAG, "waiting for a client (press Play)...")
	local started = os.clock()
	while not finished and os.clock() - started < TIMEOUT do
		task.wait(0.25)
	end
	check(
		"client finished within " .. TIMEOUT .. "s",
		finished,
		if #Players:GetPlayers() == 0 then "no player joined" else ""
	)
	task.wait(0.5) -- let the last events drain

	local function count(predicate: (any) -> boolean): number
		local n = 0
		for _, event in events do
			if event.remote == "Attack" and predicate(event) then
				n += 1
			end
		end
		return n
	end

	-- Phase 1: ids 1, 2, 13, 3 are valid; 13 errors inside the handler.
	local phase1 = table.concat(table.move(received, 1, 4, 1, {}), ",")
	check("valid payloads reach the handler", phase1 == "1,2,13,3", "received " .. phase1)
	local handlerErrors = count(function(e)
		return e.kind == "handlerError"
	end)
	check("handler error captured once, later calls still work", handlerErrors == 1, handlerErrors .. " handler errors")

	-- Phase 2: wrong type, NaN, extra key, wrong arity.
	local schemaViolations = count(function(e)
		return e.violation == "Schema"
	end)
	check(
		"invalid payloads rejected (4 schema violations)",
		schemaViolations == 4,
		schemaViolations .. " schema violations"
	)

	-- Phase 3: 50 valid calls in a burst; a 5/s bucket lets about 5 through.
	local floodAccepted = #received - 4
	check("flood limited to ~5 accepted", floodAccepted >= 5 and floodAccepted <= 7, floodAccepted .. " accepted of 50")
	local rateViolations = count(function(e)
		return e.violation == "RateLimit"
	end)
	check("flood produces rate violations", rateViolations >= 43, rateViolations .. " rate violations")

	check(
		"shorthand remote passes arguments through",
		emoteArgs ~= nil and emoteArgs.n == 2 and emoteArgs[1] == "wave" and emoteArgs[2] == 2,
		if emoteArgs then tostring(emoteArgs[1]) .. ", " .. tostring(emoteArgs[2]) else "never called"
	)
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
	check("test ran without errors", false, tostring(err))
end

local failed = 0
for _, result in results do
	if not result.ok then
		failed += 1
	end
	print(string.format("%s %s  %s  %s", TAG, if result.ok then "PASS" else "FAIL", result.name, result.detail))
end
if failed == 0 then
	print(TAG, string.format("ALL PASSED (%d checks)", #results))
else
	warn(TAG, string.format("%d of %d checks FAILED", failed, #results))
end
