--!strict
--[[
	Adapter for RemoteEvent (and UnreliableRemoteEvent): connects OnServerEvent.
	See docs/adapters.md for the adapter interface.
]]

local Types = require(script.Parent.Parent.Types)

local RemoteEventAdapter = {}

RemoteEventAdapter.name = "RemoteEvent"

function RemoteEventAdapter.validate(transport: unknown): (boolean, string?)
	if typeof(transport) ~= "Instance" then
		return false, "expected a RemoteEvent, got " .. typeof(transport)
	end
	local instance = transport :: Instance
	-- BaseRemoteEvent covers RemoteEvent and UnreliableRemoteEvent, which share OnServerEvent.
	if not instance:IsA("BaseRemoteEvent") then
		return false, "expected a RemoteEvent, got " .. instance.ClassName
	end
	return true
end

function RemoteEventAdapter.connect(transport: RemoteEvent, onCall: (player: Player, ...any) -> ()): Types.Connection
	return transport.OnServerEvent:Connect(onCall) :: any
end

function RemoteEventAdapter.getName(transport: RemoteEvent): string
	return transport.Name
end

return (RemoteEventAdapter :: any) :: Types.Adapter
