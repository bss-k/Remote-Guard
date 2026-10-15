--[[
	Tiny test harness: describe / it, plus a handful of assertions. No dependencies.
]]

local TestKit = {}

local passed = 0
local failed = 0
local failures: { string } = {}
local scope: { string } = {}

local function render(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function fail(label: string?, message: string)
	error((if label then label .. ": " else "") .. message, 3)
end

function TestKit.describe(name: string, body: () -> ())
	table.insert(scope, name)
	body()
	table.remove(scope)
end

function TestKit.it(name: string, body: () -> ())
	local fullName = table.concat(scope, " > ") .. " > " .. name
	local ok, err = xpcall(body, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, fullName .. "\n    " .. string.gsub(tostring(err), "\n", "\n    "))
	end
end

function TestKit.eq(actual: any, expected: any, label: string?)
	-- NaN ~= NaN, so compare it explicitly.
	if actual ~= expected and not (actual ~= actual and expected ~= expected) then
		fail(label, string.format("expected %s, got %s", render(expected), render(actual)))
	end
end

function TestKit.truthy(value: any, label: string?)
	if not value then
		fail(label, "expected a truthy value, got " .. render(value))
	end
end

function TestKit.falsy(value: any, label: string?)
	if value then
		fail(label, "expected a falsy value, got " .. render(value))
	end
end

function TestKit.contains(haystack: any, needle: string, label: string?)
	if type(haystack) ~= "string" or string.find(haystack, needle, 1, true) == nil then
		fail(label, string.format("expected %s to contain %s", render(haystack), render(needle)))
	end
end

function TestKit.notContains(haystack: any, needle: string, label: string?)
	if type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil then
		fail(label, string.format("expected %s not to contain %s", render(haystack), render(needle)))
	end
end

-- Runs `body`, expects it to throw, and returns the error message.
function TestKit.throws(body: () -> (), needle: string?): string
	local ok, err = pcall(body)
	if ok then
		fail(nil, "expected an error" .. (if needle then " containing " .. render(needle) else ""))
	end
	local message = tostring(err)
	if needle ~= nil and string.find(message, needle, 1, true) == nil then
		fail(nil, string.format("expected error containing %s, got %s", render(needle), render(message)))
	end
	return message
end

-- Prints failures and totals. Returns true when everything passed.
function TestKit.summary(): boolean
	for _, failure in failures do
		print("FAIL " .. failure)
	end
	print(string.format("\n%d passed, %d failed", passed, failed))
	return failed == 0
end

return TestKit
