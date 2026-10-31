-- Minimal JSON encode/decode for the Oxygen Pro editor (pure Lua 5.3/5.4, no dependencies).
-- encode: arrays are tables with only 1..n integer keys (empty table -> []), objects have sorted keys.
-- decode: strict JSON; objects -> tables, arrays -> tables with n = #array; null -> json.null.

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function encode_value(v, indent, level, out)
    local t = type(v)
    if v == json.null or v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "number" then
        -- (NaN and infinities aren't JSON: written as they were, every reader skipped that file)
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif math.floor(v) == v and math.abs(v) < 2^53 then out[#out + 1] = string.format("%d", v)
        else out[#out + 1] = string.format("%.14g", v) end
    elseif t == "string" then out[#out + 1] = encode_string(v)
    elseif t == "table" then
        local pad = indent and ("\n" .. string.rep(indent, level + 1)) or ""
        local close = indent and ("\n" .. string.rep(indent, level)) or ""
        local sep = indent and "," or ","
        if is_array(v) then
            if #v == 0 then out[#out + 1] = "[]"; return end
            out[#out + 1] = "["
            for i, item in ipairs(v) do
                if i > 1 then out[#out + 1] = sep end
                out[#out + 1] = pad
                encode_value(item, indent, level + 1, out)
            end
            out[#out + 1] = close .. "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = sep end
                out[#out + 1] = pad .. encode_string(k) .. (indent and ": " or ":")
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                encode_value(val, indent, level + 1, out)
            end
            out[#out + 1] = close .. "}"
        end
    else
        error("json.encode: cannot encode " .. t)
    end
end

function json.encode(v, pretty)
    local out = {}
    encode_value(v, pretty and "  " or nil, 0, out)
    return table.concat(out)
end

-- ---- decoder ----
local function decode_error(s, i, msg) error(string.format("json.decode: %s at position %d", msg, i), 0) end

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decode_value

local UNESCAPE = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
-- (a run of plain characters at a time, up to the next quote or backslash: one at a time, a plug-in chain event of a
-- few MB took seconds, on REAPER's own thread)
local function decode_string(s, i)
    local out, j = {}, i + 1
    while true do
        local k = s:find('["\\]', j)
        if not k then decode_error(s, j, "unterminated string") end
        if k > j then out[#out + 1] = s:sub(j, k - 1) end
        if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
        local e = s:sub(k + 1, k + 1)
        if UNESCAPE[e] then out[#out + 1] = UNESCAPE[e]; j = k + 2
        elseif e == "u" then
            local hex = s:sub(k + 2, k + 5)
            local cp = tonumber(hex, 16) or decode_error(s, k, "bad unicode escape")
            out[#out + 1] = utf8.char(cp); j = k + 6
        else decode_error(s, k, "bad escape") end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then decode_error(s, i, "bad number") end
    local v = tonumber(num) or decode_error(s, i, "bad number")
    return v, i + #num
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then decode_error(s, i, "expected key") end
            local k; k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
            local v; v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "}" then return obj, i + 1
            else decode_error(s, i, "expected ',' or '}'") end
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v; v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "]" then return arr, i + 1
            else decode_error(s, i, "expected ',' or ']'") end
        end
    elseif c == '"' then return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return json.null, i + 4
    else return decode_number(s, i) end
end

function json.decode(s)
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing data") end
    return v
end

return json
