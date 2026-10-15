--!strict
--[[
	Per-player token buckets. One rule: `perSecond`.

	Each bucket holds up to `perSecond` tokens (at least 1) and refills continuously at
	`perSecond` tokens per second. Refill is computed lazily when a call arrives, so there is
	no loop and an idle bucket costs nothing:

		tokens = min(capacity, tokens + elapsed * perSecond)
		if tokens >= 1 then spend 1 and allow, else reject (and spend nothing)

	Buckets live at buckets[player][key]. The reserved key "__global" holds a player's budget
	across every guarded remote. Pure module: no Roblox services; the clock is injectable.
]]

local GLOBAL_KEY = "__global"
-- Float tolerance: 0.2s at 5/s can come out as 0.9999999999 tokens. Without this, a client
-- calling at exactly the allowed rate would be rejected now and then.
local EPSILON = 1e-9

type Bucket = { tokens: number, last: number }

export type Options = {
	clock: (() -> number)?,
}

export type RateLimiter = {
	consume: (self: RateLimiter, player: any, key: any, perSecond: number) -> (boolean, string?),
	consumeWithGlobal: (
		self: RateLimiter,
		player: any,
		key: any,
		perSecond: number,
		globalPerSecond: number
	) -> (boolean, string?, ("RateLimit" | "GlobalRateLimit")?),
	removePlayer: (self: RateLimiter, player: any) -> (),
	removeKey: (self: RateLimiter, key: any) -> (),
	countBuckets: (self: RateLimiter) -> number,
}

local RateLimiter = {}
RateLimiter.GLOBAL_KEY = GLOBAL_KEY

local function reasonFor(perSecond: number, isGlobal: boolean): string
	local rate = if perSecond == math.floor(perSecond) then string.format("%d", perSecond) else tostring(perSecond)
	if isGlobal then
		return "exceeded global budget of " .. rate .. " calls/s"
	end
	return "exceeded " .. rate .. " calls/s"
end

function RateLimiter.new(options: Options?): RateLimiter
	local clock = (options and options.clock) or os.clock
	local buckets: { [any]: { [any]: Bucket } } = {}

	-- Returns the bucket for (player, key), refilled up to now.
	local function refill(player: any, key: any, perSecond: number): Bucket
		local now = clock()
		-- Below 1/s, a capacity of perSecond would never reach one whole token.
		local capacity = math.max(1, perSecond)
		local perPlayer = buckets[player]
		if perPlayer == nil then
			perPlayer = {}
			buckets[player] = perPlayer
		end
		local bucket = perPlayer[key]
		if bucket == nil then
			bucket = { tokens = capacity, last = now }
			perPlayer[key] = bucket
			return bucket
		end
		-- A clock that stalls or goes backwards adds nothing (never negative).
		local elapsed = math.max(0, now - bucket.last)
		bucket.tokens = math.min(capacity, bucket.tokens + elapsed * perSecond)
		bucket.last = now
		return bucket
	end

	local limiter = {}

	function limiter.consume(_self: RateLimiter, player: any, key: any, perSecond: number): (boolean, string?)
		local bucket = refill(player, key, perSecond)
		if bucket.tokens < 1 - EPSILON then
			return false, reasonFor(perSecond, key == GLOBAL_KEY)
		end
		bucket.tokens = math.max(0, bucket.tokens - 1)
		return true, nil
	end

	-- Checks both the remote's bucket and the player's global bucket, then spends from both
	-- only if both pass. A call rejected by either limit costs no tokens anywhere.
	function limiter.consumeWithGlobal(
		_self: RateLimiter,
		player: any,
		key: any,
		perSecond: number,
		globalPerSecond: number
	): (boolean, string?, ("RateLimit" | "GlobalRateLimit")?)
		local bucket = refill(player, key, perSecond)
		local global = refill(player, GLOBAL_KEY, globalPerSecond)
		if bucket.tokens < 1 - EPSILON then
			return false, reasonFor(perSecond, false), "RateLimit"
		elseif global.tokens < 1 - EPSILON then
			return false, reasonFor(globalPerSecond, true), "GlobalRateLimit"
		end
		bucket.tokens = math.max(0, bucket.tokens - 1)
		global.tokens = math.max(0, global.tokens - 1)
		return true, nil, nil
	end

	-- Called when a player leaves.
	function limiter.removePlayer(_self: RateLimiter, player: any)
		buckets[player] = nil
	end

	-- Called when a remote is disconnected. Runs once per disconnect, not per call.
	function limiter.removeKey(_self: RateLimiter, key: any)
		for player, perPlayer in buckets do
			perPlayer[key] = nil
			if next(perPlayer) == nil then
				buckets[player] = nil
			end
		end
	end

	-- For tests and debugging: total live buckets across all players.
	function limiter.countBuckets(_self: RateLimiter): number
		local count = 0
		for _, perPlayer in buckets do
			for _ in perPlayer do
				count += 1
			end
		end
		return count
	end

	return (limiter :: any) :: RateLimiter
end

return RateLimiter
