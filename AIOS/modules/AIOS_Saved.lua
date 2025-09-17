--[[
AIOS_Saved.lua — Advanced Reactive Data Persistence System
Version: 1.0.0
Author: PoorKingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.info/
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev


Purpose:
  Provides schema-based, reactive SavedVariables handling for all AIOS modules and addons.
  Features include:
    • Namespaced schemas with defaults, validation, and version migration
    • Profile, character, and global scopes
    • Reactive state updates with EventBus integration
    • Async (Promise-based) Get/Set/Reset operations
    • Full profile management (switching, copying, migration)

Notes:
  • Safe across Retail (11.x), Classic Era (1.15.x), and MoP Classic (5.4.x).
  • Gracefully integrates with AIOS.Utils, Logger, and EventBus if present.
  • Defaults and migrations apply automatically on schema registration.
  • Reactive stores can be directly bound to UI elements or logic flows.

API Reference:
  SV:RegisterSchema(ns, defaults, opts)         → schema
  SV:Get(ns, key, fallback, scope)             → value
  SV:Set(ns, key, value, scope)                → newValue
  SV:Reset(ns, scope)                          → resets namespace
  SV:OnChanged(ns, fn)                         → subscription handle
  SV:GetAsync(ns, key, fallback, scope)        → Promise
  SV:SetAsync(ns, key, value, scope)           → Promise
  SV:ResetAsync(ns, scope)                     → Promise
  SV:GetProfile()                              → profileName
  SV:SwitchProfile(name)                       → profileName
  SV:CopyProfile(src, dst, overwrite)          → success/err
  SV:GetReactiveStore(ns, scope)               → reactiveStore
  SV:GetDiagnostics()                          → { namespaces, profiles, memory }
  SV:GetAllNamespaces()                        → {ns,...}
  SV:GetAllProfiles()                          → {profiles,...}
  SV:GetAllCharacters()                        → {characters,...}
  SV:TestMigration(ns, fromVer, toVer)         → {success, error, result}
  SV:EnableDebugHooks()                        → enables reactive debug tracing
  SV:SetDebugCallback(fn)                      → register debug callback
  SV:ExportRawData()                           → snapshot of root + schemas

This file is 
  - Built-in migration testing UI panel
  - Profile export/import with compression
  - Integration with AIOS RuntimeProfile for context-aware defaults
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Saved = AIOS.Saved or {}
local SV = AIOS.Saved

-- ========= Dependency Injection Ready =========
local function resolveService(serviceName)
    if AIOS.Utils and AIOS.Utils.ResolveService then
        return AIOS.Utils.ResolveService(serviceName)
    end
    return AIOS[serviceName] -- Fallback
end

local function getUtils() return resolveService("Utils") end
local function getEventBus() return resolveService("EventBus") end
local function getLogger() return resolveService("Logger") end

-- Safe logging with graceful fallbacks
local function clog(msg, level, tag)
    local logger = getLogger()
    if logger and logger.Log then
        pcall(logger.Log, logger, level or "debug", tag or "Saved", msg)
    elseif AIOS.CoreLog then
        pcall(AIOS.CoreLog, msg, level or "debug", tag or "Saved")
    end
end

-- ========= Core Data Structures =========
local ROOT = _G.AIOS_Saved or {}
_G.AIOS_Saved = ROOT

-- Ensure sane structure with reactive awareness
ROOT.char = ROOT.char or {}
ROOT.global = ROOT.global or {}
ROOT.profiles = ROOT.profiles or {}
ROOT.profileKeys = ROOT.profileKeys or {}
ROOT.versions = ROOT.versions or {}

SV._schemas = SV._schemas or {}
SV._callbacks = SV._callbacks or {}
SV._reactives = SV._reactives or {} -- Reactive state trackers

-- ========= Utility Functions (Preserved from original) =========
local function split_path(key)
    if key == nil then return {} end
    local t = {}
    for seg in tostring(key):gmatch("[^%.]+") do
        local n = tonumber(seg)
        t[#t+1] = n and math.floor(n) or seg
    end
    return t
end

local function pluck_path(tbl, path, create)
    local cur = tbl
    for i=1,#path-1 do
        local k = path[i]
        local nxt = cur[k]
        if nxt == nil then
            if not create then return nil, k end
            nxt = {}
            cur[k] = nxt
        elseif type(nxt) ~= "table" then
            return nil, k
        end
        cur = nxt
    end
    return cur, path[#path]
end

local function deep_apply_defaults(dst, def)
    if type(def) ~= "table" then return end
    for k,v in pairs(def) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            deep_apply_defaults(dst[k], v)
        else
            if dst[k] == nil then dst[k] = v end
        end
    end
end

local function deep_clone(src)
    if type(src) ~= "table" then return src end
    local t = {}
    for k,v in pairs(src) do
        if type(v) == "table" then t[k] = deep_clone(v) else t[k] = v end
    end
    return t
end

local function _toon()
    local name = (_G.UnitName and _G.UnitName("player")) or "Unknown"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or "Realm"
    return name.."-"..realm
end

local function _scope_root(scope, toon)
    if scope == "global" then
        return ROOT.global
    elseif scope == "char" then
        ROOT.char[toon] = ROOT.char[toon] or {}
        return ROOT.char[toon]
    else
        local p = ROOT.profileKeys[toon] or "Default"
        ROOT.profileKeys[toon] = p
        ROOT.profiles[p] = ROOT.profiles[p] or {}
        return ROOT.profiles[p]
    end
end

local function _store_for(ns, scope, createIfMissing)
    scope = scope or (SV._schemas[ns] and SV._schemas[ns].scope) or "profile"
    local toon = _toon()
    local root = _scope_root(scope, toon)
    if createIfMissing and root[ns] == nil then
        root[ns] = {}
    end
    return root[ns], scope
end

local function _apply_defaults_for(ns, scope)
    local sch = SV._schemas[ns]; if not sch then return end
    local store = _store_for(ns, scope, true)
    deep_apply_defaults(store, sch.defaults or {})
end

local function _run_migration(ns, scope, prevVer, newVer)
    local sch = SV._schemas[ns]; if not sch then return end
    if type(sch.migrate) ~= "function" then return end
    local store = _store_for(ns, scope, true)
    local ok, err = pcall(sch.migrate, store, prevVer or 0, newVer or sch.version or 1)
    if not ok then clog("[Saved] migration error for "..ns..": "..tostring(err), "error") end
end

local function _emit(sig, ...)
    if AIOS and AIOS.SignalHub and AIOS.SignalHub.Emit then
        AIOS.SignalHub:Emit(sig, ...)
    end
end

-- ========= Reactive Data System =========
function SV:CreateReactiveStore(ns, scope)
    local store, scopeName = _store_for(ns, scope, true)
    local utils = getUtils()
    
    local reactiveStore = utils.ReactiveState(store, function(key, newValue, oldValue)
        local eventBus = getEventBus()
        if eventBus and eventBus.Emit then
            eventBus:Emit("REACTIVE_DATA_CHANGED", ns, key, newValue, oldValue, scopeName)
        end
        
        -- Notify traditional callbacks
        local cbs = SV._callbacks[ns]
        if cbs then
            for _, fn in ipairs(cbs) do
                if type(fn) == "function" then
                    utils.SafeCall(fn, ns, key, newValue, scopeName)
                end
            end
        end
    end)
    
    SV._reactives[ns] = SV._reactives[ns] or {}
    SV._reactives[ns][scopeName] = reactiveStore
    return reactiveStore
end

function SV:GetReactiveStore(ns, scope)
    scope = scope or (SV._schemas[ns] and SV._schemas[ns].scope) or "profile"
    SV._reactives[ns] = SV._reactives[ns] or {}
    
    if not SV._reactives[ns][scope] then
        return self:CreateReactiveStore(ns, scope)
    end
    
    return SV._reactives[ns][scope]
end

-- ========= Advanced Migration System =========
function SV:RegisterSchema(ns, defaults, opts)
    if type(ns) ~= "string" then return nil, "Namespace must be string" end
    
    opts = opts or {}
    local scope = opts.scope or "profile"
    local version = tonumber(opts.version) or 1
    local migrate = opts.migrate
    local validate = opts.validate

    SV._schemas[ns] = {
        defaults = deep_clone(defaults or {}),
        scope = scope,
        version = version,
        migrate = migrate,
        validate = validate
    }

    -- Ensure store exists and apply defaults
    _apply_defaults_for(ns, scope)

    -- Version-aware migration
    ROOT.versions[ns] = ROOT.versions[ns] or 0
    local prevVer = ROOT.versions[ns]
    
    if prevVer < version then
        if type(migrate) == "function" then
            local store = _store_for(ns, scope, true)
            local ok, err = pcall(migrate, store, prevVer, version)
            if not ok then
                clog("Migration failed for " .. ns .. ": " .. tostring(err), "error")
            end
        end
        ROOT.versions[ns] = version
    end

    -- Create reactive store
    self:GetReactiveStore(ns, scope)

    return SV._schemas[ns]
end

-- ========= Promise-Based Data Operations =========
function SV:GetAsync(ns, key, fallback, scopeOverride)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve)
        resolve(self:Get(ns, key, fallback, scopeOverride))
    end)
end

function SV:SetAsync(ns, key, value, scopeOverride)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve, reject)
        local success, result = pcall(self.Set, self, ns, key, value, scopeOverride)
        if success then
            resolve(result)
        else
            reject(result)
        end
    end)
