local roblox = require("@lune/roblox")
local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, truthy, throws = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.throws

local Schema = Loader.new().require("Schema")
local t = Schema.t
local Vector3, Instance = roblox.Vector3, roblox.Instance

local function run(schema: any, value: any): (boolean, string?)
	local validator = Schema.compile(schema)
	return validator(value, 0)
end

local function accepts(schema: any, value: any)
	local ok, reason = run(schema, value)
	if not ok then
		error("expected accept, got: " .. tostring(reason), 2)
	end
end

local function rejects(schema: any, value: any, expectedReason: string)
	local ok, reason = run(schema, value)
	if ok then
		error("expected reject with " .. string.format("%q", expectedReason), 2)
	end
	eq(reason, expectedReason)
end

local function devError(body: () -> (), needle: string)
	throws(body, needle)
end

describe("Schema", function()
	describe("number / integer", function()
		it("accepts numbers in range and -0", function()
			accepts(t.number(0, 100), 50.5)
			accepts(t.number(), -1e300)
			accepts(t.integer(1, 1e6), 1e6)
			accepts(t.integer(), -0)
		end)

		it("rejects with exact reasons", function()
			rejects(t.number(0, 100), "5", "expected number, got string")
			rejects(t.number(0, 100), 250, "expected number in [0, 100], got 250")
			rejects(t.number(0), -1, "expected number >= 0, got -1")
			rejects(t.number(nil, 5), 6, "expected number <= 5, got 6")
			rejects(t.integer(), 2.5, "expected integer, got 2.5")
			rejects(t.integer(1, 100), 0, "expected integer in [1, 100], got 0")
			rejects(t.integer(), nil, "expected integer, got nil")
		end)

		it("rejects NaN and infinities", function()
			rejects(t.number(), 0 / 0, "expected finite number, got NaN")
			rejects(t.number(), math.huge, "expected finite number, got inf")
			rejects(t.integer(), -math.huge, "expected finite integer, got -inf")
		end)

		it("raises developer errors for bad bounds", function()
			devError(function()
				t.number(5, 1)
			end, "t.number: min (5) must not be greater than max (1)")
			devError(function()
				t.integer(0 / 0)
			end, "min must be a finite number")
		end)
	end)

	describe("string", function()
		it("defaults maxLen to 256", function()
			accepts(t.string(), string.rep("a", 256))
			rejects(t.string(), string.rep("a", 257), "expected string of at most 256 bytes, got 257 bytes")
		end)

		it("checks maxLen, pattern and odd characters", function()
			accepts(t.string(8), "\0\n\255")
			rejects(t.string(3), "abcd", "expected string of at most 3 bytes, got 4 bytes")
			accepts(t.string(16, "^%w+$"), "abc123")
			rejects(t.string(16, "^%w+$"), "abc 123", 'expected string matching pattern "^%w+$"')
			rejects(t.string(), 5, "expected string, got number")
		end)

		it("raises developer errors for negative maxLen and bad patterns", function()
			devError(function()
				t.string(-1)
			end, "maxLen must be a non-negative integer")
			devError(function()
				t.string(10, "[a")
			end, "invalid pattern")
		end)
	end)

	describe("boolean / literal / enum", function()
		it("boolean", function()
			accepts(t.boolean(), false)
			rejects(t.boolean(), 0, "expected boolean, got number")
		end)

		it("literal", function()
			accepts(t.literal("attack"), "attack")
			rejects(t.literal("attack"), "emote", 'expected "attack", got "emote"')
			rejects(t.literal(3), "3", "expected 3, got string")
		end)

		it("enum uses a precomputed set", function()
			local schema = t.enum({ "Rock", "Paper", "Scissors" })
			accepts(schema, "Paper")
			rejects(schema, "Lizard", 'expected one of "Rock", "Paper", "Scissors", got "Lizard"')
			rejects(schema, {}, 'expected one of "Rock", "Paper", "Scissors", got table')
		end)

		it("raises developer errors for empty or invalid enum values", function()
			devError(function()
				t.enum({})
			end, "t.enum: needs at least one value")
			devError(function()
				t.enum({ "a", {} :: any })
			end, "value 2 must be")
			devError(function()
				t.literal(nil :: any)
			end, "t.literal")
		end)
	end)

	describe("vector3 / unitVector3", function()
		it("accepts finite vectors and rejects NaN components", function()
			accepts(t.vector3(), Vector3.new(1, 2, 3))
			rejects(t.vector3(), Vector3.new(0 / 0, 0, 0), "expected Vector3 with finite components")
			rejects(t.vector3(), { X = 1, Y = 2, Z = 3 }, "expected Vector3, got table")
		end)

		it("checks unit length with tolerance", function()
			accepts(t.unitVector3(), Vector3.new(0, 1, 0))
			accepts(t.unitVector3(), Vector3.new(0, 1.005, 0))
			rejects(
				t.unitVector3(),
				Vector3.new(0, 2.5, 0),
				"expected unit Vector3 (|magnitude - 1| <= 0.01), got magnitude 2.5"
			)
			accepts(t.unitVector3(0.5), Vector3.new(0, 1.4, 0))
		end)
	end)

	describe("instance", function()
		local game = Instance.new("DataModel")
		local workspace = Instance.new("Workspace")
		workspace.Parent = game
		local part = Instance.new("Part")
		part.Parent = workspace

		it("checks type, class and ancestry", function()
			accepts(t.instance(), part)
			accepts(t.instance("BasePart", workspace), part)
			accepts(t.instance(), game)
			rejects(t.instance("Model"), part, "expected Instance of class Model, got Part")
			rejects(t.instance(nil, part), workspace, "expected Instance inside Part")
			rejects(t.instance(), "Part", "expected Instance, got string")
		end)

		it("rejects destroyed instances without erroring", function()
			local doomed = Instance.new("Part")
			doomed.Parent = workspace
			doomed:Destroy()
			rejects(t.instance("BasePart"), doomed, "expected Instance that has not been destroyed")
		end)
	end)

	describe("struct", function()
		it("treats a plain table as a strict struct with paths", function()
			local schema = { targetId = t.integer(1, 1e6) }
			accepts(schema, { targetId = 5 })
			rejects(schema, { targetId = "5" }, "targetId: expected integer, got string")
			rejects(schema, {}, "targetId: expected integer, got nil")
			rejects(schema, { targetId = 5, extra = true }, "extra: unexpected key")
			rejects(schema, nil, "expected table, got nil")
		end)

		it("allows unknown keys when strict = false", function()
			local schema = t.struct({ id = t.integer() }, { strict = false })
			accepts(schema, { id = 1, extra = "fine" })
		end)

		it("treats user fields named kind / type as plain fields", function()
			local schema = { kind = t.string(), type = t.literal("x") }
			accepts(schema, { kind = "anything", type = "x" })
			rejects(schema, { kind = 1, type = "x" }, "kind: expected string, got number")
		end)

		it("formats odd keys", function()
			rejects({ ["my key"] = t.boolean() }, { ["my key"] = 1 }, '["my key"]: expected boolean, got number')
			rejects({ a = t.boolean() }, { a = true, [3] = 1 }, "[3]: unexpected key")
		end)

		it("rejects tables with metatables", function()
			local value = setmetatable({ id = 1 }, {})
			rejects({ id = t.integer() }, value, "expected table, got table with a metatable")
		end)

		it("raises developer errors for bad struct options", function()
			devError(function()
				t.struct({}, { strct = true } :: any)
			end, "unknown option strct")
		end)
	end)

	describe("array", function()
		it("validates elements with index paths", function()
			local schema = { items = t.array({ x = t.number(0, 100) }) }
			accepts(schema, { items = { { x = 1 }, { x = 2 } } })
			rejects(schema, { items = { { x = 1 }, { x = 250 } } }, "items[2].x: expected number in [0, 100], got 250")
			accepts(t.array(t.integer()), {})
		end)

		it("rejects gaps, non-integer keys and oversized arrays", function()
			rejects(t.array(t.integer()), { 1, nil, 3 }, "expected array without gaps")
			rejects(t.array(t.integer()), { 1, x = 2 }, "expected array, got table with key .x")
			rejects(t.array(t.integer()), { [1.5] = 1 }, "expected array, got table with key [1.5]")
			rejects(t.array(t.integer(), 2), { 1, 2, 3 }, "expected array of at most 2 elements")
		end)

		it("defaults maxLen to 100 and stops early on huge tables", function()
			local huge = table.create(100000, 1)
			rejects(t.array(t.integer()), huge, "expected array of at most 100 elements")
		end)
	end)

	describe("any", function()
		it("accepts every value, including nil and hostile tables", function()
			local cyclic: any = {}
			cyclic.self = cyclic
			for _, value in { 1, 0 / 0, "x", true, Vector3.new(0 / 0, 0, 0), print, setmetatable({}, {}), cyclic } do
				accepts(t.any(), value)
			end
			accepts(t.any(), nil)
		end)

		it("skips only its own field inside a strict struct", function()
			local schema = { id = t.integer(), meta = t.any() }
			accepts(schema, { id = 1, meta = { anything = { goes = true } } })
			accepts(schema, { id = 1 })
			rejects(schema, { id = "1", meta = 5 }, "id: expected integer, got string")
			rejects(schema, { id = 1, meta = 5, extra = 1 }, "extra: unexpected key")
		end)

		it("works as a flexible positional argument", function()
			local schema = t.args(t.string(16), t.any())
			accepts(schema, table.pack("emote", { 1, 2 }))
			accepts(schema, table.pack("emote"))
			rejects(schema, table.pack(1, "x"), "argument 1: expected string, got number")
			rejects(schema, table.pack("emote", 1, 2), "expected 1 to 2 arguments, got 3")
		end)

		it("is described as any in union reasons", function()
			local ok = run(t.union({ t.integer(), t.any() }), "x")
			eq(ok, true)
		end)
	end)

	describe("optional / union", function()
		it("optional accepts nil", function()
			accepts({ note = t.optional(t.string()) }, {})
			rejects({ note = t.optional(t.string()) }, { note = 1 }, "note: expected string, got number")
		end)

		it("union accepts any option", function()
			local schema = t.union({ t.integer(), t.string(4) })
			accepts(schema, 3)
			accepts(schema, "abc")
			rejects(schema, true, "expected integer | string, got boolean")
		end)

		it("raises developer errors for empty unions", function()
			devError(function()
				t.union({})
			end, "t.union: needs at least one schema")
		end)
	end)

	describe("args", function()
		it("validates packed positional arguments and arity", function()
			local schema = t.args(t.integer(), t.string(32))
			accepts(schema, table.pack(1, "a"))
			rejects(schema, table.pack(1, "a", 3), "expected 2 arguments, got 3")
			rejects(schema, table.pack(1), "expected 2 arguments, got 1")
			rejects(schema, table.pack("1", "a"), "argument 1: expected integer, got string")
		end)

		it("lets trailing optional arguments be omitted", function()
			local schema = t.args(t.integer(), t.optional(t.string()))
			accepts(schema, table.pack(1))
			rejects(schema, table.pack(), "expected 1 to 2 arguments, got 0")
			accepts(t.args(), table.pack())
		end)

		it("reports args in compile info", function()
			local _, info = Schema.compile(t.args(t.integer()))
			eq(info.args, true)
			local _, other = Schema.compile({ a = t.integer() })
			eq(other.args, false)
		end)

		it("cannot be nested", function()
			devError(function()
				Schema.compile({ inner = t.args(t.integer()) })
			end, "schema.inner: t.args(...) can only be used as the whole schema")
		end)
	end)

	describe("sensitive", function()
		it("validates like the inner schema and hides the value", function()
			local schema = { pin = t.sensitive(t.integer(0, 9999)) }
			accepts(schema, { pin = 1234 })
			rejects(schema, { pin = 123456 }, "pin: expected integer in [0, 9999], got <redacted>")
		end)

		it("returns a redaction tree for the Printer", function()
			local _, info = Schema.compile({
				pin = t.sensitive(t.integer()),
				list = t.array({ secret = t.sensitive(t.string()) }),
				plain = t.string(),
			})
			eq(info.redaction.fields.pin, true)
			eq(info.redaction.fields.list.each.fields.secret, true)
			eq(info.redaction.fields.plain, nil)
			local _, none = Schema.compile({ plain = t.string() })
			eq(none.redaction, nil)
		end)
	end)

	describe("compile errors", function()
		it("rejects array-style plain tables with a pointer to t.array / t.args", function()
			devError(function()
				Schema.compile({ t.integer(), t.string() })
			end, "use t.array(schema) for a list or t.args(a, b)")
		end)

		it("rejects non-schema values with their path", function()
			devError(function()
				Schema.compile({ id = 5 })
			end, "schema.id: expected a schema, got number")
			devError(function()
				Schema.compile({ id = t.integer })
			end, "combinators must be called")
		end)

		it("rejects self-referencing plain tables", function()
			local loop: any = {}
			loop.child = loop
			devError(function()
				Schema.compile(loop)
			end, "schema contains itself")
		end)
	end)

	describe("hostile input", function()
		it("does not hang or throw on cyclic values", function()
			local cyclic: any = { a = {} }
			cyclic.a.a = cyclic
			rejects({ a = { a = { b = t.integer() } } }, cyclic, "a.a.b: expected integer, got nil")
		end)

		it("enforces the max table depth of 8", function()
			local function nest(levels: number, leaf: any): any
				local schema = leaf
				for _ = 1, levels do
					schema = { x = schema }
				end
				return schema
			end
			accepts(nest(8, t.integer()), nest(8, 1))
			rejects(nest(9, t.integer()), nest(9, 1), "x.x.x.x.x.x.x.x: table nested deeper than 8 levels")
		end)

		it("survives odd value types everywhere", function()
			local odd = { coroutine.create(function() end), print, newproxy(), Vector3.zero, true, -0 }
			local schema = { a = t.union({ t.integer(), t.array(t.string()) }) }
			for _, value in odd do
				local ok = run(schema, value)
				eq(ok, false)
				run(schema, { a = value })
			end
			truthy(true)
		end)
	end)
end)
