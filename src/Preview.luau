--!strict
--[[
	Payload previews for logs: `{ targetId = "5", extra = true }`.

	Built only when something is logged, never on accepted calls. Safe on hostile input:
	bounded length (~200 chars), depth (3) and keys per table (20); cycles print <cycle>;
	metatables are ignored (raw iteration, no __tostring); values at `sensitive` schema
	paths print <redacted>.
]]

local Format = require(script.Parent.Format)
local Types = require(script.Parent.Types)

type Redaction = Types.Redaction

local MAX_LENGTH = 200
local MAX_DEPTH = 3
local MAX_KEYS = 20
local MAX_STRING = 40

local Preview = {}

type State = { parts: { string }, length: number, visiting: { [any]: boolean } }

local function push(state: State, text: string): boolean
	table.insert(state.parts, text)
	state.length += #text
	return state.length <= MAX_LENGTH
end

-- Redaction for one child of a table, or nil.
local function childRedaction(redaction: Redaction?, key: unknown): Redaction?
	if type(redaction) ~= "table" then
		return nil
	end
	local fields = redaction.fields
	if fields and fields[key] ~= nil then
		return fields[key]
	end
	return redaction.each
end

local function scalar(value: unknown): string
	local kind = typeof(value)
	if kind == "string" then
		return Format.quote(value :: string, MAX_STRING)
	elseif kind == "Instance" then
		return "Instance(" .. (value :: Instance).ClassName .. ")"
	end
	return Format.value(value)
end

local function keyText(key: unknown): string
	if type(key) == "string" and string.find(key, "^[%a_][%w_]*$") then
		return key
	end
	return "[" .. scalar(key) .. "]"
end

-- Collects up to MAX_KEYS keys in a stable order: 1..n first, then the rest sorted.
local function orderedKeys(value: { [any]: any }): ({ any }, boolean, number)
	local keys, others = {}, {}
	local arrayLength = 0
	while arrayLength < MAX_KEYS and rawget(value, arrayLength + 1) ~= nil do
		arrayLength += 1
		table.insert(keys, arrayLength)
	end
	local total = 0
	for key in next, value do
		total += 1
		if total > MAX_KEYS * 2 then
			break -- bounded work on huge tables
		end
		if not (type(key) == "number" and key >= 1 and key <= arrayLength and key == math.floor(key)) then
			table.insert(others, key)
		end
	end
	table.sort(others, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, key in others do
		if #keys >= MAX_KEYS then
			break
		end
		table.insert(keys, key)
	end
	local truncated = total > #keys
	return keys, truncated, arrayLength
end

local function write(state: State, value: unknown, redaction: Redaction?, depth: number): boolean
	if redaction == true then
		return push(state, "<redacted>")
	elseif type(value) ~= "table" then
		return push(state, scalar(value))
	elseif state.visiting[value] then
		return push(state, "<cycle>")
	elseif depth >= MAX_DEPTH then
		return push(state, "{...}")
	end
	local tbl = value :: { [any]: any }
	local keys, truncated, arrayLength = orderedKeys(tbl)
	if #keys == 0 then
		return push(state, "{}")
	end
	state.visiting[tbl] = true
	local ok = push(state, "{ ")
	for i, key in keys do
		if not ok then
			break
		end
		if i > 1 then
			ok = push(state, ", ")
		end
		if ok and not (type(key) == "number" and key <= arrayLength) then
			ok = push(state, keyText(key) .. " = ")
		end
		ok = ok and write(state, rawget(tbl, key), childRedaction(redaction, key), depth + 1)
	end
	state.visiting[tbl] = nil
	return ok and push(state, if truncated then ", ... }" else " }")
end

local function finish(state: State): string
	local text = table.concat(state.parts)
	if #text > MAX_LENGTH then
		return string.sub(text, 1, MAX_LENGTH - 3) .. "..."
	end
	return text
end

-- Preview of one value.
function Preview.value(value: unknown, redaction: Redaction?): string
	local state: State = { parts = {}, length = 0, visiting = {} }
	write(state, value, redaction, 0)
	return finish(state)
end

-- Preview of packed remote arguments: a single argument prints as itself, several as
-- `(a, b)`. `redaction.fields[i]` applies to argument i.
function Preview.arguments(packed: { n: number, [number]: any }, redaction: Redaction?): string
	if packed.n == 1 then
		return Preview.value(packed[1], childRedaction(redaction, 1))
	end
	local state: State = { parts = {}, length = 0, visiting = {} }
	local ok = push(state, "(")
	for i = 1, packed.n do
		if not ok then
			break
		end
		if i > 1 then
			ok = push(state, ", ")
		end
		ok = ok and write(state, packed[i], childRedaction(redaction, i), 0)
	end
	if ok then
		push(state, ")")
	end
	return finish(state)
end

return Preview
