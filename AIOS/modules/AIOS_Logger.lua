--[[ 
AIOS_Logger.lua — Central Logging Framework
Version: 1.0.0
Author: PoorKingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.dev
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev

Purpose:
  Provides the AIOS ecosystem with a powerful, extensible logging system.
  Features developer-friendly log levels, sinks, filters, ring buffer,
  and context-aware exports. This is the backbone of AIOS diagnostics.

Notes:
  • Safe across Retail (11.x), Classic Era (1.15.x), and MoP Classic (5.4.x).
  • Falls back gracefully if ConfigCore/EventBus/Utils aren’t loaded.
  • Debug console sink is off by default to prevent spam in user chat.
  • Extensible via custom sinks, filters, and context binding.

API Reference:
  Logger:UpdateConfiguration()              -- Reloads config (debug.on / debug.level)
  Logger:AddSink(name, config)              -- Add sink {formatter, filter, writer, enabled}
  Logger:RemoveSink(name)                   -- Remove sink
  Logger:SetSinkEnabled(name, enabled)      -- Enable/disable sink
  Logger:AddFilter(name, fn)                -- Add filter function(payload) → bool
  Logger:RemoveFilter(name)                 -- Remove filter
  Logger:SetRingSize(newSize)               -- Set ring buffer size (100–10,000)
  Logger:ClearRing()                        -- Clear ring buffer
  Logger:Log(level, tag, msg, context)      -- Generic log entry
  Logger:Trace(msg, tag, context)           -- Trace level
  Logger:Debug(msg, tag, context)           -- Debug level
  Logger:Info(msg, tag, context)            -- Info level
  Logger:Warn(msg, tag, context)            -- Warn level
  Logger:Error(msg, tag, context)           -- Error level
  Logger:WithContext(context)               -- Returns logger bound to context
  Logger:GetEntries(filterOpts)             -- Get log entries {level, tag, since, limit}
  Logger:Export(filterOpts)                 -- Export entries as text
  Logger:GetLevelColor(level)               -- Get hex color for level
  Logger:IsEnabled()                        -- Returns true/false
  Logger:GetLevel()                         -- Returns current log level
  Logger:SetLevel(newLevel)                 -- Set log level (trace/debug/info/warn/error)
  Logger:Enable()                           -- Enable logging
  Logger:Disable()                          -- Disable logging

This file is 
  - Slash commands to toggle logging
  - Hooking directly into DebugLog/DevTools panels
  - UI viewer for live log stream
--]]

local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

local Logger = {}
AIOS.Logger = Logger

-- Safe ConfigCore accessor
function Logger:getConfig()
    if AIOS and AIOS.ServiceRegistry and AIOS.ServiceRegistry.GetService then
        local cfg = AIOS.ServiceRegistry.GetService("ConfigCore")
        if cfg then
            return cfg
        end
    end
    return nil -- gracefully fallback if not ready
end

-- ========= Dependency Injection Ready (Graceful) =========
local function resolveService(serviceName)
    if AIOS.Utils and AIOS.Utils.ResolveService then
        local success, service = pcall(AIOS.Utils.ResolveService, serviceName)
        if success then return service end
    end
    return AIOS[serviceName] -- Fallback
end

local function getUtils() 
    local utils = resolveService("Utils")
    return utils or AIOS.Utils or {}
end

local function getEventBus() 
    local eventBus = resolveService("EventBus") 
    return eventBus or AIOS.EventBus or AIOS.SignalHub
end

local function getConfig() 
    return resolveService("ConfigCore") 
end

-- ========= Advanced Logging Core =========
local LEVEL_ORDER = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }
local DEFAULT_LEVEL = "info"

-- Reactive log state
local logState = {
    enabled = false,
    level = DEFAULT_LEVEL,
    sinks = {},
    filters = {}
}

-- Ring buffer with smart management
local RING_MAX = 512
local ringBuffer = {}
local ringPosition = 0
local ringCount = 0

-- ========= Performance-Optimized Utilities =========
local function now_ms()
    return _G.debugprofilestop and _G.debugprofilestop() or ((_G.GetTime or function() return 0 end)() * 1000)
end

local function shouldLog(level)
    if not logState.enabled and level ~= "error" then
        return false
    end
    return (LEVEL_ORDER[level] or 99) >= (LEVEL_ORDER[logState.level] or LEVEL_ORDER[DEFAULT_LEVEL])
end