end

function SV:ResetAsync(ns, scopeOverride)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve, reject)
        local success, result = pcall(self.Reset, self, ns, scopeOverride)
        if success then
            resolve(result)
        else
            reject(result)
        end
    end)
end

-- ========= Core API (Enhanced) =========
function SV:Get(ns, key, fallback, scopeOverride)
    local store = _store_for(ns, scopeOverride, true)
    if key == nil or key == "" then return store end
    
    local path = split_path(key)
    local parent, leaf = pluck_path(store, path, false)
    if not parent then return fallback end
    
    local value = parent[leaf]
    if value == nil then
        -- Lazy default materialization
        local sch = SV._schemas[ns]
        if sch and sch.defaults then
            local defParent, defLeaf = pluck_path(sch.defaults, path, false)
            if defParent and defParent[defLeaf] ~= nil then
                parent[leaf] = deep_clone(defParent[defLeaf])
                return parent[leaf]
            end
        end
        return fallback
    end
    return value
end

function SV:Set(ns, key, value, scopeOverride)
    if key == nil then return nil, "Key required" end
    
    local store, scope = _store_for(ns, scopeOverride, true)
    local path = split_path(key)
    local parent, leaf = pluck_path(store, path, true)
    
    if not parent then return nil, "Invalid path" end
    
    -- Validation
    local sch = SV._schemas[ns]
    if sch and sch.validate and type(sch.validate) == "function" then
        local utils = getUtils()
        local ok, err = utils.SafeCall(sch.validate, value, key)
        if not ok then
            return nil, "Validation failed: " .. tostring(err)
        end
    end
    
    local oldValue = parent[leaf]
    parent[leaf] = value
    
    -- Notify through reactive system
    local reactiveStore = self:GetReactiveStore(ns, scope)
    if reactiveStore then
        reactiveStore[leaf] = value -- This will trigger reactive updates
    else
        -- Fallback to traditional notification
        local cbs = SV._callbacks[ns]
        if cbs then
            for _, fn in ipairs(cbs) do
                if type(fn) == "function" then
                    pcall(fn, ns, key, value, scope)
                end
            end
        end
        _emit("AIOS_SETTING_CHANGED", ns, key, value, scope)
    end
    
    return value
