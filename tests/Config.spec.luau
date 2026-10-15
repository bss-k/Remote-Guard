local Loader = require("./loader")
local TestKit = require("./TestKit")

local describe, it, eq, contains, throws = TestKit.describe, TestKit.it, TestKit.eq, TestKit.contains, TestKit.throws

local lib = Loader.new()
local Config = lib.require("Config")
local DevError = lib.require("DevError")
local t = lib.require("Schema").t

-- Stands in for a public API function: runs the work inside a DevError boundary, exactly
-- the way Guard.event will.
local function fakeEvent(config: any, global: any?): any
	return DevError.boundary(2, function()
		local resolvedGlobal = Config.validateGlobal(global or Config.defaults())
		return Config.resolve(config, resolvedGlobal, "Attack")
	end)
end

local function resolve(config: any, global: any?): any
	return fakeEvent(config, global)
end

local function configError(config: any, expected: string, global: any?)
	local message = throws(function()
		fakeEvent(config, global)
	end)
	contains(message, expected)
end

describe("Config", function()
	describe("defaults and three-state resolution", function()
		it("empty config resolves to safe defaults with everything optional off", function()
			local r = resolve({})
			eq(r.name, "Attack")
			eq(r.mode, "shadow")
			eq(r.schema, false)
			eq(r.rate, false)
			eq(r.globalRate, false)
			eq(r.bypass, false)
			eq(r.checks, false)
			eq(r.strikes, false)
			eq(r.log, true)
			eq(resolve(nil).mode, "shadow", "nil config is the same as {}")
		end)

		it("nil uses the global default, false turns off, a value turns on", function()
			local global = Config.defaults()
			global.rate = 10
			global.log = false
			eq(resolve({}, global).rate, 10, "nil -> global")
			eq(resolve({ rate = false }, global).rate, false, "false -> off")
			eq(resolve({ rate = 3 }, global).rate, 3, "value -> on")
			eq(resolve({ rate = { perSecond = 4 } }, global).rate, 4, "table form")
			eq(resolve({}, global).log, false)
			eq(resolve({ log = true }, global).log, true)
		end)

		it("takes mode, name, schema and global features", function()
			local global = Config.defaults()
			global.mode = "enforce"
			global.globalRate = { perSecond = 30 }
			local bypass = function()
				return false
			end
			global.bypass = bypass
			local schema = { id = t.integer() }
			local r = resolve({ mode = "shadow", name = "Swing", schema = schema }, global)
			eq(r.mode, "shadow")
			eq(r.name, "Swing")
			eq(r.schema, schema)
			eq(r.globalRate, 30)
			eq(r.bypass, bypass)
			eq(resolve({}, global).mode, "enforce")
		end)
	end)

	describe("developer errors", function()
		it("uses the documented format with the remote name", function()
			configError(
				{ rate = { perSecond = "5" } },
				'[RemoteGuard] Config error on "Attack": rate.perSecond must be a positive number, got "5"'
			)
		end)

		it("names the remote by config.name when given", function()
			configError({ name = "Swing", mode = "loud" }, 'Config error on "Swing": mode must be')
		end)

		it("rejects invalid rates", function()
			configError({ rate = 0 }, "rate must be a positive number, { perSecond = number } or false, got 0")
			configError({ rate = -1 }, "got -1")
			configError({ rate = 0 / 0 }, "got NaN")
			configError({ rate = "5" }, 'got "5"')
			configError({ rate = { perSecond = 5, extra = 1 } }, 'rate.unknown key "extra"')
		end)

		it("explains that burst was removed", function()
			configError({ rate = { perSecond = 5, burst = 10 } }, "rate.burst was removed; use perSecond")
		end)

		it("rejects unknown modes", function()
			configError({ mode = "enfroce" }, 'mode must be "shadow" or "enforce", got "enfroce"')
		end)

		it("rejects unknown keys and suggests the closest one", function()
			configError({ rates = 5 }, 'unknown key "rates" (did you mean "rate"?)')
			configError({ Schema = {} }, '(did you mean "schema"?)')
			configError({ zzzzzz = 1 }, 'unknown key "zzzzzz"; valid keys: schema, rate')
		end)

		it("rejects checks and strikes until their phases ship", function()
			configError({ checks = {} }, "checks are not available yet")
			configError({ strikes = 3 }, "strikes are not available yet")
			eq(resolve({ checks = false, strikes = false }).checks, false)
		end)

		it("rejects bad schema, log, name and config values", function()
			configError({ schema = 5 }, "schema must be a schema")
			configError({ log = "yes" }, 'log must be a boolean, got "yes"')
			configError({ name = "" }, "name must be a non-empty string")
			configError("fast", "config must be a table, got string")
			configError(t.integer(), "the config argument is a schema; pass it as { schema = ... }")
		end)

		it("reports malformed schemas with their path", function()
			local message = throws(function()
				DevError.boundary(2, Config.compileSchema, { id = t.integer, ok = t.boolean() }, "Attack")
			end)
			contains(message, '[RemoteGuard] Config error on "Attack": schema.id: expected a schema, got a function')
		end)

		it("reports a missing handler", function()
			local message = throws(function()
				DevError.boundary(2, Config.checkHandler, nil, "Attack")
			end)
			contains(message, 'Config error on "Attack": missing handler')
		end)

		it("validates Guard.config", function()
			local function global(overrides: { [string]: any }): any
				local g = Config.defaults()
				for k, v in overrides do
					(g :: any)[k] = v
				end
				return g
			end
			configError({}, 'Config error in Guard.config: unknown key "globalrate" (did you mean "globalRate"?)', {
				globalrate = 5,
			})
			configError({}, "Guard.config: printLevel must be", global({ printLevel = "verbose" }))
			configError({}, "Guard.config: globalRate.burst was removed", global({ globalRate = { burst = 1 } }))
			configError({}, "Guard.config: bypass must be a function", global({ bypass = true }))
			configError({}, "Guard.config: strikes are not available yet", global({ strikes = true }))
		end)
	end)

	describe("error level", function()
		it("points at the line that called the public API", function()
			local callLine
			local ok, err = pcall(function()
				callLine = debug.info(1, "l") + 1
				fakeEvent({ rates = 5 })
			end)
			eq(ok, false)
			contains(err, "Config.spec:" .. callLine .. ": [RemoteGuard] Config error")
		end)

		it("lets real bugs through unchanged", function()
			local ok, err = pcall(DevError.boundary, 2, function()
				error("boom", 0)
			end)
			eq(ok, false)
			eq(err, "boom")
		end)

		it("returns every value on success", function()
			local a, b, c = DevError.boundary(2, function()
				return 1, nil, 3
			end)
			eq(a, 1)
			eq(b, nil)
			eq(c, 3)
		end)
	end)
end)