-- ========= Reactive Configuration (Graceful) =========
function Logger:UpdateConfiguration()
    local config = getConfig()
    
    -- Graceful configuration loading
    if config and type(config.Get) == "function" then
        local success, enabled = pcall(config.Get, config, "debug.on")
        if success then
            logState.enabled = not not enabled
        else
            logState.enabled = not not (AIOS.__debug_on or AIOS.__debug_mode)
        end
        
        local success, level = pcall(config.Get, config, "debug.level")
        if success and level and LEVEL_ORDER[level] then
            logState.level = level
        else
            logState.level = AIOS.__debug_level or DEFAULT_LEVEL
        end
    else
        -- Fallback to environment variables
        logState.enabled = not not (AIOS.__debug_on or AIOS.__debug_mode)
        logState.level = AIOS.__debug_level or DEFAULT_LEVEL
    end
    
    -- Notify configuration change only if EventBus is available
    local eventBus = getEventBus()
    if eventBus and type(eventBus.Emit) == "function" then
        pcall(eventBus.Emit, eventBus, "LOGGER_CONFIG_CHANGED", logState.enabled, logState.level)
    end
end

-- ========= Advanced Sink Management =========
function Logger:AddSink(name, sinkConfig)
    if type(name) ~= "string" or type(sinkConfig) ~= "table" then
        return false, "Invalid sink configuration"
    end
    
    local sink = {
        name = name,
        formatter = sinkConfig.formatter or function(payload) return payload end,
        filter = sinkConfig.filter or function() return true end,
        writer = sinkConfig.writer or function() end,
        enabled = sinkConfig.enabled ~= false
    }
    
    logState.sinks[name] = sink
    return true
end

function Logger:RemoveSink(name)
    logState.sinks[name] = nil
    return true
end

function Logger:SetSinkEnabled(name, enabled)
    local sink = logState.sinks[name]
    if sink then
        sink.enabled = enabled
        return true
    end
    return false
end

function Logger:AddFilter(filterName, filterFn)
    if type(filterName) == "string" and type(filterFn) == "function" then
        logState.filters[filterName] = filterFn
        return true
    end
    return false
end

function Logger:RemoveFilter(filterName)
    logState.filters[filterName] = nil
    return true
end

-- ========= Ring Buffer Management =========
function Logger:SetRingSize(newSize)
    newSize = math.max(100, math.min(newSize or RING_MAX, 10000))
    
    if newSize < ringCount then
        -- Prune oldest entries
        local newBuffer = {}
        local newPosition = 0
        
        for i = math.max(1, ringCount - newSize + 1), ringCount do
            newPosition = (newPosition % newSize) + 1
            newBuffer[newPosition] = ringBuffer[(ringPosition - ringCount + i - 1) % RING_MAX + 1]
        end
        
        ringBuffer = newBuffer
        ringPosition = newPosition
        ringCount = math.min(ringCount, newSize)
    end
    
    RING_MAX = newSize
    return true
end

function Logger:ClearRing()
    ringBuffer = {}
    ringPosition = 0
    ringCount = 0
end

-- ========= Core Logging Engine =========
local function processLogEntry(payload)
    -- Apply filters
    for _, filterFn in pairs(logState.filters) do
        if type(filterFn) == "function" and not filterFn(payload) then
            return false
        end
    end
    
    -- Store in ring buffer
    ringPosition = (ringPosition % RING_MAX) + 1
    ringBuffer[ringPosition] = payload
    ringCount = math.min(ringCount + 1, RING_MAX)
    
    -- Send to sinks
    for _, sink in pairs(logState.sinks) do
        if sink.enabled and type(sink.filter) == "function" and sink.filter(payload) then
            local formatted = type(sink.formatter) == "function" and sink.formatter(payload) or payload
            if type(sink.writer) == "function" then
                getUtils().SafeCall(sink.writer, formatted)
            end
        end
    end
    
    return true
end

-- ========= FIXED: Core Logging Function =========
function AIOS.CoreLog(msg, level, tag, context)
    level = (type(level) == "string" and level:lower()) or "info"
    if not shouldLog(level) then return false end

    local payload = {
        ts = now_ms(),
        level = level,
        tag = tag or "Core",
        msg = tostring(msg),
        context = context or {}
    }

    return processLogEntry(payload)
end

-- ========= Advanced Logging API =========
function Logger:Log(level, tag, msg, context)
    -- FIXED: Call the direct CoreLog function instead of creating circular reference
    return AIOS.CoreLog(msg, level, tag, context)
