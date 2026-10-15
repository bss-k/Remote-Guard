--!strict
--[[
	Builds the per-remote call function, once, at wrap time:

		[bypass?] -> [rate / globalRate] -> [schema] -> [checks: PHASE 3] -> handler (xpcall)

	Only enabled stages go into the list, so a disabled feature costs nothing per call.
	Each stage returns (ok, violationType?, reason?). On a failure the violation is
	reported (strikes hook, then logger); "enforce" drops the call, "shadow" keeps running
	the remaining stages (so every violation is logged) and still calls the handler with
	the raw arguments.
]]

local Preview = require(script.Parent.Preview)
local RateLimiter = require(script.Parent.RateLimiter)
local Types = require(script.Parent.Types)

type Event = Types.Event
type Packed = { n: number, [number]: any }
type Stage = (player: Player, packed: Packed) -> (boolean, Types.ViolationType?, string?)

export type Deps = {
	limiter: RateLimiter.RateLimiter,
	logger: { emit: (self: any, event: Event) -> () },
	remoteName: string,
	transportName: string,
	key: any, -- unique per wrapped transport; rate buckets are stored under it
	validator: Types.Validator?,
	schemaInfo: Types.SchemaInfo?,
	serverId: string,
	now: (() -> number)?, -- event timestamps, default os.time
	logCalls: (() -> boolean)?, -- emit "call" events for accepted calls (printLevel "all")
	onInternalError: (message: string, traceback: string) -> (),
}

local Pipeline = {}

local function captureError(err: unknown): { message: string, traceback: string }
	local traceback = string.gsub(debug.traceback("", 2), "^\n+", "")
	return { message = tostring(err), traceback = traceback }
end

-- Returns the ordered stages for this config plus their names (for tests and debugging).
local function buildStages(resolved: Types.ResolvedConfig, deps: Deps): ({ Stage }, { string })
	local stages: { Stage } = {}
	local names: { string } = {}
	local limiter, key = deps.limiter, deps.key
	local rate, globalRate = resolved.rate, resolved.globalRate

	-- Bypass is not a failing stage: it short-circuits to the handler, so onCall runs it
	-- before the loop. It is listed here so the names show the full order.
	if resolved.bypass then
		table.insert(names, "bypass")
	end

	if rate and globalRate then
		table.insert(names, "rate+globalRate")
		table.insert(stages, function(player)
			local ok, reason, which = limiter:consumeWithGlobal(player, key, rate, globalRate)
			return ok, which, reason
		end)
	elseif rate then
		table.insert(names, "rate")
		table.insert(stages, function(player)
			local ok, reason = limiter:consume(player, key, rate)
			return ok, "RateLimit", reason
		end)
	elseif globalRate then
		table.insert(names, "globalRate")
		table.insert(stages, function(player)
			local ok, reason = limiter:consume(player, RateLimiter.GLOBAL_KEY, globalRate)
			return ok, "GlobalRateLimit", reason
		end)
	end

	local validator = deps.validator
	if resolved.schema and validator then
		table.insert(names, "schema")
		if deps.schemaInfo and deps.schemaInfo.args then
			table.insert(stages, function(_player, packed)
				local ok, reason = validator(packed, 0)
				return ok, "Schema", reason
			end)
		else
			-- A single (non-args) schema describes exactly one argument.
			table.insert(stages, function(_player, packed)
				if packed.n ~= 1 then
					return false, "Schema", "expected 1 argument, got " .. packed.n
				end
				local ok, reason = validator(packed[1], 0)
				return ok, "Schema", reason
			end)
		end
	end

	-- PHASE 3: checks middleware stages are appended here.
	return stages, names
end

function Pipeline.build(
	resolved: Types.ResolvedConfig,
	handler: (Player, ...any) -> (),
	deps: Deps
): ((player: Player, ...any) -> (), { string })
	local stages, names = buildStages(resolved, deps)
	local enforce = resolved.mode == "enforce"
	local log = resolved.log
	local bypass = resolved.bypass
	local logger = deps.logger
	local now = deps.now or os.time
	local logCalls = deps.logCalls
	local singleArgument = resolved.schema ~= false and not (deps.schemaInfo and deps.schemaInfo.args)
	local redaction: Types.Redaction? = nil
	if deps.schemaInfo and deps.schemaInfo.redaction then
		redaction = if singleArgument
			then { fields = { [1] = deps.schemaInfo.redaction } }
			else deps.schemaInfo.redaction
	end

	local function makeEvent(kind: Types.EventKind, player: Player, packed: Packed): Event
		return {
			kind = kind,
			remote = deps.remoteName,
			transport = deps.transportName,
			userId = player.UserId,
			playerName = player.Name,
			payloadPreview = Preview.arguments(packed, redaction),
			t = now(),
			serverId = deps.serverId,
			mode = resolved.mode,
		}
	end

	local function report(player: Player, packed: Packed, violation: Types.ViolationType, reason: string?)
		-- PHASE 2: Violations.add(player, violation, deps.remoteName) -- strikes hook
		if log then
			local event = makeEvent("violation", player, packed)
			event.violation = violation
			event.reason = reason
			logger:emit(event)
		end
	end

	local function reportHandlerError(player: Player, packed: Packed, captured: { message: string, traceback: string })
		if log then
			local event = makeEvent("handlerError", player, packed)
			event.reason = captured.message
			event.traceback = captured.traceback
			logger:emit(event)
		end
	end

	local function runHandler(player: Player, packed: Packed)
		if player.Parent == nil then
			return -- the player left before we got here
		end
		local ok, captured
		if singleArgument then
			ok, captured = xpcall(handler, captureError, player, packed[1])
		else
			ok, captured = xpcall(handler, captureError, player, table.unpack(packed, 1, packed.n))
		end
		if not ok then
			reportHandlerError(player, packed, captured)
		end
	end

	-- Runs every stage. Returns true if the handler should run.
	local function runStages(player: Player, packed: Packed): boolean
		local passed = true
		for _, stage in stages do
			local ok, violation, reason = stage(player, packed)
			if not ok then
				passed = false
				report(player, packed, violation :: Types.ViolationType, reason)
				if enforce then
					return false
				end
			end
		end
		if passed and log and logCalls and logCalls() then
			logger:emit(makeEvent("call", player, packed))
		end
		return true
	end

	local function onCall(player: Player, ...: any)
		if player.Parent == nil then
			-- Already left (calls can arrive after PlayerRemoving): do nothing, so no rate
			-- buckets are recreated for a player whose buckets were just cleared.
			return
		end
		local packed: Packed = table.pack(...)
		if bypass then
			local ok, skip = xpcall(bypass, captureError, player)
			if ok and skip == true then
				runHandler(player, packed)
				return
			elseif not ok then
				local captured = skip :: any
				captured.message = "bypass function errored: " .. captured.message
				reportHandlerError(player, packed, captured)
			end
		end
		-- Library bugs inside the stages must never take the remote down.
		local ok, result = xpcall(runStages, captureError, player, packed)
		if not ok then
			deps.onInternalError(result.message, result.traceback)
			if enforce then
				return -- fail closed when enforcing
			end
		elseif result == false then
			return
		end
		runHandler(player, packed)
	end

	return onCall, names
end

return Pipeline
