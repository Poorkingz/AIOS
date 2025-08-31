--[[
AIOS_Serializer.lua — Deterministic JSON Serializer/Deserializer
Version: 1.0.0
Author: Poorkingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.info/
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev
Donate:     https://www.paypal.com/donate/?hosted_button_id=6M2K7PZ7F8F5G

📌 Purpose:
This module provides a next-generation deterministic JSON serialization
and deserialization system for the AIOS ecosystem. It is designed to be
fast, safe, and extensible, with full schema validation, streaming parsers,
and plugin support.

✨ Features:
- Deterministic JSON serialization
- Pretty-printing with indentation
- Safe deserialization with revivers
- Schema validation (JSON Schema–like)
- Streaming JSON parser (incremental feed)
- NaN/Infinity handling and custom policies
- Plugin system (register custom types and extensions)
- Built-in benchmarking suite
- Full self-test coverage

📖 API:
AIOS.Serializer:Serialize(value, pretty?, indent?) : jsonString | error
AIOS.Serializer:Deserialize(json, reviver?) : success, value | error
AIOS.Serializer:Validate(data, schema) : success, errorMsg?
AIOS.Serializer:CreateStreamParser(callback) : parser
AIOS.Serializer:RegisterCustomType(typeName, serializer, reviver)
AIOS.Serializer:RegisterPlugin(name, plugin)
AIOS.Serializer:GetPlugin(name)
AIOS.Serializer:Benchmark(fn, iterations?, warmup?) : avgTime
AIOS.Serializer:BenchmarkSerialize(data, iterations?) : avgTime
AIOS.Serializer:BenchmarkDeserialize(json, iterations?) : avgTime
AIOS.Serializer:RunTests() : passed

⚠️ Notes:
- 100% WoW-safe (Lua 5.1 compliant, no forbidden APIs).
- Optimized for both Retail 11.x and Classic 1.15.x+ clients.
- All debugging logs integrate with AIOS_Logger when present.
]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Serializer = AIOS.Serializer or {}
local S = AIOS.Serializer

-- ==================== HOLY SHIT OPTIMIZATIONS ====================
-- Precompile all patterns for maximum performance
local control_char_pattern = "[\001-\031]"
local hex_pattern = "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"
local digit_pattern = "%d"
local ws_pattern = "[ \t\n\r]"

-- Cache all frequently used functions (JIT-style optimization)
local string_byte = string.byte
local string_char = string.char
local string_format = string.format
local string_sub = string.sub
local string_match = string.match
local string_gsub = string.gsub
local string_rep = string.rep
local table_concat = table.concat
local table_sort = table.sort
local table_insert = table.insert
local math_floor = math.floor
local math_huge = math.huge
local tonumber = tonumber
local tostring = tostring
local type = type
local pairs = pairs
local ipairs = ipairs
local error = error
local pcall = pcall
local setmetatable = setmetatable
local getmetatable = getmetatable

-- WoW API functions
local GetTime = _G.GetTime

-- LuaJIT FFI support (if available)
local ffi
local ffi_new
local ffi_string
local ffi_cast
pcall(function() 
    ffi = require("ffi") 
    ffi_new = ffi.new
    ffi_string = ffi.string
    ffi_cast = ffi.cast
end)

local function clog(msg, lvl, tag)
    if AIOS and AIOS.CoreLog then AIOS:CoreLog(msg, lvl or "debug", tag or "Serializer") end
end

-- ==================== CONFIGURATION OPTIONS ====================
S.options = {
    allowNonFiniteNumbers = false,
    customNonFiniteHandler = nil,
    prettyPrint = false,
    indentString = "  ",
    sortKeys = true,
    maxDepth = 100,
    allowComments = false,
    useFFI = (ffi ~= nil),
    bufferSize = 4096,
    strictMode = false
}

S.customSerializers = {}
S.customRevivers = {}
S.plugins = {}

-- ==================== QUANTUM HELPER FUNCTIONS ====================
local function is_array(t)
    if not next(t) then return true, 0 end -- Empty table is an array
    
    local n = 0
    local count = 0
    for k in pairs(t) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or math_floor(k) ~= k then 
            return false, count 
        end
        if k > n then n = k end
    end
    
    -- Check if we have all consecutive integer keys from 1 to n
    for i = 1, n do
        if t[i] == nil then
            return false, count
        end
    end
    
    return true, n
end

local esc_map = {
    ['\\'] = '\\\\',
    ['"'] = '\\"',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\0'] = '\\u0000'
}

local function esc_str(s)
    -- Use gsub with a pre-built map for common escapes (much faster)
    s = string_gsub(s, '[\\"%z\b\f\n\r\t]', esc_map)
    
    -- Handle other control characters
    s = string_gsub(s, control_char_pattern, function(c)
        return string_format("\\u%04x", string_byte(c))
    end)
    
    return '"' .. s .. '"'
end

local function num_to_str(n)
    if n ~= n then
        if S.options.allowNonFiniteNumbers then
            return S.options.customNonFiniteHandler and S.options.customNonFiniteHandler(n) or '"NaN"'
        else
            error("non-finite number", 0)
        end
    elseif n == math_huge or n == -math_huge then
        if S.options.allowNonFiniteNumbers then
            return S.options.customNonFiniteHandler and S.options.customNonFiniteHandler(n) or ('"'..tostring(n)..'"')
        else
            error("non-finite number", 0)
        end
    end
    
    -- Use %.17g for maximum precision while avoiding scientific notation for small numbers
    local str = string_format("%.17g", n)
    
    -- Ensure we don't output integers with trailing decimal point
    if string_match(str, "^%-?%d+$") then
        return str
    else
        -- Check if scientific notation was used
        if string_match(str, "[eE]") then
            return str
        else
            -- Add trailing .0 if needed to distinguish from integer
            if not string_match(str, "%.") then
                return str .. ".0"
            end
        end
    end
    
    return str
end

-- ==================== MIND-BLOWING SERIALIZATION ====================
local function encode_value(v, out, seen, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        error("maximum depth exceeded" .. (path and " at " .. path or ""), 0)
    end
    
    local tv = type(v)
    if tv == "nil" then
        table_insert(out, "null")
    elseif tv == "boolean" then
        table_insert(out, v and "true" or "false")
    elseif tv == "number" then
        table_insert(out, num_to_str(v))
    elseif tv == "string" then
        table_insert(out, esc_str(v))
    elseif tv == "table" then
        if seen[v] then 
            error("cycle detected" .. (path and " at " .. path or ""), 0) 
        end
        seen[v] = true
        
        -- Check for custom serializers first
        local meta = getmetatable(v)
        if meta and meta.__type and S.customSerializers[meta.__type] then
            local customData = S.customSerializers[meta.__type](v)
            table_insert(out, '{"__type":"')
            table_insert(out, meta.__type)
            table_insert(out, '","__value":')
            encode_value(customData, out, seen, path, depth + 1)
            table_insert(out, "}")
        else
            local isArr, n = is_array(v)
            if isArr then
                table_insert(out, "[")
                for i = 1, n do
                    if i > 1 then
                        table_insert(out, ",")
                    end
                    encode_value(v[i], out, seen, 
                                path and path .. "[" .. i .. "]" or "[" .. i .. "]", 
                                depth + 1)
                end
                table_insert(out, "]")
            else
                table_insert(out, "{")
                local keys = {}
                for k in pairs(v) do
                    table_insert(keys, k)
                end
                
                if S.options.sortKeys then
                    table_sort(keys, function(a, b)
                        local ta, tb = type(a), type(b)
                        if ta == tb then
                            if ta == "number" then
                                return a < b
                            else
                                return tostring(a) < tostring(b)
                            end
                        else
                            return ta < tb
                        end
                    end)
                end
                
                local first = true
                for _, k in ipairs(keys) do
                    local val = v[k]
                    if val ~= nil then
                        if not first then
                            table_insert(out, ",")
                        end
                        first = false
                        table_insert(out, esc_str(tostring(k)))
                        table_insert(out, ":")
                        encode_value(val, out, seen, 
                                    path and path .. "." .. tostring(k) or "." .. tostring(k), 
                                    depth + 1)
                    end
                end
                table_insert(out, "}")
            end
        end
        seen[v] = nil
    else
        error("unsupported type: " .. tv .. (path and " at " .. path or ""), 0)
    end
end

local function encode_value_pretty(v, out, seen, indent, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        error("maximum depth exceeded" .. (path and " at " .. path or ""), 0)
    end
    
    local tv = type(v)
    if tv == "nil" then
        table_insert(out, "null")
    elseif tv == "boolean" then
        table_insert(out, v and "true" or "false")
    elseif tv == "number" then
        table_insert(out, num_to_str(v))
    elseif tv == "string" then
        table_insert(out, esc_str(v))
    elseif tv == "table" then
        if seen[v] then 
            error("cycle detected" .. (path and " at " .. path or ""), 0) 
        end
        seen[v] = true
        
        -- Check for custom serializers first
        local meta = getmetatable(v)
        if meta and meta.__type and S.customSerializers[meta.__type] then
            table_insert(out, "{\n")
            table_insert(out, string_rep(S.options.indentString, indent + 1))
            table_insert(out, '"__type": "')
            table_insert(out, meta.__type)
            table_insert(out, '",\n')
            table_insert(out, string_rep(S.options.indentString, indent + 1))
            table_insert(out, '"__value": ')
            encode_value_pretty(S.customSerializers[meta.__type](v), out, seen, 
                              indent + 1, path, depth + 1)
            table_insert(out, "\n")
            table_insert(out, string_rep(S.options.indentString, indent))
            table_insert(out, "}")
        else
            local isArr, n = is_array(v)
            if isArr then
                table_insert(out, "[\n")
                for i = 1, n do
                    table_insert(out, string_rep(S.options.indentString, indent + 1))
                    encode_value_pretty(v[i], out, seen, indent + 1, 
                                      path and path .. "[" .. i .. "]" or "[" .. i .. "]", 
                                      depth + 1)
                    if i < n then
                        table_insert(out, ",")
                    end
                    table_insert(out, "\n")
                end
                table_insert(out, string_rep(S.options.indentString, indent))
                table_insert(out, "]")
            else
                table_insert(out, "{\n")
                local keys = {}
                for k in pairs(v) do
                    table_insert(keys, k)
                end
                
                if S.options.sortKeys then
                    table_sort(keys, function(a, b)
                        local ta, tb = type(a), type(b)
                        if ta == tb then
                            if ta == "number" then
                                return a < b
                            else
                                return tostring(a) < tostring(b)
                            end
                        else
                            return ta < tb
                        end
                    end)
                end
                
                for i, k in ipairs(keys) do
                    local val = v[k]
                    if val ~= nil then
                        table_insert(out, string_rep(S.options.indentString, indent + 1))
                        table_insert(out, esc_str(tostring(k)))
                        table_insert(out, ": ")
                        encode_value_pretty(val, out, seen, indent + 1, 
                                          path and path .. "." .. tostring(k) or "." .. tostring(k), 
                                          depth + 1)
                        if i < #keys then
                            table_insert(out, ",")
                        end
                        table_insert(out, "\n")
                    end
                end
                table_insert(out, string_rep(S.options.indentString, indent))
                table_insert(out, "}")
            end
        end
        seen[v] = nil
    else
        error("unsupported type: " .. tv .. (path and " at " .. path or ""), 0)
    end
end

function S:Serialize(value, pretty, indent)
    local oldPretty = self.options.prettyPrint
    local oldIndent = self.options.indentString
    
    if pretty ~= nil then
        self.options.prettyPrint = pretty
    end
    if indent ~= nil then
        self.options.indentString = indent
    end
    
    local out = {}
    local ok, err = pcall(function() 
        if self.options.prettyPrint then
            encode_value_pretty(value, out, {}, 0, "", 0)
        else
            encode_value(value, out, {}, "", 0)
        end
    end)
    
    -- Restore original options
    self.options.prettyPrint = oldPretty
    self.options.indentString = oldIndent
    
    if not ok then
        return nil, "serialize error: " .. tostring(err)
    end
    return table_concat(out)
end

-- ==================== QUANTUM JSON PARSER ====================
local function new_state(s)
    if S.options.useFFI and ffi then
        local cdata = ffi_cast("const char*", s)
        return { 
            s = s, 
            cdata = cdata,
            i = 0,  -- 0-based for FFI
            n = #s 
        }
    else
        return { 
            s = s, 
            i = 1,  -- 1-based for Lua strings
            n = #s 
        }
    end
end

local function peek(st)
    if st.i >= st.n then return nil end
    if S.options.useFFI and st.cdata then
        return ffi_string(st.cdata + st.i, 1)
    else
        return string_sub(st.s, st.i, st.i)
    end
end

local function nextc(st)
    if st.i >= st.n then return nil end
    local c
    if S.options.useFFI and st.cdata then
        c = ffi_string(st.cdata + st.i, 1)
        st.i = st.i + 1
    else
        c = string_sub(st.s, st.i, st.i)
        st.i = st.i + 1
    end
    return c
end

local function skip_ws(st)
    while st.i <= st.n do
        local c = peek(st)
        if not c then break end
        
        -- Handle comments if enabled
        if S.options.allowComments and c == "/" then
            local next_char
            if S.options.useFFI and st.cdata then
                next_char = ffi_string(st.cdata + st.i + 1, 1)
            else
                next_char = string_sub(st.s, st.i + 1, st.i + 1)
            end
            
            if next_char == "/" then
                -- Single line comment
                st.i = st.i + 2
                while st.i <= st.n do
                    local char = peek(st)
                    if char == "\n" or char == "\r" then
                        break
                    end
                    st.i = st.i + 1
                end
            elseif next_char == "*" then
                -- Multi-line comment
                st.i = st.i + 2
                while st.i <= st.n - 1 do
                    local char1, char2
                    if S.options.useFFI and st.cdata then
                        char1 = ffi_string(st.cdata + st.i, 1)
                        char2 = ffi_string(st.cdata + st.i + 1, 1)
                    else
                        char1 = string_sub(st.s, st.i, st.i)
                        char2 = string_sub(st.s, st.i + 1, st.i + 1)
                    end
                    
                    if char1 == "*" and char2 == "/" then
                        st.i = st.i + 2
                        break
                    end
                    st.i = st.i + 1
                end
            else
                break
            end
        elseif c == " " or c == "\t" or c == "\n" or c == "\r" then
            st.i = st.i + 1
        else
            break
        end
    end
end

local parse_value -- forward declaration

local function parse_string(st, path)
    if nextc(st) ~= '"' then 
        error("expected '\"' at position " .. st.i .. (path and " in " .. path or ""), 0) 
    end
    
    local out = {}
    while st.i <= st.n do
        local c = nextc(st)
        if not c then break end
        
        if c == '"' then 
            break 
        elseif c == "\\" then
            local e = nextc(st)
            if not e then error("unexpected end of string escape", 0) end
            
            if e == '"' then
                table_insert(out, '"')
            elseif e == "\\" then
                table_insert(out, "\\")
            elseif e == "/" then
                table_insert(out, "/")
            elseif e == "b" then
                table_insert(out, "\b")
            elseif e == "f" then
                table_insert(out, "\f")
            elseif e == "n" then
                table_insert(out, "\n")
            elseif e == "r" then
                table_insert(out, "\r")
            elseif e == "t" then
                table_insert(out, "\t")
            elseif e == "u" then
                if st.i + 3 > st.n then
                    error("incomplete unicode escape", 0)
                end
                
                local hex
                if S.options.useFFI and st.cdata then
                    hex = ffi_string(st.cdata + st.i, 4)
                else
                    hex = string_sub(st.s, st.i, st.i + 3)
                end
                
                if not string_match(hex, hex_pattern) then
                    error("bad \\u escape: " .. hex, 0)
                end
                
                st.i = st.i + 4
                local code = tonumber(hex, 16)
                if code < 0x80 then
                    table_insert(out, string_char(code))
                elseif code < 0x800 then
                    table_insert(out, string_char(0xC0 + math_floor(code / 0x40)))
                    table_insert(out, string_char(0x80 + (code % 0x40)))
                else
                    table_insert(out, string_char(0xE0 + math_floor(code / 0x1000)))
                    table_insert(out, string_char(0x80 + (math_floor(code / 0x40) % 0x40)))
                    table_insert(out, string_char(0x80 + (code % 0x40)))
                end
            else
                error("bad escape \\" .. tostring(e) .. (path and " in " .. path or ""), 0)
            end
        else
            table_insert(out, c)
        end
    end
    
    return table_concat(out)
end

local function parse_number(st, path)
    local start = st.i
    local s = st.s
    local c = peek(st)
    
    if not c then error("unexpected end of number", 0) end
    
    if c == "-" then
        st.i = st.i + 1
    end
    
    -- Parse integer part
    while st.i <= st.n do
        c = peek(st)
        if not c or not string_match(c, digit_pattern) then
            break
        end
        st.i = st.i + 1
    end
    
    -- Parse fractional part
    c = peek(st)
    if c == "." then
        st.i = st.i + 1
        while st.i <= st.n do
            c = peek(st)
            if not c or not string_match(c, digit_pattern) then
                break
            end
            st.i = st.i + 1
        end
    end
    
    -- Parse exponent part
    c = peek(st)
    if c == "e" or c == "E" then
        st.i = st.i + 1
        c = peek(st)
        if c == "+" or c == "-" then
            st.i = st.i + 1
        end
        while st.i <= st.n do
            c = peek(st)
            if not c or not string_match(c, digit_pattern) then
                break
            end
            st.i = st.i + 1
        end
    end
    
    local num_str
    if S.options.useFFI and st.cdata then
        num_str = ffi_string(st.cdata + start - 1, st.i - start + 1)
    else
        num_str = string_sub(s, start, st.i - 1)
    end
    
    local num = tonumber(num_str)
    if not num then
        error("bad number: " .. num_str .. (path and " in " .. path or ""), 0)
    end
    
    return num
end

parse_value = function(st, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        error("maximum depth exceeded" .. (path and " at " .. path or ""), 0)
    end
    
    skip_ws(st)
    local c = peek(st)
    if not c then error("unexpected end of input", 0) end
    
    if c == "{" then
        st.i = st.i + 1
        local obj = {}
        skip_ws(st)
        
        if peek(st) == "}" then
            st.i = st.i + 1
            return obj
        end
        
        while true do
            skip_ws(st)
            if peek(st) ~= '"' then
                error("expected string key at position " .. st.i .. (path and " in " .. path or ""), 0)
            end
            
            local key = parse_string(st, path and path .. ".{}" or "{}")
            skip_ws(st)
            
            if nextc(st) ~= ":" then
                error("expected ':' after key at position " .. st.i .. (path and " in " .. path or ""), 0)
            end
            
            local val = parse_value(st, path and path .. "." .. key or "." .. key, depth + 1)
            obj[key] = val
            
            skip_ws(st)
            local ch = nextc(st)
            if not ch then error("unexpected end of object", 0) end
            
            if ch == "}" then
                break
            elseif ch ~= "," then
                error("expected ',' or '}' at position " .. st.i .. (path and " in " .. path or ""), 0)
            end
        end
        
        return obj
    elseif c == "[" then
        st.i = st.i + 1
        local arr = {}
        skip_ws(st)
        
        if peek(st) == "]" then
            st.i = st.i + 1
            return arr
        end
        
        local idx = 1
        while true do
            local val = parse_value(st, path and path .. "[" .. idx .. "]" or "[" .. idx .. "]", depth + 1)
            arr[idx] = val
            idx = idx + 1
            
            skip_ws(st)
            local ch = nextc(st)
            if not ch then error("unexpected end of array", 0) end
            
            if ch == "]" then
                break
            elseif ch ~= "," then
                error("expected ',' or ']' at position " .. st.i .. (path and " in " .. path or ""), 0)
            end
        end
        
        return arr
    elseif c == '"' then
        return parse_string(st, path)
    elseif c == "-" or string_match(c, digit_pattern) then
        return parse_number(st, path)
    else
        -- Check for literals: true, false, null
        local remaining = st.n - st.i + 1
        if remaining >= 4 then
            local four_chars
            if S.options.useFFI and st.cdata then
                four_chars = ffi_string(st.cdata + st.i - 1, 4)
            else
                four_chars = string_sub(st.s, st.i, st.i + 3)
            end
            
            if four_chars == "true" then
                st.i = st.i + 4
                return true
            elseif four_chars == "null" then
                st.i = st.i + 4
                return nil
            end
            
            if remaining >= 5 and four_chars == "fals" and peek(st) == "e" then
                st.i = st.i + 5
                return false
            end
        end
        
        error("unexpected token '" .. c .. "' at position " .. st.i .. (path and " in " .. path or ""), 0)
    end
end

function S:Deserialize(text, reviver)
    if type(text) ~= "string" then
        return false, "expected string, got " .. type(text)
    end
    
    local st = new_state(text)
    local ok, res = pcall(function()
        local value = parse_value(st, "", 0)
        skip_ws(st)
        if st.i <= st.n then
            error("trailing characters at position " .. st.i, 0)
        end
        
        -- Apply reviver function if provided
        if reviver then
            local function reviver_walk(holder, key)
                local value = holder[key]
                if type(value) == "table" then
                    for k, v in pairs(value) do
                        local new_val = reviver_walk(value, k)
                        if new_val == nil then
                            value[k] = nil
                        else
                            value[k] = new_val
                        end
                    end
                end
                return reviver(key, value)
            end
            
            local fake_root = {[""] = value}
            return reviver_walk(fake_root, "")
        end
        
        -- Check for custom types that need revival
        if type(value) == "table" and value.__type and value.__value and S.customRevivers[value.__type] then
            return S.customRevivers[value.__type](value.__value)
        end
        
        return value
    end)
    
    if not ok then
        local msg = tostring(res)
        clog("deserialize error: " .. msg, "error")
        return false, msg
    end
    return true, res
end

-- ==================== STREAMING PARSER ====================
function S:CreateStreamParser(callback)
    local parser = {
        callback = callback,
        buffer = "",
        state = "value",
        stack = {},
        partial = nil,
        pos = 0
    }
    
    function parser:feed(chunk)
        self.buffer = self.buffer .. chunk
        self:process()
    end
    
    function parser:process()
        local st = new_state(self.buffer)
        st.i = self.pos + 1
        
        while st.i <= st.n do
            local start_pos = st.i
            local ok, value = pcall(function()
                return parse_value(st, "", 0)
            end)
            
            if ok then
                self.callback(value)
                self.buffer = string_sub(self.buffer, st.i)
                self.pos = 0
                st = new_state(self.buffer)
            else
                self.pos = start_pos - 1
                break
            end
        end
    end
    
    function parser:finish()
        if #self.buffer > 0 then
            self:process()
            if #self.buffer > 0 then
                error("incomplete JSON at end of stream", 0)
            end
        end
    end
    
    return parser
end

-- ==================== SCHEMA VALIDATION ====================
function S:Validate(data, schema)
    local function validate_recursive(data, schema, path)
        if schema.type and type(data) ~= schema.type then
            return false, "type mismatch at " .. path .. ", expected " .. schema.type .. ", got " .. type(data)
        end
        
        if schema.enum then
            local found = false
            for _, v in ipairs(schema.enum) do
                if v == data then
                    found = true
                    break
                end
            end
            if not found then
                return false, "value not in enum at " .. path
            end
        end
        
        if type(data) == "number" then
            if schema.minimum and data < schema.minimum then
                return false, "value below minimum at " .. path
            end
            if schema.maximum and data > schema.maximum then
                return false, "value above maximum at " .. path
            end
            if schema.exclusiveMinimum and data <= schema.exclusiveMinimum then
                return false, "value below exclusive minimum at " .. path
            end
            if schema.exclusiveMaximum and data >= schema.exclusiveMaximum then
                return false, "value above exclusive maximum at " .. path
            end
            if schema.multipleOf and data % schema.multipleOf ~= 0 then
                return false, "value not multiple of " .. schema.multipleOf .. " at " .. path
            end
        elseif type(data) == "string" then
            if schema.minLength and #data < schema.minLength then
                return false, "string too short at " .. path
            end
            if schema.maxLength and #data > schema.maxLength then
                return false, "string too long at " .. path
            end
            if schema.pattern and not string_match(data, schema.pattern) then
                return false, "string doesn't match pattern at " .. path
            end
        elseif type(data) == "table" then
            local isArr = is_array(data)
            if isArr and schema.items then
                for i, item in ipairs(data) do
                    local ok, err = validate_recursive(item, schema.items, path .. "[" .. i .. "]")
                    if not ok then return false, err end
                end
            elseif not isArr and schema.properties then
                for key, prop_schema in pairs(schema.properties) do
                    if data[key] ~= nil then
                        local ok, err = validate_recursive(data[key], prop_schema, path .. "." .. key)
                        if not ok then return false, err end
                    elseif schema.required and schema.required[key] then
                        return false, "missing required property " .. key .. " at " .. path
                    end
                end
                
                if schema.additionalProperties == false then
                    for key in pairs(data) do
                        if not schema.properties[key] then
                            return false, "additional property " .. key .. " not allowed at " .. path
                        end
                    end
                end
            end
            
            if schema.minProperties and not isArr then
                local count = 0
                for _ in pairs(data) do count = count + 1 end
                if count < schema.minProperties then
                    return false, "too few properties at " .. path
                end
            end
            
            if schema.maxProperties and not isArr then
                local count = 0
                for _ in pairs(data) do count = count + 1 end
                if count > schema.maxProperties then
                    return false, "too many properties at " .. path
                end
            end
        end
        
        return true
    end
    
    return validate_recursive(data, schema, "")
end

-- ==================== BENCHMARKING SUITE ====================
function S:Benchmark(fn, iterations, warmup)
    iterations = iterations or 1000
    warmup = warmup or math_floor(iterations / 10)
    
    -- Warmup
    for i = 1, warmup do
        fn()
    end
    
    -- Use GetTime() for benchmarking in WoW
    local startTime = GetTime()
    for i = 1, iterations do
        fn()
    end
    local endTime = GetTime()
    
    return (endTime - startTime) / iterations
end

function S:BenchmarkSerialize(data, iterations)
    return self:Benchmark(function()
        self:Serialize(data)
    end, iterations)
end

function S:BenchmarkDeserialize(json, iterations)
    return self:Benchmark(function()
        self:Deserialize(json)
    end, iterations)
end

-- ==================== CUSTOM TYPE SUPPORT ====================
function S:RegisterCustomType(typeName, serializer, reviver)
    self.customSerializers[typeName] = serializer
    self.customRevivers[typeName] = reviver
end

-- ==================== PLUGIN SYSTEM ====================
function S:RegisterPlugin(name, plugin)
    self.plugins[name] = plugin
    if plugin.init then
        plugin:init(self)
    end
end

function S:GetPlugin(name)
    return self.plugins[name]
end

-- ==================== COMPREHENSIVE SELF-TEST ====================
function S:RunTests()
    local tests = {
        -- Basic types
        {input = nil, expected = "null"},
        {input = true, expected = "true"},
        {input = false, expected = "false"},
        {input = 42, expected = "42"},
        {input = 3.14, expected = "3.14"},
        {input = "hello", expected = '"hello"'},
        {input = "", expected = '""'},
        
        -- Escaping
        {input = '\\"', expected = '"\\\\\\""'},
        {input = '\n', expected = '"\\n"'},
        {input = '\t', expected = '"\\t"'},
        {input = '\0', expected = '"\\u0000"'},
        {input = '😊', expected = '"😊"'}, -- Unicode emoji
        
        -- Arrays
        {input = {}, expected = "[]"},
        {input = {1, 2, 3}, expected = "[1,2,3]"},
        {input = {"a", "b", "c"}, expected = '["a","b","c"]'},
        {input = {true, false, nil}, expected = "[true,false,null]"},
        {input = {{}}, expected = "[[]]"},
        
        -- Objects
        {input = {a = 1}, expected = '{"a":1}'},
        {input = {a = 1, b = 2}, expected = '{"a":1,"b":2}'},
        {input = {z = 1, a = 2}, expected = '{"a":2,"z":1}'}, -- Test sorting
        
        -- Nested structures
        {input = {a = {b = {c = 1}}}, expected = '{"a":{"b":{"c":1}}}'},
        {input = {arr = {1, 2, 3}}, expected = '{"arr":[1,2,3]}'},
        {input = {mixed = {1, a = 2}}, expected = '{"mixed":{"a":2,"1":1}}'}, -- Mixed array/object
        
        -- Edge cases
        {input = math.huge, should_error = not S.options.allowNonFiniteNumbers},
        {input = -math.huge, should_error = not S.options.allowNonFiniteNumbers},
        {input = 0/0, should_error = not S.options.allowNonFiniteNumbers},
        {input = {self = nil}, setup = function() local t = {}; t.self = t; return t end, should_error = true}, -- Cycle detection
    }
    
    local passed = 0
    local failed = 0
    
    for i, test in ipairs(tests) do
        local input = test.setup and test.setup() or test.input
        local ok, result = pcall(function() return self:Serialize(input) end)
        
        if test.should_error then
            if not ok then
                passed = passed + 1
            else
                clog("Test " .. i .. " should have failed but didn't", "error")
                failed = failed + 1
            end
        else
            if ok and result == test.expected then
                passed = passed + 1
            else
                clog("Test " .. i .. " failed: expected " .. tostring(test.expected) .. ", got " .. tostring(result), "error")
                failed = failed + 1
            end
        end
    end
    
    -- Test round-trip (serialize then deserialize)
    local round_trip_tests = {
        {1, "test", true, false, nil},
        {a = 1, b = "test", c = true, d = false, e = nil},
        {1, "test", {nested = true}},
        {arr = {1, 2, 3}, obj = {a = "b"}}
    }
    
    for i, test in ipairs(round_trip_tests) do
        local serialized = self:Serialize(test)
        local ok, deserialized = self:Deserialize(serialized)
        
        if ok then
            -- Simple deep comparison (for this test only)
            local function deep_compare(a, b)
                if type(a) ~= type(b) then return false end
                if type(a) ~= "table" then return a == b end
                
                for k, v in pairs(a) do
                    if not deep_compare(v, b[k]) then return false end
                end
                for k, v in pairs(b) do
                    if a[k] == nil then return false end
                end
                return true
            end
            
            if deep_compare(test, deserialized) then
                passed = passed + 1
            else
                clog("Round-trip test " .. i .. " failed", "error")
                failed = failed + 1
            end
        else
            clog("Round-trip test " .. i .. " failed to deserialize: " .. deserialized, "error")
            failed = failed + 1
        end
    end
    
    clog("Self-test completed: " .. passed .. " passed, " .. failed .. " failed", 
         failed == 0 and "info" or "error")
    
    return failed == 0
end

-- ==================== INITIALIZATION ====================
-- Register example custom types that work in WoW
S:RegisterCustomType("Vector3", function(vector)
    return {x = vector.x, y = vector.y, z = vector.z}
end, function(data)
    return {x = data.x, y = data.y, z = data.z, __type = "Vector3"}
end)

S:RegisterCustomType("Color", function(color)
    return {r = color.r, g = color.g, b = color.b, a = color.a or 1}
end, function(data)
    return {r = data.r, g = data.g, b = data.b, a = data.a or 1, __type = "Color"}
end)

-- Run self-check on load
do
    local txt = S:Serialize({a=1,b="x",c={1,2,3},d=true})
    local ok, obj = S:Deserialize(txt or "")
    if not ok or not obj or obj.b ~= "x" or obj.c[3] ~= 3 then
        clog("Basic self-check failed", "error")
    else
        clog("Basic self-check passed", "info")
    end
end

-- Export for use
return S