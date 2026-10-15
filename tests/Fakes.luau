--[[
	Test doubles: fake players and a MockAdapter that lets tests fire calls through the
	whole pipeline without Roblox.
]]

local Fakes = {}

-- A player-shaped table. Set `player.Parent = nil` to simulate leaving.
function Fakes.player(name: string, userId: number): any
	return { Name = name, UserId = userId, Parent = { Name = "Players" } }
end

-- A fake transport plus an adapter for it. `transport:fire(player, ...)` runs the guard.
function Fakes.transport(name: string): any
	return { kind = "MockTransport", Name = name, listeners = {} }
end

function Fakes.fire(transport: any, player: any, ...: any)
	for _, listener in table.clone(transport.listeners) do
		listener(player, ...)
	end
end

Fakes.MockAdapter = {
	name = "Mock",
	validate = function(transport: any): (boolean, string?)
		if type(transport) == "table" and transport.kind == "MockTransport" then
			return true
		end
		return false, "expected a mock transport, got " .. typeof(transport)
	end,
	connect = function(transport: any, onCall: (any, ...any) -> ()): any
		table.insert(transport.listeners, onCall)
		return {
			Disconnect = function()
				local index = table.find(transport.listeners, onCall)
				if index then
					table.remove(transport.listeners, index)
				end
			end,
		}
	end,
	getName = function(transport: any): string
		return transport.Name
	end,
}

-- Collects emitted events.
function Fakes.logger(): any
	local logger = { events = {} }
	function logger.emit(self: any, event: any)
		table.insert(self.events, event)
	end
	return logger
end

-- A minimal `game` for loading the library root. Counts GetService calls so tests can prove
-- nothing is touched at require time, and lets tests fire PlayerRemoving.
function Fakes.game(options: { isStudio: boolean? }?): any
	local removing = { listeners = {} }
	function removing.Connect(self: any, fn: any)
		table.insert(self.listeners, fn)
		return { Disconnect = function() end }
	end
	local services = {
		Players = { PlayerRemoving = removing },
		RunService = {
			IsStudio = function()
				return if options and options.isStudio ~= nil then options.isStudio else true
			end,
		},
	}
	local game = { JobId = "", serviceCalls = 0 }
	function game.GetService(self: any, name: string): any
		self.serviceCalls += 1
		return services[name]
	end
	function game.firePlayerRemoving(_self: any, player: any)
		for _, fn in removing.listeners do
			fn(player)
		end
	end
	function game.countPlayerRemovingListeners(): number
		return #removing.listeners
	end
	return game
end

return Fakes
