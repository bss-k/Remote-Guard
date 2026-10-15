local roblox = require("@lune/roblox")
local Fakes = require("./Fakes")
local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, truthy, contains, throws =
	TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.contains, TestKit.throws

local MockAdapter = Fakes.MockAdapter

-- A fresh library instance per test, with a fake `game` and the Console sink removed so test
-- output stays quiet. Events are read back through Guard.logger.getRecent().
local function fresh(): (any, any)
	local game = Fakes.game()
	local Guard = Loader.new({ globals = { game = game } }).require()
	Guard.logger.removeSink("Console")
	return Guard, game
end

local alice = Fakes.player("Alice", 1)

describe("Guard", function()
	describe("loading", function()
		it("touches no Roblox services at require time", function()
			local game = Fakes.game()
			local Guard = Loader.new({ globals = { game = game } }).require()
			eq(game.serviceCalls, 0)
			eq(type(Guard.t.integer), "function")
			eq(Guard.config.mode, "shadow")
			eq(Guard.config.rate, false)
		end)

		it("exposes the documented surface", function()
			local Guard = fresh()
			eq(type(Guard.wrap), "function")
			eq(type(Guard.event), "function")
			eq(Guard.adapters.RemoteEvent.name, "RemoteEvent")
			eq(Guard.sinks.Console.name, "Console")
			eq(type(Guard.logger.getRecent), "function")
		end)
	end)

	describe("wrap", function()
		it("guards calls end to end", function()
			local Guard = fresh()
			local t = Guard.t
			local remote = Fakes.transport("Attack")
			local received = {}
			Guard.wrap(
				remote,
				MockAdapter,
				{ schema = { targetId = t.integer(1, 1e6) }, rate = 5, mode = "enforce" },
				function(player, data)
					table.insert(received, data.targetId)
				end
			)
			Fakes.fire(remote, alice, { targetId = 7 })
			Fakes.fire(remote, alice, { targetId = "7" })
			eq(#received, 1)
			local events = Guard.logger.getRecent()
			eq(#events, 1)
			eq(events[1].remote, "Attack")
			eq(events[1].transport, "Mock")
			eq(events[1].reason, "targetId: expected integer, got string")
			eq(events[1].serverId, "studio")
		end)

		it("an empty config behaves like a plain connection", function()
			local Guard = fresh()
			local remote = Fakes.transport("Emote")
			local got
			Guard.wrap(remote, MockAdapter, {}, function(_, a, b)
				got = { a, b }
			end)
			Fakes.fire(remote, alice, "wave", 2)
			eq(got[1], "wave")
			eq(got[2], 2)
			eq(#Guard.logger.getRecent(), 0)
			eq(Guard._internal.countBuckets(), 0, "no rate buckets when rate is off")
		end)

		it("reads Guard.config at wrap time", function()
			local Guard = fresh()
			Guard.config.mode = "enforce"
			Guard.config.rate = 1
			local remote = Fakes.transport("Attack")
			local count = 0
			Guard.wrap(remote, MockAdapter, nil, function()
				count += 1
			end)
			Fakes.fire(remote, alice)
			Fakes.fire(remote, alice)
			eq(count, 1)
		end)

		it("emits call events when printLevel is all", function()
			local Guard = fresh()
			Guard.config.printLevel = "all"
			local remote = Fakes.transport("Emote")
			Guard.wrap(remote, MockAdapter, {}, function() end)
			Fakes.fire(remote, alice, "wave")
			eq(Guard.logger.getRecent()[1].kind, "call")
		end)
	end)

	describe("connections and cleanup", function()
		it("Disconnect stops calls, frees the registry and clears buckets", function()
			local Guard = fresh()
			local remote = Fakes.transport("Attack")
			local count = 0
			local connection = Guard.wrap(remote, MockAdapter, { rate = 5 }, function()
				count += 1
			end)
			Fakes.fire(remote, alice)
			eq(Guard._internal.countBuckets(), 1)
			connection:Disconnect()
			connection:Disconnect() -- idempotent
			Fakes.fire(remote, alice)
			eq(count, 1)
			eq(Guard._internal.countBuckets(), 0)
			Guard.wrap(remote, MockAdapter, {}, function() end) -- can be wrapped again
		end)

		it("rejects wrapping the same transport twice", function()
			local Guard = fresh()
			local remote = Fakes.transport("Attack")
			Guard.wrap(remote, MockAdapter, {}, function() end)
			throws(function()
				Guard.wrap(remote, MockAdapter, {}, function() end)
			end, 'Config error on "Attack": this Mock is already wrapped')
		end)

		it("allows two transports with the same Name and keeps their buckets apart", function()
			local Guard = fresh()
			local a, b = Fakes.transport("Attack"), Fakes.transport("Attack")
			local counts = { a = 0, b = 0 }
			Guard.wrap(a, MockAdapter, { rate = 1, mode = "enforce" }, function()
				counts.a += 1
			end)
			Guard.wrap(b, MockAdapter, { rate = 1, mode = "enforce", name = "AttackB" }, function()
				counts.b += 1
			end)
			Fakes.fire(a, alice)
			Fakes.fire(b, alice)
			eq(counts.a, 1)
			eq(counts.b, 1, "b has its own bucket")
		end)

		it("connects PlayerRemoving once, lazily, and clears that player's buckets", function()
			local Guard, game = fresh()
			eq(game.countPlayerRemovingListeners(), 0)
			local a, b = Fakes.transport("A"), Fakes.transport("B")
			Guard.wrap(a, MockAdapter, { rate = 5 }, function() end)
			Guard.wrap(b, MockAdapter, { rate = 5 }, function() end)
			eq(game.countPlayerRemovingListeners(), 1)
			Fakes.fire(a, alice)
			Fakes.fire(b, alice)
			eq(Guard._internal.countBuckets(), 2)
			game:firePlayerRemoving(alice)
			eq(Guard._internal.countBuckets(), 0)
		end)

		it("does not recreate buckets for a player who already left", function()
			local Guard, game = fresh()
			local remote = Fakes.transport("Attack")
			local count = 0
			Guard.wrap(remote, MockAdapter, { rate = 5 }, function()
				count += 1
			end)
			local bob = Fakes.player("Bob", 2)
			game:firePlayerRemoving(bob)
			bob.Parent = nil
			Fakes.fire(remote, bob)
			eq(count, 0)
			eq(Guard._internal.countBuckets(), 0)
		end)
	end)

	describe("developer errors", function()
		it("point at the caller's line", function()
			local Guard = fresh()
			local remote = Fakes.transport("Attack")
			local line
			local ok, err = pcall(function()
				line = debug.info(1, "l") + 1
				Guard.wrap(remote, MockAdapter, { rates = 5 }, function() end)
			end)
			eq(ok, false)
			contains(err, "Guard.spec:" .. line .. ': [RemoteGuard] Config error on "Attack": unknown key "rates"')
		end)

		it("cover the handler, adapter, transport and Guard.config", function()
			local Guard = fresh()
			local remote = Fakes.transport("Attack")
			throws(function()
				Guard.wrap(remote, MockAdapter, {})
			end, 'Config error on "Attack": missing handler')
			throws(function()
				Guard.wrap(remote, {}, {}, function() end)
			end, "invalid adapter")
			throws(function()
				Guard.wrap("not a transport", MockAdapter, {}, function() end)
			end, "invalid transport for the Mock adapter: expected a mock transport, got string")
			Guard.config.printLevl = "all"
			throws(function()
				Guard.wrap(remote, MockAdapter, {}, function() end)
			end, 'Guard.config: unknown key "printLevl" (did you mean "printLevel"?)')
		end)

		it("Guard.event accepts the (remote, handler) shorthand and checks the remote", function()
			local Guard = fresh()
			throws(function()
				Guard.event({}, function() end)
			end, "invalid transport for the RemoteEvent adapter: expected a RemoteEvent, got table")
			local remote = roblox.Instance.new("RemoteEvent")
			remote.Name = "Attack"
			throws(function()
				Guard.event(remote, { schema = { id = 5 } }, function() end)
			end, 'Config error on "Attack": schema.id: expected a schema, got number')
			throws(function()
				Guard.event(remote, { rate = 5 })
			end, "missing handler")
		end)
	end)

	describe("logger API", function()
		it("works with dot and colon calls", function()
			local Guard = fresh()
			local seen = 0
			Guard.logger.addSink({
				name = "Count",
				write = function(events)
					seen += #events
				end,
			})
			local remote = Fakes.transport("Attack")
			Guard.wrap(remote, MockAdapter, { schema = { id = Guard.t.integer() } }, function() end)
			Fakes.fire(remote, alice, {})
			eq(seen, 1)
			eq(#Guard.logger:getRecent(1), 1)
			eq(Guard.logger:removeSink("Count"), true)
			truthy(Guard.logger.addSink(Guard.sinks.Console) == nil, "Console can be re-added")
		end)
	end)
end)

describe("RemoteEvent adapter", function()
	local Adapter = Loader.new().require("Adapters/RemoteEvent")

	it("accepts RemoteEvent and UnreliableRemoteEvent", function()
		eq(Adapter.validate(roblox.Instance.new("RemoteEvent")), true)
		eq(Adapter.validate(roblox.Instance.new("UnreliableRemoteEvent")), true)
	end)

	it("rejects other values with a readable reason", function()
		local ok, reason = Adapter.validate(roblox.Instance.new("RemoteFunction"))
		eq(ok, false)
		eq(reason, "expected a RemoteEvent, got RemoteFunction")
		local _, other = Adapter.validate("Attack")
		eq(other, "expected a RemoteEvent, got string")
	end)

	it("uses the instance Name", function()
		local remote = roblox.Instance.new("RemoteEvent")
		remote.Name = "Emote"
		eq(Adapter.getName(remote), "Emote")
	end)
end)
