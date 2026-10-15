local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq = TestKit.describe, TestKit.it, TestKit.eq

local RateLimiter = Loader.new().require("RateLimiter")

-- A clock the test moves by hand.
local function fakeClock()
	local now = 0
	return function()
		return now
	end, function(seconds: number)
		now += seconds
	end
end

local function newLimiter()
	local clock, advance = fakeClock()
	return RateLimiter.new({ clock = clock }), advance
end

-- Consumes until rejected; returns how many calls were allowed.
local function drain(limiter: any, player: any, key: any, perSecond: number): number
	local allowed = 0
	while allowed < 1000 and limiter:consume(player, key, perSecond) do
		allowed += 1
	end
	return allowed
end

local alice, bob = { Name = "Alice" }, { Name = "Bob" }

describe("RateLimiter", function()
	it("starts full and allows exactly perSecond calls at once", function()
		local limiter = newLimiter()
		eq(drain(limiter, alice, "Attack", 5), 5)
	end)

	it("returns a readable reason on rejection", function()
		local limiter = newLimiter()
		drain(limiter, alice, "Attack", 5)
		local ok, reason = limiter:consume(alice, "Attack", 5)
		eq(ok, false)
		eq(reason, "exceeded 5 calls/s")
	end)

	it("refills continuously at perSecond", function()
		local limiter, advance = newLimiter()
		drain(limiter, alice, "Attack", 5)
		advance(0.1) -- 0.5 tokens
		eq(limiter:consume(alice, "Attack", 5), false)
		advance(0.1) -- 1.0 tokens: exactly at the boundary
		eq(limiter:consume(alice, "Attack", 5), true)
		eq(limiter:consume(alice, "Attack", 5), false)
	end)

	it("caps tokens at capacity after a long idle", function()
		local limiter, advance = newLimiter()
		drain(limiter, alice, "Attack", 5)
		advance(3600)
		eq(drain(limiter, alice, "Attack", 5), 5)
	end)

	it("does not spend tokens on rejected calls", function()
		local limiter, advance = newLimiter()
		drain(limiter, alice, "Attack", 5)
		for _ = 1, 100 do
			limiter:consume(alice, "Attack", 5) -- spam while empty
		end
		advance(0.2)
		eq(limiter:consume(alice, "Attack", 5), true, "one token refilled despite spam")
	end)

	it("allows one call per period below 1/s", function()
		local limiter, advance = newLimiter()
		eq(drain(limiter, alice, "Slow", 0.5), 1)
		advance(1)
		eq(limiter:consume(alice, "Slow", 0.5), false)
		advance(1)
		eq(limiter:consume(alice, "Slow", 0.5), true)
	end)

	it("handles a clock that stalls or goes backwards", function()
		local limiter, advance = newLimiter()
		drain(limiter, alice, "Attack", 5)
		advance(-10)
		eq(limiter:consume(alice, "Attack", 5), false, "backwards adds nothing")
		advance(0.2) -- measured from the backwards point, not the old time
		eq(limiter:consume(alice, "Attack", 5), true)
		eq(limiter:consume(alice, "Attack", 5), false, "stalled clock adds nothing")
	end)

	it("isolates players and keys", function()
		local limiter = newLimiter()
		drain(limiter, alice, "Attack", 5)
		eq(limiter:consume(bob, "Attack", 5), true, "other player")
		eq(limiter:consume(alice, "Emote", 5), true, "other key")
	end)

	describe("global budget", function()
		it("requires both limits to pass", function()
			local limiter = newLimiter()
			local allowed = 0
			for _ = 1, 10 do
				if limiter:consumeWithGlobal(alice, "Attack", 100, 3) then
					allowed += 1
				end
			end
			eq(allowed, 3)
			local ok, reason, which = limiter:consumeWithGlobal(alice, "Emote", 100, 3)
			eq(ok, false)
			eq(reason, "exceeded global budget of 3 calls/s")
			eq(which, "GlobalRateLimit")
		end)

		it("spends no per-remote tokens when the global check fails", function()
			local limiter, advance = newLimiter()
			-- Use up the global budget on another remote.
			eq(drain(limiter, alice, RateLimiter.GLOBAL_KEY, 2), 2)
			for _ = 1, 10 do
				eq(limiter:consumeWithGlobal(alice, "Attack", 2, 2), false)
			end
			advance(10)
			-- Attack's bucket is still full: both of its tokens are available.
			eq(limiter:consume(alice, "Attack", 2), true)
			eq(limiter:consume(alice, "Attack", 2), true)
			eq(limiter:consume(alice, "Attack", 2), false)
		end)

		it("spends no global tokens when the per-remote check fails", function()
			local limiter = newLimiter()
			drain(limiter, alice, "Attack", 1)
			local ok, reason, which = limiter:consumeWithGlobal(alice, "Attack", 1, 2)
			eq(ok, false)
			eq(reason, "exceeded 1 calls/s")
			eq(which, "RateLimit")
			eq(drain(limiter, alice, RateLimiter.GLOBAL_KEY, 2), 2, "global bucket untouched")
		end)
	end)

	describe("cleanup", function()
		it("removePlayer drops every bucket for that player", function()
			local limiter = newLimiter()
			limiter:consumeWithGlobal(alice, "Attack", 5, 10)
			limiter:consume(bob, "Attack", 5)
			eq(limiter:countBuckets(), 3)
			limiter:removePlayer(alice)
			eq(limiter:countBuckets(), 1)
		end)

		it("removeKey drops that key for all players and empty player entries", function()
			local limiter = newLimiter()
			limiter:consume(alice, "Attack", 5)
			limiter:consume(alice, "Emote", 5)
			limiter:consume(bob, "Attack", 5)
			limiter:removeKey("Attack")
			eq(limiter:countBuckets(), 1)
			eq(drain(limiter, bob, "Attack", 5), 5, "a fresh bucket starts full")
		end)
	end)
end)
