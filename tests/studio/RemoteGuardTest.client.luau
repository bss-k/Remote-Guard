--[[
	RemoteGuard Studio integration test (client half). Fires valid payloads, invalid
	payloads and a flood at the server's guarded remotes, then signals that it is done.
	Pauses between phases let the 5/s rate bucket refill, so each phase is judged alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local attack = ReplicatedStorage:WaitForChild("RemoteGuardTest_Attack", 15) :: RemoteEvent?
local emote = ReplicatedStorage:WaitForChild("RemoteGuardTest_Emote", 15) :: RemoteEvent?
local done = ReplicatedStorage:WaitForChild("RemoteGuardTest_Done", 15) :: RemoteEvent?
if not (attack and emote and done) then
	warn("[RemoteGuardStudioTest] client: test remotes not found; is the server test running?")
	return
end

-- Phase 1: valid payloads (13 makes the server handler error on purpose).
for _, id in { 1, 2, 13, 3 } do
	attack:FireServer({ targetId = id })
end
emote:FireServer("wave", 2)
task.wait(1.5)

-- Phase 2: invalid payloads.
attack:FireServer({ targetId = "5" }) -- wrong type
attack:FireServer({ targetId = 0 / 0 }) -- NaN
attack:FireServer({ targetId = 1, extra = true }) -- extra key
attack:FireServer({ targetId = 1 }, "extra argument") -- wrong arity
task.wait(1.5)

-- Phase 3: flood.
for i = 1, 50 do
	attack:FireServer({ targetId = i })
end
task.wait(1)

done:FireServer()