end

function Logger:Trace(msg, tag, context)
    return self:Log("trace", tag, msg, context)
end

function Logger:Debug(msg, tag, context)
    return self:Log("debug", tag, msg, context)
end

function Logger:Info(msg, tag, context)
    return self:Log("info", tag, msg, context)
end

function Logger:Warn(msg, tag, context)
    return self:Log("warn", tag, msg, context)
end

function Logger:Error(msg, tag, context)
    return self:Log("error", tag, msg, context)
end

-- Contextual logging with correlation
function Logger:WithContext(context)
    return {
        trace = function(msg, tag) return Logger:Trace(msg, tag, context) end,
        debug = function(msg, tag) return Logger:Debug(msg, tag, context) end,
        info = function(msg, tag) return Logger:Info(msg, tag, context) end,
        warn = function(msg, tag) return Logger:Warn(msg, tag, context) end,
        error = function(msg, tag) return Logger:Error(msg, tag, context) end
    }
end

-- ========= Log Retrieval & Analysis =========
function Logger:GetEntries(filterOpts)
    filterOpts = filterOpts or {}
    local results = {}
    local count = 0
    local maxEntries = filterOpts.limit or ringCount
    
    for i = math.max(1, ringCount - maxEntries + 1), ringCount do
        local entry = ringBuffer[(ringPosition - ringCount + i - 1) % RING_MAX + 1]
        
        if entry and (not filterOpts.level or entry.level == filterOpts.level) and
           (not filterOpts.tag or entry.tag == filterOpts.tag) and
           (not filterOpts.since or entry.ts >= filterOpts.since) then
            count = count + 1
            results[count] = entry
        end
    end
    
    return results
end

function Logger:Export(filterOpts)
    local entries = self:GetEntries(filterOpts)
    local output = {}
    
    for i, entry in ipairs(entries) do
        output[i] = string.format("[%s] %s: %s", entry.level:upper(), entry.tag, entry.msg)
    end
    
    return table.concat(output, "\n")
end

-- ========= Built-in Sinks =========
-- Console sink (development only)
Logger:AddSink("console", {
    formatter = function(payload)
        return string.format("|cff66ccff[%s]|r |cff%s%s|r: %s",
            "HH:MM:SS", -- Simplified without date parsing
            Logger:GetLevelColor(payload.level),
            payload.tag,
            payload.msg)
    end,
    filter = function(payload)
        return payload.level ~= "trace" -- Don't spam console with traces
    end,
    writer = function(formatted)
        if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
            _G.DEFAULT_CHAT_FRAME:AddMessage(formatted)
        end
    end,
    enabled = false -- Off by default
})

-- EventBus sink (graceful)
Logger:AddSink("eventbus", {
    formatter = function(payload) return payload end,
    writer = function(payload)
        local eventBus = getEventBus()
        if eventBus and type(eventBus.Emit) == "function" then
            pcall(eventBus.Emit, eventBus, "AIOS_LOG", payload)
        end
    end,
    enabled = true
})

-- ========= Utility Methods =========
function Logger:GetLevelColor(level)
    local colors = {
        trace = "888888",
        debug = "00ff00", 
        info = "ffffff",
        warn = "ffff00",
        error = "ff0000"
    }
    return colors[level] or "ffffff"
end

function Logger:IsEnabled()
    return logState.enabled
end

function Logger:GetLevel()
    return logState.level
end

function Logger:SetLevel(newLevel)
    if LEVEL_ORDER[newLevel] then
        logState.level = newLevel
        return true
    end
    return false
end

function Logger:Enable()
    logState.enabled = true
    return true
end

function Logger:Disable()
    logState.enabled = false
    return true
end

-- ========= Initialization (Graceful) =========
local function initializeLogger()
    Logger:UpdateConfiguration()
    
    -- Watch for configuration changes if EventBus is available
    local eventBus = getEventBus()
    if eventBus and type(eventBus.Listen) == "function" then
        pcall(eventBus.Listen, eventBus, "CONFIG_CHANGED", function()
            Logger:UpdateConfiguration()
        end)
    end
    
    -- Register with DI system if available
    local utils = getUtils()
    if utils and type(utils.RegisterService) == "function" then
        pcall(utils.RegisterService, utils, "Logger", function() return Logger end)
    end
end

-- Initialize on load
initializeLogger()

return Logger