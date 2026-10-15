--!strict
--[[
	Small, safe value formatting shared by Schema reasons and the Printer.
	Never throws, never calls user metamethods.
]]

local Format = {}

local MAX_SHOWN_STRING = 32

function Format.number(n: number): string
	if n ~= n then
		return "NaN"
	elseif n == math.huge then
		return "inf"
	elseif n == -math.huge then
		return "-inf"
	elseif n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.14g", n)
end

-- Quotes a string and escapes control characters, quotes and backslashes, so attacker
-- strings can't break log lines.
function Format.quote(s: string, maxLen: number?): string
	local limit = maxLen or MAX_SHOWN_STRING
	local shown = if #s > limit then string.sub(s, 1, limit) else s
	local escaped = string.gsub(shown, '[%c"\\]', function(c: string): string
		return string.format("\\%d", string.byte(c))
	end)
	return '"' .. escaped .. '"' .. (if #s > limit then string.format("... (%d bytes)", #s) else "")
end

-- Short description of a value, used after "got" when the type matched but the value did not.
function Format.value(value: unknown): string
	local kind = typeof(value)
	if kind == "number" then
		return Format.number(value :: number)
	elseif kind == "string" then
		return Format.quote(value :: string)
	elseif kind == "boolean" or kind == "nil" then
		return tostring(value)
	elseif kind == "Vector3" then
		local v = value :: Vector3
		return string.format("Vector3(%s, %s, %s)", Format.number(v.X), Format.number(v.Y), Format.number(v.Z))
	end
	return kind
end

-- Path segment for a table key: `.name` for identifiers, `[3]` or `["odd key"]` otherwise.
function Format.keySegment(key: unknown): string
	if type(key) == "string" then
		if string.find(key, "^[%a_][%w_]*$") then
			return "." .. key
		end
		return "[" .. Format.quote(key) .. "]"
	elseif type(key) == "number" then
		return "[" .. Format.number(key) .. "]"
	end
	return "[" .. typeof(key) .. "]"
end

-- Joins a path (".items[2].x") and a message into "items[2].x: message".
function Format.withPath(path: string?, message: string): string
	if path == nil or path == "" then
		return message
	end
	if string.sub(path, 1, 1) == "." then
		path = string.sub(path, 2)
	end
	return path .. ": " .. message
end

return Format
