# Remote-Guard

**RemoteGuard** is a drop-in, server-side guard for remotes. It sits in front of your
handlers and decides which calls get through: schema validation, per-player rate limits, and
readable, throttled violation logs.

It is a **layer, not a network library**. It does no serialization or batching; it works with
the remotes you already have. RemoteEvent is supported today, and other transports plug in
through a small [adapter](docs/adapters.md).

```
incoming call -> adapter -> [bypass] -> [rate] -> [globalRate] -> [schema] -> handler (xpcall)
any failure   -> violation event -> logger -> sinks (Output window by default)
mode "shadow" logs and still runs the handler; "enforce" logs and drops the call
```

Every feature is opt-in per remote. A remote with an empty config behaves like a plain
`OnServerEvent` connection, plus handler errors caught with a traceback, and logging.

> **Status: pre-release (0.x).** The API may change between minor versions. Server-side only.

## Install

**Wally** (server realm):

```toml
[server-dependencies]
RemoteGuard = "bss-k/remote-guard@0.1.0"
```

**Model file**: build it and insert `RemoteGuard.rbxm` into `ServerScriptService` (or any
server-only container):

```bash
rojo build -o RemoteGuard.rbxm
```

## Quickstart

```lua
local Guard = require(game:GetService("ServerScriptService").RemoteGuard)
local t = Guard.t
local Remotes = game:GetService("ReplicatedStorage").Remotes

-- Plain remote + pcall safety + logging
Guard.event(Remotes.Emote, function(player, emoteName) end)

-- One table argument, validated
Guard.event(Remotes.Interact, { schema = { targetId = t.integer(1, 1e6) } }, function(player, data)
	print(data.targetId)
end)

-- Positional arguments, 5 calls/s per player, violations dropped
Guard.event(Remotes.Attack, {
	schema = t.args(t.integer(1, 1e6), t.string(32)),
	rate = 5,
	mode = "enforce",
}, function(player, targetId, comboName) end)
```

A violation prints a line like this (payloads show in Studio, hidden on live servers):

```
[RemoteGuard] Schema violation | Interact | PlayerName (123)
  → targetId: expected integer, got string
  → payload: { targetId = "5" }
```

Repeats of the same line are collapsed into `... x47 in 10s`. A mistake in your config raises
an error that points at your own `Guard.event(...)` line:

```
Server:12: [RemoteGuard] Config error on "Attack": unknown key "rates" (did you mean "rate"?); valid keys: ...
```

See [`examples/basic.server.luau`](examples/basic.server.luau) for a complete script.

> **Never also connect the raw remote.** If you guard a remote and keep a separate
> `remote.OnServerEvent:Connect(...)` on it, that connection receives every call unchecked.
> Move the handler into `Guard.event` instead.

## Per-remote config

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `schema` | schema or `false` | none | A single schema means the remote takes exactly one argument, passed to your handler as `data`. `t.args(...)` validates positional arguments, passed through as-is. |
| `rate` | `number`, `{ perSecond = number }` or `false` | `Guard.config.rate` | Token bucket per player: holds `perSecond` calls and refills at `perSecond` per second. There is no `burst`. |
| `mode` | `"shadow"` or `"enforce"` | `Guard.config.mode` | Shadow logs and still runs the handler (with the raw data). Enforce drops the call. |
| `log` | `boolean` | `Guard.config.log` | `false` stops this remote's events reaching the logger (enforcement still applies). |
| `name` | `string` | the remote's `Name` | Display name in logs and errors. |
| `checks` | | | Coming soon. |
| `strikes` | | | Coming soon. |

### Opt-out rules

Every optional property follows one rule:

- **`nil`** (left out): use the `Guard.config` default.
- **`false`**: off for this remote, even if the global default is on.
- **a value**: on, with these settings.

## Global config (`Guard.config`)

Set fields before wrapping remotes; they are validated each time a remote is wrapped.

| Key | Default | Notes |
| --- | --- | --- |
| `mode` | `"shadow"` | Safe for existing games: nothing is dropped until you switch to `"enforce"`. |
| `rate` | `false` | Default per-remote rate. Off unless you opt in. |
| `globalRate` | `false` | Per-player budget across all guarded remotes. A call must pass both limits. |
| `printLevel` | `"violations"` | `"all"` (also accepted calls), `"violations"`, `"errors"` (handler and library errors only), `"off"`. Read on every print. |
| `printPayloads` | `nil` | `nil` = show payloads in Studio only. `true` / `false` forces it. |
| `log` | `true` | Default for the per-remote `log` key. |
| `bypass` | `nil` | `function(player) -> boolean`. `true` skips rate limits and schema for that call. |
| `strikes` | `false` | Coming soon. |

## Schemas (`Guard.t`)

| Combinator | Accepts |
| --- | --- |
| `t.number(min?, max?)` | finite number (no NaN / ±inf) |
| `t.integer(min?, max?)` | finite whole number |
| `t.string(maxLen? = 256, pattern?)` | string up to `maxLen` bytes, optionally matching a Lua pattern |
| `t.boolean()`, `t.literal(value)`, `t.enum({ values })` | exact values |
| `t.vector3()`, `t.unitVector3(tolerance? = 0.01)` | Vector3 with finite components (unit length) |
| `t.instance(className?, descendantOf?)` | a live (not destroyed) Instance |
| `t.optional(schema)` | `nil` or the schema |
| `t.array(schema, maxLen? = 100)` | array without gaps |
| `t.struct(fields, { strict = false }?)` | table; strict (unknown keys rejected) unless `strict = false` |
| `{ key = schema }` | shorthand for a strict `t.struct` |
| `t.union({ schemas })` | any one of the schemas |
| `t.args(...)` | positional arguments; trailing `t.optional` arguments may be omitted |
| `t.sensitive(schema)` | validates like `schema` but prints `<redacted>` in logs |

Tables with metatables and tables nested deeper than 8 levels are rejected. Schemas are compiled
once when the remote is wrapped; each call only runs the compiled checks.

## Logging

```lua
Guard.logger.getRecent(20) -- the last 20 events (a buffer of 200 is kept)
Guard.logger.removeSink("Console") -- stop printing to Output
Guard.logger.addSink({
	name = "MySink",
	minSeverity = "warning", -- optional: "info" | "warning" | "error"
	write = function(events) end, -- an array of frozen events
})
```

Sinks run in their own thread inside `pcall`: a failing or yielding sink never affects your
remotes.

## Development

Tools are pinned in `rokit.toml`:

```bash
rokit install
```

```bash
lune run tests
```

```bash
selene src && stylua --check src tests
```

```bash
rojo build -o RemoteGuard.rbxm
```

See [`tests/README.md`](tests/README.md) for how the Lune suite loads modules and how
to run the Studio integration test.

## License

MIT. See [LICENSE](LICENSE).
