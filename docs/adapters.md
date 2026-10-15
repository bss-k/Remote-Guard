# Adapters

RemoteGuard's core never mentions `OnServerEvent` or any network library. A transport
(RemoteEvent today; RemoteFunction, Packet or ByteNet later) plugs in through an adapter: a
plain table with one string and three functions.

```lua
type Adapter = {
	name: string, -- shown in logs as the event's `transport`, e.g. "RemoteEvent"
	validate: (transport: unknown) -> (boolean, string?),
	connect: (transport, onCall: (player: Player, ...any) -> ()) -> { Disconnect: (self) -> () },
	getName: (transport) -> string,
}
```

| Function | Called | Must |
| --- | --- | --- |
| `validate(transport)` | once, when wrapping | Return `true`, or `false` and a reason. A `false` becomes a developer error: `invalid transport for the <name> adapter: <reason>`. |
| `getName(transport)` | once, when wrapping | Return a display name for logs (overridable with the `name` config key). |
| `connect(transport, onCall)` | once, when wrapping | Call `onCall(player, ...)` for every incoming call, with the arguments exactly as received. Return an object with `Disconnect`. |

`onCall` runs the whole pipeline (bypass, rate limits, schema, handler). It never throws and
it never yields unless the user's handler yields.

## The built-in RemoteEvent adapter

```lua
validate = function(transport)
	if typeof(transport) ~= "Instance" then
		return false, "expected a RemoteEvent, got " .. typeof(transport)
	end
	if not transport:IsA("BaseRemoteEvent") then -- RemoteEvent or UnreliableRemoteEvent
		return false, "expected a RemoteEvent, got " .. transport.ClassName
	end
	return true
end,
connect = function(remote, onCall)
	return remote.OnServerEvent:Connect(onCall)
end,
getName = function(remote)
	return remote.Name
end,
```

## Using a custom adapter

```lua
local connection = Guard.wrap(myTransport, MyAdapter, { schema = ..., rate = 5 }, handler)
connection:Disconnect()
```

Each transport instance can be wrapped once. `Disconnect()` disconnects the adapter's
connection, frees the instance for re-wrapping and clears its rate-limit buckets.

The Lune test suite uses a `MockAdapter` (`tests/Fakes.luau`) built exactly this way, so the full
pipeline can be tested without Roblox.