end

function SV:Reset(ns, scopeOverride)
    local sch = SV._schemas[ns]; if not sch then return end
    local store, scope = _store_for(ns, scopeOverride, true)
    for k,_ in pairs(store) do store[k] = nil end
    deep_apply_defaults(store, sch.defaults or {})
    _emit("AIOS_SETTING_CHANGED", ns, "*reset*", nil, scope)
end

function SV:OnChanged(ns, fn)
    if type(fn)~="function" then return nil end
    local list = SV._callbacks[ns] or {}; SV._callbacks[ns] = list
    list[#list+1] = fn
    local h = { Cancel=function(self)
        for i=1,#list do if list[i]==fn then table.remove(list, i) break end end
    end }
    return h
end

function SV:GetProfile()
    local toon = _toon()
    local p = ROOT.profileKeys[toon] or "Default"
    ROOT.profileKeys[toon] = p
    return p
end

function SV:SwitchProfile(profileName)
    profileName = tostring(profileName or "Default")
    local toon = _toon()
    ROOT.profileKeys[toon] = profileName
    ROOT.profiles[profileName] = ROOT.profiles[profileName] or {}
    -- apply defaults for all profile-scoped namespaces
    for ns, sch in pairs(SV._schemas) do
        if sch.scope == "profile" then _apply_defaults_for(ns, "profile") end
    end
    _emit("AIOS_PROFILE_SWITCHED", profileName)
    return profileName
end

function SV:CopyProfile(srcName, dstName, overwrite)
    srcName = tostring(srcName or "Default")
    dstName = tostring(dstName or "Default")
    if srcName == dstName then return true end
    ROOT.profiles[srcName] = ROOT.profiles[srcName] or {}
    ROOT.profiles[dstName] = ROOT.profiles[dstName] or {}
    local src = ROOT.profiles[srcName]
    local dst = ROOT.profiles[dstName]
    if not overwrite and next(dst) ~= nil then
        return nil, "destination profile not empty (use overwrite=true)"
    end
    for ns, tbl in pairs(src) do
        dst[ns] = deep_clone(tbl)
    end
    return true
end

-- ========= DI Registration =========
local function initializeSaved()
    local utils = getUtils()
    if utils and utils.RegisterService then
        utils:RegisterService("Saved", function() return SV end)
    end
end

initializeSaved()

-- ========= DEBUGGING & DIAGNOSTICS API =========
-- These hooks allow third-party debug tools to inspect and monitor the SavedVariables system
-- without adding any overhead or bloat to the production code.

function SV:GetDiagnostics()
    return {
        totalNamespaces = self:GetNamespaceCount(),
        totalProfiles = self:GetProfileCount(),
        totalCharacters = self:GetCharacterCount(),
        memoryUsage = self:EstimateMemoryUsage(),
        schemaStats = self:GetSchemaStatistics()
    }
end

function SV:GetNamespaceCount()
    local count = 0
    for _ in pairs(SV._schemas or {}) do count = count + 1 end
    return count
end

function SV:GetProfileCount()
    local count = 0
    for _ in pairs(ROOT.profiles or {}) do count = count + 1 end
    return count
end

function SV:GetCharacterCount()
    local count = 0
    for _ in pairs(ROOT.char or {}) do count = count + 1 end
    return count
end

function SV:EstimateMemoryUsage()
    local utils = getUtils()
    if utils and utils.EstimateTableSize then
        return utils.EstimateTableSize(ROOT)
    end
    return collectgarbage("count") * 1024
end

function SV:GetSchemaStatistics()
    local stats = {}
    for ns, schema in pairs(SV._schemas or {}) do
        stats[ns] = {
            scope = schema.scope,
            version = schema.version,
            hasMigration = type(schema.migrate) == "function",
            hasValidation = type(schema.validate) == "function"
        }
    end
    return stats
end

function SV:InspectNamespace(ns)
    if not SV._schemas or not SV._schemas[ns] then
        return nil, "Namespace not found"
    end
    
    local schema = SV._schemas[ns]
    local store = _store_for(ns, schema.scope, false)
    
    return {
        schema = {
            scope = schema.scope,
            version = schema.version,
            hasDefaults = schema.defaults ~= nil,
            hasMigration = type(schema.migrate) == "function",
            hasValidation = type(schema.validate) == "function"
        },
        data = store and deep_clone(store) or {},
        reactiveStore = SV._reactives[ns] and SV._reactives[ns][schema.scope] or nil
    }
end

function SV:GetAllNamespaces()
    local namespaces = {}
    for ns in pairs(SV._schemas or {}) do
        table.insert(namespaces, ns)
    end
    table.sort(namespaces)
    return namespaces
end

function SV:GetAllProfiles()
    local profiles = {}
    for name in pairs(ROOT.profiles or {}) do
        table.insert(profiles, name)
    end
    table.sort(profiles)
    return profiles
end

function SV:GetAllCharacters()
    local characters = {}
    for toon in pairs(ROOT.char or {}) do
        table.insert(characters, toon)
    end
    table.sort(characters)
    return characters
end

function SV:TestMigration(ns, fromVersion, toVersion)
    if not SV._schemas or not SV._schemas[ns] then
        return nil, "Namespace not found"
    end
    
    local schema = SV._schemas[ns]
    if type(schema.migrate) ~= "function" then
        return nil, "No migration function defined"
    end
    
    local testData = deep_clone(schema.defaults or {})
    local ok, err = pcall(schema.migrate, testData, fromVersion, toVersion)
    
    return {
        success = ok,
        error = err,
        result = testData
    }
end

function SV:EnableDebugHooks()
    SV._debugHooksEnabled = true
    
    local eventBus = getEventBus()
    if eventBus then
        eventBus:On("REACTIVE_DATA_CHANGED", function(ns, key, newValue, oldValue, scope)
            if SV._debugHooksEnabled and SV._onDebugEvent then
                SV._onDebugEvent("REACTIVE_DATA_CHANGED", ns, key, newValue, oldValue, scope)
            end
        end)
        
        eventBus:On("AIOS_SETTING_CHANGED", function(ns, key, value, scope)
            if SV._debugHooksEnabled and SV._onDebugEvent then
                SV._onDebugEvent("SETTING_CHANGED", ns, key, value, nil, scope)
            end
        end)
    end
end

function SV:SetDebugCallback(callback)
    if type(callback) == "function" then
        SV._onDebugEvent = callback
        return true
    end
    return false
end

function SV:ExportRawData()
    return {
        root = deep_clone(ROOT),
        schemas = deep_clone(SV._schemas or {}),
        callbacks = SV._callbacks and #SV._callbacks or 0,
        reactives = SV._reactives and #SV._reactives or 0
    }
end

return SV