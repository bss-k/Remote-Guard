--!strict
--[[
	Developer (configuration) errors.

	Problems are raised deep inside the library as tagged error objects. Each public API
	function runs its work through `DevError.boundary`, which turns a tagged error into a
	plain message raised at the API caller's line, so the traceback points at the user's
	`Guard.event(...)` call no matter how deep the check was. Untagged errors (real bugs)
	pass through unchanged.
]]

local DevError = {}

local TAG = table.freeze({})

type Tagged = { message: string }

local taggedMeta = {
	__tostring = function(self: Tagged): string
		return self.message
	end,
}

-- [RemoteGuard] Config error on "Attack": <message>
function DevError.format(remoteName: string?, message: string): string
	if remoteName then
		return string.format('[RemoteGuard] Config error on "%s": %s', remoteName, message)
	end
	return "[RemoteGuard] Config error: " .. message
end

function DevError.raise(remoteName: string?, message: string): never
	error(setmetatable({ [TAG] = true, message = DevError.format(remoteName, message) }, taggedMeta), 0)
end

function DevError.raiseGlobal(message: string): never
	error(
		setmetatable({ [TAG] = true, message = "[RemoteGuard] Config error in Guard.config: " .. message }, taggedMeta),
		0
	)
end

function DevError.is(err: unknown): boolean
	return type(err) == "table" and rawget(err :: any, TAG) == true
end

-- Runs `fn(...)`. A developer error is re-raised as a string at `level` relative to the
-- function that called `boundary` (2 = that function's caller, like `error(msg, 2)`).
function DevError.boundary<A..., R...>(level: number, fn: (A...) -> R..., ...: A...): R...
	local result = table.pack(pcall(fn, ...))
	if result[1] then
		return table.unpack(result, 2, result.n)
	end
	local err = result[2]
	if DevError.is(err) then
		-- +1 because this frame (boundary) sits between the API function and error().
		error((err :: Tagged).message, level + 1)
	end
	error(err, 0)
end

local function distance(a: string, b: string): number
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end
	for i = 1, #a do
		local current = { [0] = i }
		for j = 1, #b do
			local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#b]
end

-- 'unknown key "rates" (did you mean "rate"?); valid keys: ...'
function DevError.unknownKey(key: unknown, valid: { string }): string
	local shown = if type(key) == "string" then string.format("%q", key) else tostring(key)
	local suggestion: string? = nil
	if type(key) == "string" and #key <= 32 then
		local lowered = string.lower(key)
		local best = 3 -- only suggest within 2 edits
		for _, candidate in valid do
			local d = distance(lowered, string.lower(candidate))
			if d < best then
				best, suggestion = d, candidate
			end
		end
	end
	return "unknown key "
		.. shown
		.. (if suggestion then string.format(' (did you mean "%s"?)', suggestion) else "")
		.. "; valid keys: "
		.. table.concat(valid, ", ")
end

return DevError
