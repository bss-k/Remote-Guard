--[[
	RemoteGuard example: three ways to guard a RemoteEvent.
	Put this in ServerScriptService next to the RemoteGuard module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Guard = require(ServerScriptService.RemoteGuard)
local t = Guard.t

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Optional: global defaults, set before wrapping.
-- Guard.config.mode = "enforce"     -- default "shadow": log violations but still run handlers
-- Guard.config.rate = 10            -- default false: no per-remote rate limit unless asked
-- Guard.config.globalRate = 60      -- default false: per-player budget across all remotes

-- 1. Empty config: a plain connection, plus pcall safety and logging of handler errors.
Guard.event(Remotes.Emote, function(player, emoteName)
	print(player.Name, "emoted", emoteName)
end)

-- 2. Schema only: the remote takes exactly one argument, a table shaped like this.
--    The handler receives that table as `data`.
Guard.event(Remotes.Interact, {
	schema = { targetId = t.integer(1, 1e6) },
}, function(player, data)
	print(player.Name, "interacted with", data.targetId)
end)

-- 3. Full config: positional arguments, a rate limit and enforcement.
--    The handler receives the arguments as they were sent.
Guard.event(Remotes.Attack, {
	schema = t.args(t.integer(1, 1e6), t.unitVector3(), t.optional(t.string(32))),
	rate = 5, -- calls per second, per player
	mode = "enforce", -- drop violating calls instead of only logging them
	name = "Attack", -- display name in logs (defaults to the remote's Name)
}, function(player, targetId, aimDirection, comboName)
	print(player.Name, "attacked", targetId, aimDirection, comboName)
end)
