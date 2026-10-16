# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, minor releases may contain breaking changes.

## [Unreleased]

## [0.1.0-dev]

### Added

- Repository scaffold: Rojo project, Wally manifest, Rokit toolchain pins, Selene, StyLua, GitHub Actions CI.
- Lune test runner with a loader that runs the library's Roblox-style `require(script.Parent.X)` source unchanged.
- Shared types (`Types`) and schema combinators (`t.number`, `t.integer`, `t.string`, `t.boolean`, `t.literal`, `t.enum`,
  `t.vector3`, `t.unitVector3`, `t.instance`, `t.optional`, `t.array`, `t.struct`, `t.union`, `t.args`, `t.sensitive`),
  compiled once into validator closures with path-aware reasons.
- `RateLimiter`: per-player token buckets (`perSecond` only, lazy refill, injectable clock) with a per-player global budget
  that spends from both buckets only when both pass.
- `Config`: global defaults, three-state per-remote resolution, and developer errors raised at the caller's line
  (with "did you mean" suggestions for unknown keys).
- `Printer`: readable violation, handler-error and internal-error lines; payload previews (bounded, cycle-safe, `sensitive`
  values redacted); repeat throttling with `xN in 10s` summaries; `printLevel` filtering; Studio vs live payload profile.
- `Logger`: ring buffer of recent events (default 200), sinks called in isolated threads inside `pcall`, `addSink` /
  `removeSink` / `getRecent`. Default `Console` sink prints through the Printer and schedules repeat summaries.
- `Pipeline`: per-remote stage list built once (bypass, rate / globalRate, schema; checks reserved), shadow vs enforce,
  handler under `xpcall` with traceback, players who left are skipped, library bugs reported without breaking the remote.
- Public API: `Guard.event`, `Guard.wrap`, `Guard.t`, `Guard.config`, `Guard.logger`, `Guard.sinks`, `Guard.adapters`.
  RemoteEvent adapter (also accepts UnreliableRemoteEvent). Each transport can be wrapped once; `Disconnect()` frees it
  and clears its rate buckets. Rate buckets are cleared on `PlayerRemoving`.
- Studio integration test (`tests/studio/`), usage example (`examples/basic.server.luau`), full README.
- `t.any()`: accepts any value (including nil) without checks, for deliberately flexible arguments.
