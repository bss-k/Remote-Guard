# Tests

| Suite | Where | Runs |
| --- | --- | --- |
| Unit and pipeline tests | `tests/*.spec.luau` | Lune, locally and in CI |
| Studio integration | `tests/studio/` | Manually, in Roblox Studio Play mode |

## Running the Lune suite

From the repo root:

```bash
lune run tests
```

[`init.luau`](init.luau) runs every `tests/*.spec.luau` file and exits non-zero if any test fails.
A spec that fails to load is reported as a failure rather than aborting the run.
[`TestKit.luau`](TestKit.luau) provides `describe`, `it` and a few assertions (`eq`, `truthy`,
`falsy`, `contains`, `notContains`, `throws`).

Spec files require their siblings with `./` (for example `require("./TestKit")`); only
`init.luau` uses `@self/`.

## How Roblox-style modules load under Lune

The library is written as ordinary Roblox code: every module uses `require(script.Parent.X)` and
Rojo maps `src/` to instances. Lune has no DataModel, so [`loader.luau`](loader.luau) recreates
just enough of one. Nothing in `src/` knows the loader exists.

1. It walks the source folder with Rojo's rules (`init.luau` makes a folder a module, `X.luau`
   becomes a child named `X`, plain folders stay folders) and builds a tree of small "script"
   nodes that support `.Name`, `.Parent` and child lookup by name. A missing child errors with
   Roblox's wording (`X is not a valid member of Y`).
2. It loads each file with `luau.load(source, { environment = env })`, where `env` holds
   `script` (that file's node), a `require` that accepts nodes, Lune's `task` library, and any
   extra globals the test passes in.
3. Each `Loader.new()` has its own module cache, so tests get fresh library state.

```lua
local Loader = require("./loader")

local Guard = Loader.new().require()                      -- src/init.luau
local Schema = Loader.new().require("Schema")             -- src/Schema.luau
local lib = Loader.new({ globals = { game = fakeGame } }) -- inject fakes
```

### Why this approach

- **Alternatives rejected.** Rewriting requires as string paths would distort the library for
  the test runner. A build-time transform adds a step that can drift from what Rojo ships.
  `@lune/roblox` can read place files, but it does not run scripts or resolve `script`.
- **Rule for library code.** Pure modules (Schema, RateLimiter, Config, Printer) never read
  `game` at require time. Their clock, Players and RunService come in as parameters. Only
  `init.luau` and the adapters touch Roblox services, and only when first used, so tests can
  supply fakes.
- **What Lune can't cover.** Lune has no real `OnServerEvent`. The Studio integration test in
  `tests/studio/` covers that wiring, and the Lune suite drives the pipeline through a mock
  adapter.

`tests/fixtures/loader/` is a tiny module tree that pins down the loader's behaviour
(`script.X`, `script.Parent.X`, `script.Parent.Parent.X`, caching, cycles, injected globals).

## Studio integration test

`tests/studio/` covers what Lune can't: the real `OnServerEvent` wiring and how values are
serialized over the network.

- `RemoteGuardTest.server.luau` creates temporary RemoteEvents. It guards `Attack` with a
  schema, `rate = 5` and `mode = "enforce"`, and guards `Emote` with the `Guard.event(remote, handler)`
  shorthand. It checks two developer errors (wrapping twice, `burst`), waits for the client, and
  prints a PASS/FAIL line for each check.
- `RemoteGuardTest.client.luau` sends:
  - valid payloads, including one that makes the handler error on purpose;
  - invalid payloads: wrong type, NaN, an extra key and a wrong argument count;
  - a flood of 50 calls.

  It pauses between phases so the rate bucket refills.

Temporary remotes are destroyed and connections disconnected after the run, even if it errors.

To run it, build the test place:

```bash
rojo build tests/studio/test.project.json -o RemoteGuardTest.rbxl
```

Then open `RemoteGuardTest.rbxl` in Studio, press **Play**, and read the Output window.
(You can also `rojo serve tests/studio/test.project.json` into an empty baseplate.) Expect
`[RemoteGuardStudioTest] ALL PASSED`, along with RemoteGuard's own violation lines and a
throttled `x.. in 10s` summary for the flood.
