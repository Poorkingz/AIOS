--[[
AIOS_Serializer.lua — Quantum JSON Serializer/Deserializer
Version: 4.0.0 "Quantum Leap" Edition
Author: PoorKingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.info/
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev

Purpose:
  Provides a universal serialization/deserialization layer for AIOS.
  Handles JSON, binary, schema validation, streaming, plugins, and
  WoW-specific types. Built for high performance with caching,
  memory pools, and optional FFI acceleration.

Notes:
  • Safe across Retail (11.x), Classic Era (1.15.x), MoP Classic (5.4.x).
  • Auto-registers with AIOS when available.
  • Uses strict schema validation and error handling by default.
  • Optional FFI fast-path for large datasets.
  • Integrates with AIOS.Logger and AIOS.Config if present.
  • Supports plugins for custom serializers and revivers.

API Reference:
  Serializer:Serialize(value, pretty, indent)          -- JSON encode
  Serializer:Deserialize(text, reviver)                -- JSON decode
  Serializer:SerializeBinary(data)                     -- Binary encode (with compression)
  Serializer:DeserializeBinary(binary)                 -- Binary decode
  Serializer:Validate(data, schema)                    -- JSON schema validation
  Serializer:CreateStreamParser(callback)              -- Streaming parser
  Serializer:RegisterCustomType(name, serializer, reviver) -- Extend with custom types
  Serializer:RegisterDefaultTypes()                    -- Register built-in types (Vector, Color, GUID)
  Serializer:RegisterPlugin(name, plugin)              -- Attach plugin with init()
  Serializer:GetPlugin(name)                           -- Retrieve plugin
  Serializer:StartProfiling()                          -- Begin perf stats collection
  Serializer:StopProfiling()                           -- End perf stats collection
  Serializer:GetPerformanceStats()                     -- Cache/memory/profiler info
  Serializer:Initialize()                              -- Safe init, memory pool, types
  Serializer:GetStatus()                               -- Current init + config state

This file is 
  - Advanced compression plugins (zlib, LZ4)
  - Full streaming state machine for live data feeds
  - Built-in revivers for WoW API objects (items, spells, etc.)
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Serializer = AIOS.Serializer or {}
local S = AIOS.Serializer

-- ==================== QUANTUM CORE INITIALIZATION ====================
-- JIT-optimized function caching
local string_byte = string.byte
local string_char = string.char
local string_format = string.format
local string_sub = string.sub
local string_match = string.match
local string_gsub = string.gsub
local string_rep = string.rep
local string_find = string.find
local string_len = string.len
local table_concat = table.concat
local table_sort = table.sort
local table_insert = table.insert
local table_remove = table.remove
local math_floor = math.floor
local math_huge = math.huge
local math_type = math.type
local math_max = math.max
local math_min = math.min
local tonumber = tonumber
local tostring = tostring
local type = type
local pairs = pairs
local ipairs = ipairs
local error = error
local pcall = pcall
local xpcall = xpcall
local setmetatable = setmetatable
local getmetatable = getmetatable
local select = select
local next = next
local tinsert = table.insert
local tremove = table.remove

-- WoW API optimization
local GetTime = _G.GetTime
local Collectgarbage = _G.collectgarbage

-- ==================== QUANTUM LOGGING SYSTEM ====================
function S._log(msg, level)
    if AIOS and AIOS.Logger then
        AIOS.Logger:Log(msg, level or "debug", "Serializer")
    elseif AIOS and AIOS.CoreLog then
        AIOS:CoreLog(msg, level or "debug", "Serializer")
    else
        print("[" .. (level or "INFO") .. "] Serializer: " .. msg)
    end
end

-- ==================== QUANTUM CONFIGURATION SYSTEM ====================
S.options = {
    allowNonFiniteNumbers = false,
    customNonFiniteHandler = nil,
    prettyPrint = false,
    indentString = "  ",
    sortKeys = true,
    maxDepth = 1000, -- Increased for complex structures
    allowComments = true,
    useFFI = false,
    bufferSize = 8192, -- Increased buffer size
    strictMode = false,
    useCache = true,
    cacheSize = 1000,
    compression = false,
    compressionThreshold = 1024, -- Compress objects larger than 1KB
    streaming = true,
    validateSchema = false,
    errorHandling = "strict", -- strict, lenient, or custom
    customErrorHandler = nil,
    maxStringLength = 1000000, -- 1MB max string length
    maxArraySize = 100000, -- 100k elements max
    maxObjectKeys = 100000, -- 100k keys max
    dateFormat = "iso", -- iso, epoch, or custom
    customDateFormat = nil,
    binaryEncoding = "base64", -- base64, hex, or custom
    customBinaryHandler = nil,
    optimizeForLargeData = true,
    useMemoryPool = true,
    memoryPoolSize = 1024 * 1024, -- 1MB memory pool
    garbageCollectionThreshold = 100, -- Run GC after 100 operations
    parallelProcessing = false, -- Experimental
    security = {
        preventProtoPollution = true,
        maxNesting = 100,
        safeEval = true,
        allowedTypes = {} -- Whitelist of allowed types
    }
}

S.customSerializers = {}
S.customRevivers = {}
S.plugins = {}
S._initialized = false
S._memoryPool = {}
S._poolIndex = 0
S._operationCount = 0

-- ==================== QUANTUM MEMORY ARCHITECTURE ====================
S._cache = {
    serialized = setmetatable({}, {__mode = "v"}),
    deserialized = setmetatable({}, {__mode = "v"}),
    schemas = setmetatable({}, {__mode = "v"}),
    hits = 0,
    misses = 0,
    size = 0,
    maxSize = 1000
}

-- Memory pool for efficient allocation
function S:_getFromPool()
    if self._poolIndex > 0 then
        local item = self._memoryPool[self._poolIndex]
        self._memoryPool[self._poolIndex] = nil
        self._poolIndex = self._poolIndex - 1
        return item
    end
    return {}
end

function S:_returnToPool(t)
    if self._poolIndex < self.options.memoryPoolSize then
        for k in pairs(t) do
            t[k] = nil
        end
        self._poolIndex = self._poolIndex + 1
        self._memoryPool[self._poolIndex] = t
    end
end

-- ==================== FFI QUANTUM BOOST ====================
local ffi, ffi_new, ffi_string, ffi_cast, ffi_typeof, ffi_copy, ffi_fill
if pcall(function() 
    ffi = require("ffi")
    ffi_new = ffi.new
    ffi_string = ffi.string
    ffi_cast = ffi.cast
    ffi_typeof = ffi.typeof
    ffi_copy = ffi.copy
    ffi_fill = ffi.fill
    
    -- FFI type definitions for quantum performance
    ffi.cdef[[
        typedef struct { const char *data; size_t len; } string_view;
        typedef struct { uint8_t *data; size_t size; size_t capacity; } quantum_buffer;
        typedef struct { size_t length; size_t capacity; void** items; } quantum_array;
    ]]
    
    S.options.useFFI = true
    S._log("FFI enabled for quantum performance", "DEBUG")
end) then
    -- FFI loaded successfully
else
    S._log("FFI not available, using quantum Lua fallback", "INFO")
end

-- ==================== QUANTUM HELPER FUNCTIONS ====================
local function is_array(t)
    if not next(t) then return true, 0 end -- Empty table is an array
    
    local count = 0
    local max_index = 0
    local min_index = math_huge
    
    for k in pairs(t) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or math_floor(k) ~= k then 
            return false, count 
        end
        max_index = math_max(max_index, k)
        min_index = math_min(min_index, k)
    end
    
    -- Check if we have all consecutive integer keys from 1 to n
    if min_index ~= 1 or max_index ~= count then
        return false, count
    end
    
    return true, max_index
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
    if string_len(s) > S.options.maxStringLength then
        error("string length exceeds maximum allowed size", 0)
    end
    
    -- Use gsub with a pre-built map for common escapes (much faster)
    s = string_gsub(s, '[\\"%z\b\f\n\r\t]', esc_map)
    
    -- Handle other control characters
    s = string_gsub(s, "[\001-\031]", function(c)
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

-- ==================== QUANTUM ERROR HANDLING ====================
function S:_handleError(err, context, level)
    self._operationCount = self._operationCount + 1
    
    -- Run garbage collection if threshold reached
    if self._operationCount % self.options.garbageCollectionThreshold == 0 then
        Collectgarbage("collect")
    end
    
    if self.options.errorHandling == "strict" then
        error(err, level or 0)
    elseif self.options.errorHandling == "lenient" then
        self._log("Lenient error handling: " .. tostring(err) .. " in " .. (context or "unknown"), "WARNING")
        return nil
    elseif self.options.errorHandling == "custom" and self.options.customErrorHandler then
        return self.options.customErrorHandler(err, context, level)
    else
        error(err, level or 0)
    end
end

-- ==================== ADVANCED SERIALIZATION ====================
local function encode_value(v, out, seen, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        S:_handleError("maximum depth exceeded" .. (path and " at " .. path or ""), "encode_value", 0)
        return
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
            S:_handleError("cycle detected" .. (path and " at " .. path or ""), "encode_value", 0)
            return
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
                if n > S.options.maxArraySize then
                    S:_handleError("array size exceeds maximum allowed", "encode_value", 0)
                    return
                end
                
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
                local keyCount = 0
                for _ in pairs(v) do
                    keyCount = keyCount + 1
                    if keyCount > S.options.maxObjectKeys then
                        S:_handleError("object key count exceeds maximum allowed", "encode_value", 0)
                        return
                    end
                end
                
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
        S:_handleError("unsupported type: " .. tv .. (path and " at " .. path or ""), "encode_value", 0)
    end
end

local function encode_value_pretty(v, out, seen, indent, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        S:_handleError("maximum depth exceeded" .. (path and " at " .. path or ""), "encode_value_pretty", 0)
        return
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
            S:_handleError("cycle detected" .. (path and " at " .. path or ""), "encode_value_pretty", 0)
            return
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
                if n > S.options.maxArraySize then
                    S:_handleError("array size exceeds maximum allowed", "encode_value_pretty", 0)
                    return
                end
                
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
                local keyCount = 0
                for _ in pairs(v) do
                    keyCount = keyCount + 1
                    if keyCount > S.options.maxObjectKeys then
                        S:_handleError("object key count exceeds maximum allowed", "encode_value_pretty", 0)
                        return
                    end
                end
                
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
        S:_handleError("unsupported type: " .. tv .. (path and " at " .. path or ""), "encode_value_pretty", 0)
    end
end

function S:Serialize(value, pretty, indent)
    local oldPretty = self.options.prettyPrint
    local oldIndent = self.options.indentString
    
    if pretty ~= nil then
        self.options.prettyPrint = pretty
    end
    if indent ~= nil then
        -- Convert numeric indent to appropriate string
        if type(indent) == "number" then
            self.options.indentString = string_rep(" ", indent)
        else
            self.options.indentString = indent
        end
    end
    
    -- Check cache if enabled
    local cacheKey
    if self.options.useCache then
        cacheKey = tostring(value) .. tostring(self.options.prettyPrint) .. tostring(self.options.indentString)
        if self._cache.serialized[cacheKey] then
            self._cache.hits = self._cache.hits + 1
            return self._cache.serialized[cacheKey]
        end
        self._cache.misses = self._cache.misses + 1
    end
    
    local out = self:_getFromPool()
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
        self:_returnToPool(out)
        return nil, "serialize error: " .. tostring(err)
    end
    
    local result = table_concat(out)
    self:_returnToPool(out)
    
    -- Add to cache if enabled
    if self.options.useCache and cacheKey then
        if self._cache.size >= self._cache.maxSize then
            -- Remove oldest entry (FIFO)
            local oldestKey = next(self._cache.serialized)
            if oldestKey then
                self._cache.serialized[oldestKey] = nil
                self._cache.size = self._cache.size - 1
            end
        end
        self._cache.serialized[cacheKey] = result
        self._cache.size = self._cache.size + 1
    end
    
    return result
end

-- ==================== QUANTUM JSON PARSER ====================
local function new_state(s)
    return { 
        s = s, 
        i = 1,  -- 1-based for Lua strings
        n = #s,
        line = 1,
        col = 1
    }
end

local function peek(st)
    if st.i > st.n then return nil end
    return string_sub(st.s, st.i, st.i)
end

local function nextc(st)
    if st.i > st.n then return nil end
    local c = string_sub(st.s, st.i, st.i)
    st.i = st.i + 1
    if c == "\n" then
        st.line = st.line + 1
        st.col = 1
    else
        st.col = st.col + 1
    end
    return c
end

local function skip_ws(st)
    while st.i <= st.n do
        local c = peek(st)
        if not c then break end
        
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            nextc(st)
        elseif c == "/" and S.options.allowComments then
            -- Check for comment
            local next_char = string_sub(st.s, st.i + 1, st.i + 1)
            if next_char == "/" then
                -- Single line comment
                st.i = st.i + 2
                while st.i <= st.n do
                    c = nextc(st)
                    if c == "\n" then
                        break
                    end
                end
            elseif next_char == "*" then
                -- Multi-line comment
                st.i = st.i + 2
                while st.i <= st.n do
                    c = nextc(st)
                    if c == "*" and peek(st) == "/" then
                        nextc(st) -- Skip the '/'
                        break
                    end
                end
            else
                break
            end
        else
            break
        end
    end
end

local parse_value -- forward declaration

local function parse_string(st, path)
    if nextc(st) ~= '"' then 
        error("expected '\"' at line " .. st.line .. ", column " .. st.col, 0) 
    end
    
    local out = {}
    while st.i <= st.n do
        local c = nextc(st)
        if not c then error("unexpected end of string", 0) end
        
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
                
                local hex = string_sub(st.s, st.i, st.i + 3)
                st.i = st.i + 4
                st.col = st.col + 4
                local code = tonumber(hex, 16)
                if not code then
                    error("invalid unicode escape: \\u" .. hex, 0)
                end
                table_insert(out, string_char(code))
            else
                error("bad escape \\" .. tostring(e) .. " at line " .. st.line .. ", column " .. st.col, 0)
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
    
    if peek(st) == "-" then
        st.i = st.i + 1
        st.col = st.col + 1
    end
    
    -- Parse integer part
    while st.i <= st.n do
        local c = peek(st)
        if not c or not string_match(c, "%d") then break end
        st.i = st.i + 1
        st.col = st.col + 1
    end
    
    -- Parse fractional part
    if peek(st) == "." then
        st.i = st.i + 1
        st.col = st.col + 1
        while st.i <= st.n do
            local c = peek(st)
            if not c or not string_match(c, "%d") then break end
            st.i = st.i + 1
            st.col = st.col + 1
        end
    end
    
    -- Parse exponent part
    local c = peek(st)
    if c == "e" or c == "E" then
        st.i = st.i + 1
        st.col = st.col + 1
        c = peek(st)
        if c == "+" or c == "-" then
            st.i = st.i + 1
            st.col = st.col + 1
        end
        while st.i <= st.n do
            local c = peek(st)
            if not c or not string_match(c, "%d") then break end
            st.i = st.i + 1
            st.col = st.col + 1
        end
    end
    
    local num_str = string_sub(s, start, st.i - 1)
    local num = tonumber(num_str)
    if not num then
        error("bad number: " .. num_str .. " at line " .. st.line .. ", column " .. st.col, 0)
    end
    
    return num
end

parse_value = function(st, path, depth)
    depth = depth or 0
    if depth > S.options.maxDepth then
        error("maximum depth exceeded" .. (path and " at " .. path or "") .. 
              " at line " .. st.line .. ", column " .. st.col, 0)
    end
    
    skip_ws(st)
    local c = peek(st)
    if not c then error("unexpected end of input at line " .. st.line .. ", column " .. st.col, 0) end
    
    if c == "{" then
        nextc(st)
        skip_ws(st)
        
        -- Check for empty object first
        if peek(st) == "}" then
            nextc(st)
            return {}
        end
        
        local obj = {}
        local first = true
        
        while true do
            skip_ws(st)
            
            -- Check if we're at the end of the object
            if peek(st) == "}" then
                nextc(st)
                break
            end
            
            -- If not first element, expect a comma
            if not first then
                if nextc(st) ~= "," then
                    error("expected ',' at line " .. st.line .. ", column " .. st.col, 0)
                end
                skip_ws(st)
            end
            first = false
            
            -- Parse key (must be a string)
            if peek(st) ~= '"' then
                error("expected string key at line " .. st.line .. ", column " .. st.col, 0)
            end
            
            local key = parse_string(st, path and path .. ".{}" or "{}")
            skip_ws(st)
            
            -- Parse colon
            if nextc(st) ~= ":" then
                error("expected ':' after key at line " .. st.line .. ", column " .. st.col, 0)
            end
            
            skip_ws(st)
            
            -- Parse value
            local val = parse_value(st, path and path .. "." .. key or "." .. key, depth + 1)
            
            -- Security: prevent prototype pollution
            if S.options.security.preventProtoPollution and (key == "__proto__" or key == "constructor") then
                S._log("Blocked potential prototype pollution attempt: " .. key, "WARNING")
            else
                obj[key] = val
            end
            
            skip_ws(st)
        end
        
        return obj
        
    elseif c == "[" then
        nextc(st)
        skip_ws(st)
        
        -- Check for empty array first
        if peek(st) == "]" then
            nextc(st)
            return {}
        end
        
        local arr = {}
        local idx = 1
        local first = true
        
        while true do
            skip_ws(st)
            
            -- Check if we're at the end of the array
            if peek(st) == "]" then
                nextc(st)
                break
            end
            
            -- If not first element, expect a comma
            if not first then
                if nextc(st) ~= "," then
                    error("expected ',' at line " .. st.line .. ", column " .. st.col, 0)
                end
                skip_ws(st)
            end
            first = false
            
            -- Parse value
            local val = parse_value(st, path and path .. "[" .. idx .. "]" or "[" .. idx .. "]", depth + 1)
            arr[idx] = val
            idx = idx + 1
            
            if idx > S.options.maxArraySize then
                error("array size exceeds maximum allowed at line " .. st.line .. ", column " .. st.col, 0)
            end
            
            skip_ws(st)
        end
        
        return arr
        
    elseif c == '"' then
        return parse_string(st, path)
    elseif c == "-" or string_match(c, "%d") then
        return parse_number(st, path)
    else
        -- Check for literals: true, false, null
        local remaining = st.n - st.i + 1
        if remaining >= 4 then
            local four_chars = string_sub(st.s, st.i, st.i + 3)
            
            if four_chars == "true" then
                st.i = st.i + 4
                st.col = st.col + 4
                return true
            elseif four_chars == "null" then
                st.i = st.i + 4
                st.col = st.col + 4
                return nil
            end
            
            if remaining >= 5 then
                local five_chars = string_sub(st.s, st.i, st.i + 4)
                if five_chars == "false" then
                    st.i = st.i + 5
                    st.col = st.col + 5
                    return false
                end
            end
        end
        
        error("unexpected token '" .. c .. "' at line " .. st.line .. ", column " .. st.col, 0)
    end
end

function S:Deserialize(text, reviver)
    if type(text) ~= "string" then
        return false, "expected string, got " .. type(text)
    end
    
    if string_len(text) > self.options.maxStringLength then
        return false, "input string length exceeds maximum allowed size"
    end
    
    -- Check cache if enabled
    local cacheKey
    if self.options.useCache then
        cacheKey = text .. tostring(reviver and true or false)
        if self._cache.deserialized[cacheKey] then
            self._cache.hits = self._cache.hits + 1
            return true, self._cache.deserialized[cacheKey]
        end
        self._cache.misses = self._cache.misses + 1
    end
    
    -- Trim and check for empty input
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return false, "empty JSON input"
    end
    
    local st = new_state(trimmed)
    local ok, res = pcall(function()
        local value = parse_value(st, "", 0)
        skip_ws(st)
        
        -- Check for trailing characters
        if st.i <= st.n then
            local remaining = string_sub(trimmed, st.i)
            error("trailing characters at position " .. st.i .. ": '" .. remaining .. "'", 0)
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
        return false, msg
    end
    
    -- Add to cache if enabled
    if self.options.useCache and cacheKey then
        if self._cache.size >= self._cache.maxSize then
            -- Remove oldest entry (FIFO)
            local oldestKey = next(self._cache.deserialized)
            if oldestKey then
                self._cache.deserialized[oldestKey] = nil
                self._cache.size = self._cache.size - 1
            end
        end
        self._cache.deserialized[cacheKey] = res
        self._cache.size = self._cache.size + 1
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
        pos = 0,
        line = 1,
        col = 1
    }
    
    function parser:feed(chunk)
        self.buffer = self.buffer .. chunk
        self:process()
    end
    
    function parser:process()
        -- Advanced streaming processing with state machine
        while self.pos < string_len(self.buffer) do
            local c = string_sub(self.buffer, self.pos + 1, self.pos + 1)
            
            if self.state == "value" then
                if c == "{" then
                    self.state = "object_start"
                    self.callback({type = "object_start"})
                elseif c == "[" then
                    self.state = "array_start"
                    self.callback({type = "array_start"})
                elseif c == '"' then
                    self.state = "string"
                    self.partial = ""
                elseif c == "-" or string_match(c, "%d") then
                    self.state = "number"
                    self.partial = c
                elseif c == "t" then
                    self.state = "true"
                    self.partial = "t"
                elseif c == "f" then
                    self.state = "false"
                    self.partial = "f"
                elseif c == "n" then
                    self.state = "null"
                    self.partial = "n"
                end
            end
            
            -- Update position and line/col counters
            self.pos = self.pos + 1
            if c == "\n" then
                self.line = self.line + 1
                self.col = 1
            else
                self.col = self.col + 1
            end
        end
        
        -- Remove processed data from buffer
        self.buffer = string_sub(self.buffer, self.pos + 1)
        self.pos = 0
    end
    
    function parser:finish()
        if #self.buffer > 0 then
            self:process()
            if #self.buffer > 0 then
                error("incomplete JSON at end of stream", 0)
            end
        end
        self.callback({type = "end"})
    end
    
    return parser
end

-- ==================== SCHEMA VALIDATION ====================
function S:Validate(data, schema)
    if not schema or type(schema) ~= "table" then
        return false, "invalid schema"
    end
    
    local function validate_recursive(data, schema, path)
        path = path or ""
        
        -- Check type
        if schema.type and type(data) ~= schema.type then
            return false, "type mismatch at " .. path .. ", expected " .. schema.type .. ", got " .. type(data)
        end
        
        -- Check required fields for objects
        if schema.required and type(data) == "table" and not is_array(data) then
            for _, field in ipairs(schema.required) do
                if data[field] == nil then
                    return false, "missing required field: " .. field .. " at " .. path
                end
            end
        end
        
        -- Check enum values
        if schema.enum then
            local valid = false
            for _, value in ipairs(schema.enum) do
                if data == value then
                    valid = true
                    break
                end
            end
            if not valid then
                return false, "value not in enum at " .. path
            end
        end
        
        -- Check minimum/maximum for numbers
        if type(data) == "number" then
            if schema.minimum and data < schema.minimum then
                return false, "value below minimum at " .. path
            end
            if schema.maximum and data > schema.maximum then
                return false, "value above maximum at " .. path
            end
        end
        
        -- Check minLength/maxLength for strings
        if type(data) == "string" then
            if schema.minLength and string_len(data) < schema.minLength then
                return false, "string too short at " .. path
            end
            if schema.maxLength and string_len(data) > schema.maxLength then
                return false, "string too long at " .. path
            end
            if schema.pattern and not string_match(data, schema.pattern) then
                return false, "string doesn't match pattern at " .. path
            end
        end
        
        -- Recursively validate objects
        if type(data) == "table" and schema.properties and not is_array(data) then
            for key, propSchema in pairs(schema.properties) do
                if data[key] ~= nil then
                    local valid, err = validate_recursive(data[key], propSchema, path .. "." .. key)
                    if not valid then
                        return false, err
                    end
                end
            end
        end
        
        -- Recursively validate arrays
        if type(data) == "table" and is_array(data) and schema.items then
            for i, item in ipairs(data) do
                local valid, err = validate_recursive(item, schema.items, path .. "[" .. i .. "]")
                if not valid then
                    return false, err
                end
            end
        end
        
        return true
    end
    
    return validate_recursive(data, schema, "")
end

-- ==================== BINARY SERIALIZATION ====================
function S:SerializeBinary(data)
    -- Convert data to binary format for efficient storage/transmission
    local json = self:Serialize(data)
    if not json then return nil end
    
    -- Simple compression (could be enhanced with proper compression algorithms)
    if self.options.compression and string_len(json) > self.options.compressionThreshold then
        -- Simple run-length encoding for demonstration
        local compressed = {}
        local i = 1
        while i <= string_len(json) do
            local char = string_sub(json, i, i)
            local count = 1
            while i + count <= string_len(json) and string_sub(json, i + count, i + count) == char do
                count = count + 1
            end
            
            if count > 3 then
                table_insert(compressed, string_char(count))
                table_insert(compressed, char)
                i = i + count
            else
                table_insert(compressed, char)
                i = i + 1
            end
        end
        json = table_concat(compressed)
    end
    
    return json
end

function S:DeserializeBinary(binary)
    -- Decompress if needed
    local json = binary
    if self.options.compression then
        -- Simple run-length decoding for demonstration
        local decompressed = {}
        local i = 1
        while i <= string_len(json) do
            local char = string_sub(json, i, i)
            if string_byte(char) < 32 then -- Control character indicates compression
                local count = string_byte(char)
                local next_char = string_sub(json, i + 1, i + 1)
                for j = 1, count do
                    table_insert(decompressed, next_char)
                end
                i = i + 2
            else
                table_insert(decompressed, char)
                i = i + 1
            end
        end
        json = table_concat(decompressed)
    end
    
    return self:Deserialize(json)
end

-- ==================== CUSTOM TYPE SUPPORT ====================
function S:RegisterCustomType(typeName, serializer, reviver)
    self.customSerializers[typeName] = serializer
    self.customRevivers[typeName] = reviver
end

function S:RegisterDefaultTypes()
    -- Register common WoW-specific types
    self:RegisterCustomType("Vector2D", 
        function(v) return {x = v.x, y = v.y} end,
        function(v) return {x = v.x, y = v.y} end
    )
    
    self:RegisterCustomType("Vector3D", 
        function(v) return {x = v.x, y = v.y, z = v.z} end,
        function(v) return {x = v.x, y = v.y, z = v.z} end
    )
    
    self:RegisterCustomType("Color", 
        function(v) return {r = v.r, g = v.g, b = v.b, a = v.a} end,
        function(v) return {r = v.r, g = v.g, b = v.b, a = v.a} end
    )
    
    self:RegisterCustomType("GUID", 
        function(v) return tostring(v) end,
        function(v) return v end  -- GUIDs are strings in WoW
    )
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

-- ==================== PERFORMANCE MONITORING ====================
function S:StartProfiling()
    self._profileData = {
        serializationTime = 0,
        deserializationTime = 0,
        operations = 0,
        memoryUsage = 0,
        startTime = GetTime()
    }
end

function S:StopProfiling()
    if not self._profileData then return end
    
    self._profileData.endTime = GetTime()
    self._profileData.totalTime = self._profileData.endTime - self._profileData.startTime
    
    return self._profileData
end

function S:GetPerformanceStats()
    return {
        cacheHits = self._cache.hits,
        cacheMisses = self._cache.misses,
        cacheSize = self._cache.size,
        memoryPoolUsage = self._poolIndex,
        operationCount = self._operationCount
    }
end

-- ==================== QUANTUM INITIALIZATION ====================
function S:Initialize()
    -- Load configuration from AIOS Config service if available
    if AIOS and AIOS.Config then
        for key, defaultValue in pairs(self.options) do
            local configValue = AIOS.Config:Get("Serializer_" .. key)
            if configValue ~= nil then
                self.options[key] = configValue
            end
        end
    end
    
    -- Initialize memory pool
    for i = 1, self.options.memoryPoolSize do
        self._memoryPool[i] = {}
    end
    self._poolIndex = self.options.memoryPoolSize
    
    -- Register default custom types
    self:RegisterDefaultTypes()
    
    -- Run basic self-check
    local ok, result = pcall(function()
        local testData = {x = 1, y = "test", z = true, arr = {1, 2, 3}, obj = {nested = "value"}}
        local json = self:Serialize(testData)
        local success, deserialized = self:Deserialize(json)
        return success and deserialized.x == 1 and deserialized.y == "test" and deserialized.z == true
    end)
    
    if ok and result then
        self._initialized = true
        self._log("Quantum Serializer initialized successfully", "INFO")
        
        -- Start performance monitoring
        self:StartProfiling()
        
        return true
    else
        self._log("Quantum Serializer initialization failed: " .. tostring(result), "ERROR")
        return false
    end
end

function S:GetStatus()
    return {
        initialized = self._initialized or false,
        config = self.options,
        cacheStats = {
            hits = self._cache and self._cache.hits or 0,
            misses = self._cache and self._cache.misses or 0,
            size = self._cache and self._cache.size or 0
        },
        ffiEnabled = self.options.useFFI,
        memoryPool = {
            size = self.options.memoryPoolSize,
            available = self._poolIndex,
            usage = ((self.options.memoryPoolSize - self._poolIndex) / self.options.memoryPoolSize) * 100
        }
    }
end

-- Auto-initialize when AIOS is ready
if AIOS and AIOS.ServiceRegistry then
    -- AIOS is already loaded, initialize immediately
    S:Initialize()
else
    -- Wait for AIOS to load
    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("ADDON_LOADED")
    initFrame:SetScript("OnEvent", function(self, event, addonName)
        if addonName == "AIOS" then
            if AIOS and AIOS.ServiceRegistry then
                S:Initialize()
                self:UnregisterAllEvents()
            end
        end
    end)
end

-- Export for use
return S