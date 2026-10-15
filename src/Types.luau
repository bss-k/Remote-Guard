--!strict
--[[
	Shared types for RemoteGuard. No runtime logic beyond the version string.
]]

local Types = {}

Types.VERSION = "0.1.0-dev"

-- Schemas -------------------------------------------------------------------

-- A schema is either a node built by `Guard.t` (tagged with a private marker key) or a plain
-- table of string keys -> schemas, which is shorthand for a strict struct.
export type Schema = { [any]: any }

-- Compiled per-call check. `depth` is the table depth of `value` (0 at the top).
-- Returns false and a reason with a path ("items[2].x: expected number ...") on failure.
export type Validator = (value: unknown, depth: number) -> (boolean, string?)

-- Where `sensitive` values sit inside a payload, so previews can print <redacted>.
-- `true` redacts the whole value; `fields` maps keys (or argument positions) to their own
-- redaction; `each` applies to every element of an array.
export type Redaction = true | { fields: { [any]: Redaction }?, each: Redaction? }

export type SchemaInfo = {
	args: boolean, -- true when the schema is t.args(...) and validates packed arguments
	redaction: Redaction?,
}

-- Config --------------------------------------------------------------------

export type Mode = "shadow" | "enforce"
export type PrintLevel = "all" | "violations" | "errors" | "off"

export type RateConfig = { perSecond: number }

-- Every optional property follows one rule: nil = use the global default, false = off,
-- a value = on with those settings.
export type RemoteConfig = {
	schema: Schema?,
	rate: (number | RateConfig | false)?,
	mode: Mode?,
	checks: false?, -- PHASE 3
	strikes: false?, -- PHASE 2
	log: boolean?,
	name: string?,
}

export type GlobalConfig = {
	mode: Mode,
	rate: number | RateConfig | false,
	globalRate: number | RateConfig | false,
	printLevel: PrintLevel,
	printPayloads: boolean?,
	log: boolean,
	bypass: ((player: Player) -> boolean)?,
	strikes: false, -- PHASE 2
}

-- One remote's settings after merging with Guard.config. Every feature is a concrete
-- value or false, so the pipeline never has to look at defaults again.
export type ResolvedConfig = {
	name: string,
	mode: Mode,
	schema: Schema | false,
	rate: number | false, -- perSecond
	globalRate: number | false, -- perSecond
	bypass: ((player: Player) -> boolean) | false,
	checks: false, -- PHASE 3
	strikes: false, -- PHASE 2
	log: boolean,
}

-- Logging -------------------------------------------------------------------

export type EventKind = "violation" | "call" | "handlerError"
export type ViolationType = "RateLimit" | "GlobalRateLimit" | "Schema" | "Check"

export type Event = {
	kind: EventKind,
	remote: string,
	transport: string,
	userId: number,
	playerName: string,
	violation: ViolationType?,
	reason: string?,
	payloadPreview: string?,
	traceback: string?,
	t: number,
	serverId: string,
	mode: Mode,
}

export type Sink = {
	name: string,
	minSeverity: string?,
	write: (events: { Event }) -> (),
}

-- Transports ----------------------------------------------------------------

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

-- Plugs one transport type (RemoteEvent, later others) into the pipeline.
export type Adapter = {
	name: string,
	validate: (transport: unknown) -> (boolean, string?),
	connect: (transport: any, onCall: (player: Player, ...any) -> ()) -> Connection,
	getName: (transport: any) -> string,
}

return Types
