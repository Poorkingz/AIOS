--[[
AIOS_ConfigCore
Version: 1.0
Author: Poorkingz
Project: AIOS Core Library

Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Support: support@aioswow.dev

Purpose:
Provides a centralized configuration service for the AIOS ecosystem.
Includes schema registration, validation, defaults, path-based access,
batch updates, serialization (string & JSON), event hooks, and metrics.

Key API Functions:
- Config:RegisterSchema(appId, schema, opts)
- Config:Get(appId, path)
- Config:Set(appId, path, value)
- Config:BatchSet(appId, changes)
- Config:Reset(appId)
- Config:Serialize(appId) / Config:Deserialize(appId, serialized)
- Config:ExportJSON(appId) / Config:ImportJSON(appId, json)
- Config:OnChanged(appId, fn), OnLoaded, OnReset, OnValidateFailed
- Config:Unsubscribe(appId, token)
- Config:GetMetrics(), Config:ClearCache()
- Config:TableToString(tbl), Config:StringToTable(str)

Notes:
- Fully self-contained (no Ace3/LibStub).
- Supports nested schema defaults & advanced validation rules.
- Emits events both locally and via AIOS EventBus.
- Includes slash command `/aiosconfig` for built-in self-test.
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Config = AIOS.Config or {}

local Config = AIOS.Config

-- =========================================================================
-- Internal Storage (self-contained)
-- =========================================================================
Config._storage = _G.AIOS_ConfigStorage or {}
_G.AIOS_ConfigStorage = Config._storage

Config._schemas = setmetatable({}, {__mode = "v"})
Config._defaults = setmetatable({}, {__mode = "v"})
Config._localSubs = setmetatable({}, {__mode = "kv"})
Config._lastEvent = nil
Config._cache = setmetatable({}, {__mode = "v"})
Config._metrics = {
    schemas = 0, changes = 0,
    cacheHits = 0, cacheMisses = 0,
    validationFailures = 0,
    events = 0, eventTime = 0
}
Config._pathMemo = setmetatable({}, {__mode = "k"})
Config._schemaNodeCache = setmetatable({}, {__mode = "k"})

-- =========================================================================
-- Service Registration (immediate, safe)
-- =========================================================================
if AIOS and AIOS.Utils and AIOS.Utils.RegisterService then
    AIOS.Utils.RegisterService("ConfigCore", function() return Config end)
end

-- =========================================================================
-- Path Utilities with Memoization
-- =========================================================================
local function splitPath(path)
    if type(path) ~= "string" or path == "" then return {} end
    local memo = Config._pathMemo[path]
    if memo then return memo end
    local out = {}
    for part in string.gmatch(path, "[^%.]+") do
        if part ~= "" then table.insert(out, part) end
    end
    Config._pathMemo[path] = out
    return out
end

local function ensure(tbl, key)
    if type(tbl) ~= "table" then return {} end
    local t = tbl[key]
    if t == nil then
        t = {}
        tbl[key] = t
    end
    return t
end

local function setByPath(root, path, value)
    local p = splitPath(path)
    if #p == 0 then return end
    local t = root
    for i = 1, #p - 1 do t = ensure(t, p[i]) end
    t[p[#p]] = value
end

local function getByPath(root, path)
    local p = splitPath(path)
    if #p == 0 then return nil end
    local t = root
    for i = 1, #p do
        if type(t) ~= "table" then return nil end
        t = t[p[i]]
        if t == nil then return nil end
    end
    return t
end

-- =========================================================================
-- Defaults with Nested Support
-- =========================================================================
local function applyDefaults(dst, src)
    if type(src) ~= "table" then return end
    for k, v in pairs(src) do
        if type(v) == "table" then
            local subt = dst[k]
            if type(subt) ~= "table" then
                subt = {}
                dst[k] = subt
            end
            applyDefaults(subt, v)
        else
            if dst[k] == nil then dst[k] = v end
        end
    end
end

local function collectDefaults(schema, defaultsOut)
    local function walk(node, currentPath)
        if type(node) ~= "table" then return end
        if node.default ~= nil then
            setByPath(defaultsOut, currentPath, node.default)
        end
        local kids = node.children or node.args
        if type(kids) == "table" then
            for key, child in pairs(kids) do
                local newPath = currentPath == "" and tostring(key) or currentPath .. "." .. tostring(key)
                walk(child, newPath)
            end
        end
    end
    walk(schema, "")
end

-- =========================================================================
-- Schema Node Finder with Caching - DEBUG VERSION
-- =========================================================================
local function findSchemaNode(schema, path)
    local cacheKey = tostring(schema) .. "|" .. path
    local cached = Config._schemaNodeCache[cacheKey]
    if cached ~= nil then return cached end
    
    print("DEBUG: findSchemaNode looking for path:", path, "in schema:", schema)
    
    if not schema or type(schema) ~= "table" then 
        Config._schemaNodeCache[cacheKey] = false
        return nil 
    end
    
    local p = splitPath(path)
    if #p == 0 then 
        Config._schemaNodeCache[cacheKey] = false
        return nil 
    end
    
    -- Start from schema root and traverse through children
    local current = schema
    for i = 1, #p do
        local part = p[i]
        local children = current.children or current.args
        if not children or type(children) ~= "table" then
            Config._schemaNodeCache[cacheKey] = false
            return nil
        end
        
        -- Look for a child with matching key (not path)
        local found = false
        for key, child in pairs(children) do
            if key == part then
                current = child
                found = true
                break
            end
        end
        
        if not found then
            Config._schemaNodeCache[cacheKey] = false
            return nil
        end
    end
    
    Config._schemaNodeCache[cacheKey] = current
    print("DEBUG: Found schema node:", current)
    return current
end

-- =========================================================================
-- Advanced Validation
-- =========================================================================
local function validateValue(value, rules)
    if not rules then return true end
    local vtype = type(value)
    if rules.type and vtype ~= rules.type then
        Config._metrics.validationFailures = Config._metrics.validationFailures + 1
        return false, "Type mismatch: expected " .. rules.type .. ", got " .. vtype
    end
    if vtype == "number" then
        if rules.min and value < rules.min then
            Config._metrics.validationFailures = Config._metrics.validationFailures + 1
            return false, "Value below min: " .. value .. " < " .. rules.min
        end
        if rules.max and value > rules.max then
            Config._metrics.validationFailures = Config._metrics.validationFailures + 1
            return false, "Value above max: " .. value .. " > " .. rules.max
        end
    elseif vtype == "string" then
        if rules.pattern and not string.match(value, rules.pattern) then
            Config._metrics.validationFailures = Config._metrics.validationFailures + 1
            return false, "String does not match pattern"
        end
        if rules.enum and not rules.enum[value] then
            Config._metrics.validationFailures = Config._metrics.validationFailures + 1
            return false, "Value not in enum"
        end
    end
    if rules.custom and type(rules.custom) == "function" and not rules.custom(value) then
        Config._metrics.validationFailures = Config._metrics.validationFailures + 1
        return false, "Custom validation failed"
    end
    return true
end

-- =========================================================================
-- Event System (self-contained)
-- =========================================================================
local function emitEvent(event, appId, ...)
    local start = _G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)
    Config._lastEvent = { event = event, appId = appId, args = {...}, t = start }
    
    local list = Config._localSubs[appId]
    if list then
        for _, fn in pairs(list) do
            pcall(fn, event, appId, ...)
        end
    end
    
    Config._metrics.events = Config._metrics.events + 1
    Config._metrics.eventTime = Config._metrics.eventTime + ((_G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)) - start)
    
    -- Emit to AIOS EventBus if available
    if AIOS.EventBus and AIOS.EventBus.Emit then
        AIOS.EventBus:Emit("AIOS_CONFIG_" .. event, appId, ...)
    end
end

local emitChanged = function(appId, path, newv, oldv) emitEvent("CHANGED", appId, path, newv, oldv) end
local emitLoaded = function(appId, store) emitEvent("LOADED", appId, store) end
local emitReset = function(appId) emitEvent("RESET", appId) end
local emitValidateFailed = function(appId, path, value, errorMsg) emitEvent("VALIDATE_FAILED", appId, path, value, errorMsg) end

-- =========================================================================
-- Simple Serialization (self-contained) - NOW PART OF CONFIG NAMESPACE
-- =========================================================================
function Config:TableToString(tbl, seen)
    seen = seen or {}
    if type(tbl) ~= "table" then
        if type(tbl) == "string" then return string.format("%q", tbl) end
        if type(tbl) == "number" or type(tbl) == "boolean" then return tostring(tbl) end
        return nil
    end
    if seen[tbl] then return "{}" end
    seen[tbl] = true
    
    local parts = {}
    for k, v in pairs(tbl) do
        local serializedKey
        if type(k) == "string" then
            serializedKey = string.format("%q", k)
        else
            serializedKey = tostring(k)
        end
        
        local serializedVal = self:TableToString(v, seen)
        if serializedVal then
            table.insert(parts, "[" .. serializedKey .. "]=" .. serializedVal)
        end
    end
    seen[tbl] = nil
    
    return "{" .. table.concat(parts, ",") .. "}"
end

function Config:StringToTable(str)
    if type(str) ~= "string" or str == "" then return {} end
    local func, err = loadstring("return " .. str)
    if not func then return {} end
    local ok, res = pcall(func)
    if not ok then return {} end
    if type(res) ~= "table" then return {} end
    return res
end

------------------------------------------------------
-- Unified Serialize / Deserialize
------------------------------------------------------
function Config:Serialize(appId)
    if type(appId) ~= "string" or appId == "" then return nil end
    local store = self._storage[appId] or {}
    return self:TableToString({ version = 1, data = store })
end

function Config:Deserialize(appId, serialized)
    if type(appId) ~= "string" or appId == "" or type(serialized) ~= "string" or serialized == "" then
        return
    end
    local tbl = self:StringToTable(serialized)
    if type(tbl) ~= "table" or not tbl.version or not tbl.data then return end
    self._storage[appId] = tbl.data
    self._cache[appId] = nil
    emitLoaded(appId, tbl.data)
    return tbl.data
end

------------------------------------------------------
-- JSON Bridge (cross-addon / SimLite use)
------------------------------------------------------
function Config:ExportJSON(appId)
    if type(appId) ~= "string" or appId == "" then return nil, "invalid appId" end
    if not AIOS or not AIOS.Serializer then return nil, "Serializer missing" end
    local store = self._storage[appId] or {}
    local payload = { version = 1, data = store }
    local ok, result = pcall(function()
        return AIOS.Serializer:Serialize(payload)
    end)
    return ok and result or nil
end

function Config:ImportJSON(appId, json)
    if type(appId) ~= "string" or appId == "" then return nil, "invalid appId" end
    if not AIOS or not AIOS.Serializer then return nil, "Serializer missing" end
    local ok, tbl = pcall(function()
        return AIOS.Serializer:Deserialize(json)
    end)
    if not ok or type(tbl) ~= "table" or not tbl.data then
        return nil, "invalid JSON"
    end
    self._storage[appId] = tbl.data
    self._cache[appId] = nil
    emitLoaded(appId, tbl.data)
    return tbl.data
end

-- =========================================================================
-- Schema Registration - FIXED VERSION
-- =========================================================================
function Config:RegisterSchema(appId, schema, opts)
    if type(appId) ~= "string" or appId == "" or type(schema) ~= "table" then return nil end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end

    print("DEBUG: RegisterSchema called with appId:", appId)

    local function validateSchema(node, depth, currentPath)
        if depth > 20 then return false end
        node.path = currentPath or ""
        
        if node.default ~= nil and not node.path then return false end
        if node.validate then
            local val = node.validate
            if type(val) ~= "table" then return false end
            if val.type and not ({string=true, number=true, boolean=true, table=true})[val.type] then return false end
            if val.min and type(val.min) ~= "number" then return false end
            if val.max and type(val.max) ~= "number" then return false end
            if val.pattern and type(val.pattern) ~= "string" then return false end
            if val.enum and type(val.enum) ~= "table" then return false end
        end
        
        local kids = node.children or node.args
        if kids then
            if type(kids) ~= "table" then return false end
            for key, child in pairs(kids) do
                local newPath = currentPath == "" and key or currentPath .. "." .. key
                if not validateSchema(child, depth + 1, newPath) then return false end
            end
        end
        return true
    end
    
    if not validateSchema(schema, 0, "") then 
        print("DEBUG: Schema validation failed")
        return nil 
    end

    self._schemas[appId] = schema
    local defaults = {}
    collectDefaults(schema, defaults)
    self._defaults[appId] = defaults

    print("DEBUG: Defaults collected:", defaults)

    -- Initialize storage with defaults
    Config._storage[appId] = Config._storage[appId] or {}
    applyDefaults(Config._storage[appId], defaults)
    
    print("DEBUG: Storage after defaults:", Config._storage[appId])
    
    emitLoaded(appId, Config._storage[appId])
    self._cache[appId] = nil
    self._metrics.schemas = self._metrics.schemas + 1
    
    print("DEBUG: Schema registered successfully")
    return { appId = appId }
end

-- =========================================================================
-- Get with Cache - DEBUG VERSION
-- =========================================================================
function Config:Get(appId, path)
    if type(appId) ~= "string" or appId == "" or type(path) ~= "string" or path == "" then return nil end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end

    print("DEBUG: Get called with appId:", appId, "path:", path)

    local cache = self._cache[appId]
    if cache then
        local val = getByPath(cache, path)
        if val ~= nil then
            self._metrics.cacheHits = self._metrics.cacheHits + 1
            print("DEBUG: Cache hit - value:", val)
            return val
        end
    end
    self._metrics.cacheMisses = self._metrics.cacheMisses + 1

    local store = Config._storage[appId]
    print("DEBUG: Storage for appId:", store)
    
    if not store then 
        print("DEBUG: No storage found, returning nil")
        return nil 
    end

    local val = getByPath(store, path)
    print("DEBUG: Raw value from storage:", val)
    
    -- Check if there's a default value in the schema
    if val == nil then
        local schema = self._schemas[appId]
        if schema then
            local node = findSchemaNode(schema, path)
            if node and node.default ~= nil then
                val = node.default
                print("DEBUG: Using default value:", val)
            end
        end
    end

    -- Cache the entire store for this appId
    if not self._cache[appId] then
        self._cache[appId] = store
    end
    
    print("DEBUG: Final value returned:", val)
    return val
end

-- =========================================================================
-- Set with Validation - DEBUG VERSION
-- =========================================================================
function Config:Set(appId, path, value)
    if type(appId) ~= "string" or appId == "" or type(path) ~= "string" or path == "" then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end

    print("DEBUG: Set called with appId:", appId, "path:", path, "value:", value)
    
    -- Get current value for comparison
    local old = self:Get(appId, path)
    print("DEBUG: Old value:", old)
    
    if old == value then 
        print("DEBUG: Value unchanged, returning")
        return 
    end

    local schema = self._schemas[appId]
    if not schema then 
        print("DEBUG: No schema found for appId:", appId)
        return 
    end
    
    local node = findSchemaNode(schema, path)
    if not node then 
        print("DEBUG: No schema node found for path:", path)
        return 
    end
    
    if node.validate then
        local isValid, errorMsg = validateValue(value, node.validate)
        if not isValid then
            print("DEBUG: Validation failed:", errorMsg)
            emitValidateFailed(appId, path, value, errorMsg)
            return
        end
    end

    -- Ensure storage exists for this appId
    Config._storage[appId] = Config._storage[appId] or {}
    local store = Config._storage[appId]
    
    print("DEBUG: Before set - store:", store)
    print("DEBUG: Before set - store.volume:", store and store.volume)
    
    -- Set the value using path
    setByPath(store, path, value)

    print("DEBUG: After set - store:", store)
    print("DEBUG: After set - store.volume:", store and store.volume)
    
    self._cache[appId] = nil
    emitChanged(appId, path, value, old)
    self._metrics.changes = self._metrics.changes + 1
    
    print("DEBUG: Set completed successfully")
end

-- =========================================================================
-- Transactional Batch Set
-- =========================================================================
function Config:BatchSet(appId, changes)
    if type(appId) ~= "string" or appId == "" or type(changes) ~= "table" then return false end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return false end

    local store = Config._storage[appId] or {}
    local emitted = {}
    local schema = self._schemas[appId]
    if not schema then return false end

    -- Validate all changes first
    local validChanges = {}
    for path, value in pairs(changes) do
        if type(path) == "string" and path ~= "" then
            local old = getByPath(store, path)
            if old ~= value then
                local node = findSchemaNode(schema, path)
                if node then
                    if node.validate then
                        local isValid, errorMsg = validateValue(value, node.validate)
                        if not isValid then
                            emitValidateFailed(appId, path, value, errorMsg)
                            return false
                        end
                    end
                    validChanges[path] = {value = value, old = old}
                end
            end
        end
    end

    if next(validChanges) == nil then return true end

    -- Apply all valid changes
    for path, ch in pairs(validChanges) do
        setByPath(store, path, ch.value)
        table.insert(emitted, {path = path, newv = ch.value, oldv = ch.old})
    end

    Config._storage[appId] = store
    self._cache[appId] = nil
    for _, ch in ipairs(emitted) do 
        emitChanged(appId, ch.path, ch.newv, ch.oldv) 
    end
    self._metrics.changes = self._metrics.changes + #emitted
    
    return true
end

-- =========================================================================
-- Reset
-- =========================================================================
function Config:Reset(appId)
    if type(appId) ~= "string" or appId == "" then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end

    local defaults = self._defaults[appId]
    if not defaults then return end

    Config._storage[appId] = {}
    applyDefaults(Config._storage[appId], defaults)

    self._cache[appId] = nil
    emitReset(appId)
end

-- =========================================================================
-- Event Subscription
-- =========================================================================
local subToken = 0
function Config:OnChanged(appId, fn)
    if type(appId) ~= "string" or appId == "" or type(fn) ~= "function" then return nil end
    local list = self._localSubs[appId] or {}
    self._localSubs[appId] = list
    subToken = subToken + 1
    local token = "changed_" .. subToken
    list[token] = function(event, a, p, n, o) if event == "CHANGED" and a == appId then fn(a, p, n, o) end end
    return token
end

function Config:OnLoaded(appId, fn)
    if type(appId) ~= "string" or appId == "" or type(fn) ~= "function" then return nil end
    local list = self._localSubs[appId] or {}
    self._localSubs[appId] = list
    subToken = subToken + 1
    local token = "loaded_" .. subToken
    list[token] = function(event, a, s) if event == "LOADED" and a == appId then fn(a, s) end end
    return token
end

function Config:OnReset(appId, fn)
    if type(appId) ~= "string" or appId == "" or type(fn) ~= "function" then return nil end
    local list = self._localSubs[appId] or {}
    self._localSubs[appId] = list
    subToken = subToken + 1
    local token = "reset_" .. subToken
    list[token] = function(event, a) if event == "RESET" and a == appId then fn(a) end end
    return token
end

function Config:OnValidateFailed(appId, fn)
    if type(appId) ~= "string" or appId == "" or type(fn) ~= "function" then return nil end
    local list = self._localSubs[appId] or {}
    self._localSubs[appId] = list
    subToken = subToken + 1
    local token = "validate_" .. subToken
    list[token] = function(event, a, p, v, e) if event == "VALIDATE_FAILED" and a == appId then fn(a, p, v, e) end end
    return token
end

function Config:Unsubscribe(appId, token)
    if type(appId) ~= "string" or appId == "" or type(token) ~= "string" then return end
    local list = self._localSubs[appId]
    if list then list[token] = nil end
end

-- =========================================================================
-- Metrics
-- =========================================================================
function Config:GetMetrics()
    local totalCache = self._metrics.cacheHits + self._metrics.cacheMisses
    return {
        schemas = self._metrics.schemas,
        changes = self._metrics.changes,
        cacheHits = self._metrics.cacheHits,
        cacheMisses = self._metrics.cacheMisses,
        validationFailures = self._metrics.validationFailures,
        events = self._metrics.events,
        cacheHitRate = totalCache > 0 and (self._metrics.cacheHits / totalCache) * 100 or 0,
        avgEventTime = self._metrics.events > 0 and self._metrics.eventTime / self._metrics.events or 0
    }
end

function Config:ClearCache()
    self._cache = setmetatable({}, {__mode = "v"})
    self._pathMemo = setmetatable({}, {__mode = "k"})
    Config._schemaNodeCache = setmetatable({}, {__mode = "k"})
end

-- =========================================================================
-- Initialization (delayed/safe if needed)
-- =========================================================================
Config._initialized = false

C_Timer.After(1, function()
    if not Config._initialized then
        Config._initialized = true
        -- future init work here
    end
end)

return Config