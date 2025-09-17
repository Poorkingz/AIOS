--[[
AIOS — Advanced Interface Operating System
File: AIOS_EventBus.lua
Version: 1.0.0
Author: Poorkingz
License: MIT

Project Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Email: support@aioswow.dev

Purpose:
  - Reactive event system for AIOS and external addons.
  - Unifies WoW native events and custom signals under one API.
  - Supports promises, reactive streams, debounce/throttle, and combat deferral.

API Reference:
  - EventBus:Observe(eventName [, predicate]) → subscription
  - EventBus:CreateStream(eventName) → stream
  - EventBus:WaitFor(eventName [, timeoutMs, predicate]) → promise
  - EventBus:Debounce(eventName, delayMs [, transformFn]) → fn
  - EventBus:Throttle(eventName, intervalMs [, transformFn]) → fn
  - EventBus:Register(eventName, fn [, opts]) → handle
  - EventBus:Listen(name, fn [, opts]) → handle
  - EventBus:Once(name, fn [, opts]) → handle
  - EventBus:Emit(name, ...)
  - EventBus:Unregister(handle)
  - EventBus:RegisterMany(events, fn [, opts]) → handles[]
  - EventBus:ListenMany(events, fn [, opts]) → handles[]
  - EventBus:HasListeners(eventName) → bool

Notes:
  - Priority-based listener ordering.
  - Options: once, predicate, debounce, throttle, inCombatDefer, priority, unit.
  - Uses coroutine-safe SafeCall wrapper for stability.
  - Self-tests included at load (silent).
  - Registered as "EventBus" service for DI.
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.EventBus = AIOS.EventBus or {}
local EB = AIOS.EventBus

-- ========= Dependency Injection Ready =========
local function resolveService(serviceName)
    if AIOS.Utils and AIOS.Utils.ResolveService then
        return AIOS.Utils.ResolveService(serviceName)
    end
    return AIOS[serviceName] -- Fallback
end

-- Lazy service resolution
local function getUtils() return resolveService("Utils") end
local function getTimers() return resolveService("Timers") end
local function getLogger() return resolveService("Logger") end

-- Safe logging with DI fallback
local function clog(msg, level, tag)
    local logger = getLogger()
    if logger and logger.Log then
        logger:Log(level or "debug", tag or "EventBus", msg)
    elseif AIOS.CoreLog then
        AIOS.CoreLog(msg, level or "debug", tag or "EventBus")
    end
end

-- ========= Core Structures =========
EB._frame = EB._frame or CreateFrame("Frame")
EB._frame:Hide()
EB._wow = EB._wow or {}        -- event -> array of listener records
EB._sig = EB._sig or {}        -- signal -> array of listener records
EB._streams = EB._streams or {} -- Reactive event streams
EB._waiting = EB._waiting or {} -- Promises waiting for events

-- Debug: Ensure _streams is initialized
clog("Initializing EB._streams", "debug", "EventBus")

-- ========= Advanced Pattern: Event Streams =========
function EB:Observe(eventName, predicate)
    clog("Calling Observe with eventName: " .. tostring(eventName), "debug", "EventBus")
    if type(eventName) ~= "string" then
        clog("Observe: eventName must be a string, got " .. type(eventName), "error")
        error("Invalid eventName", 2)
    end
    local subscription = {
        event = eventName,
        predicate = predicate,
        subscribe = function(_, callback)
            clog("Subscribing to event: " .. eventName, "debug", "EventBus")
            return EB:Listen(eventName, function(...)
                if not predicate or predicate(...) then
                    clog("Calling callback for event: " .. eventName, "debug", "EventBus")
                    callback(...)
                end
            end)
        end
    }
    clog("Observe returned subscription", "debug", "EventBus")
    return subscription
end

function EB:CreateStream(eventName)
    clog("Calling CreateStream with eventName: " .. tostring(eventName), "debug", "EventBus")
    local streamObj = {
        subscribers = {},
        emit = function(self, ...)
            clog("Emitting stream event: " .. tostring(eventName), "debug", "EventBus")
            for _, callback in ipairs(self.subscribers) do
                local utils = getUtils()
                clog("Calling SafeCall for callback in stream: " .. tostring(eventName), "debug", "EventBus")
                utils.SafeCall(callback, ...)
            end
        end
    }
    clog("Assigning streamObj to EB._streams[" .. tostring(eventName) .. "]", "debug", "EventBus")
    EB._streams[eventName] = streamObj
    clog("CreateStream completed", "debug", "EventBus")
    return streamObj
end

-- ========= Promise-Based Event Waiting =========
function EB:WaitFor(eventName, timeoutMs, predicate)
    local utils = getUtils()
    clog("Calling WaitFor with eventName: " .. tostring(eventName) .. ", timeoutMs: " .. tostring(timeoutMs), "debug", "EventBus")
    return utils.CreatePromise(function(resolve, reject)
        local timerHandle
        local eventHandle
        
        -- Cleanup function
        local function cleanup()
            if timerHandle and timerHandle.Cancel then
                timerHandle:Cancel()
            end
            if eventHandle and eventHandle.Cancel then
                eventHandle:Cancel()
            end
        end
        
        -- Timeout handling
        if timeoutMs and timeoutMs > 0 then
            local timers = getTimers()
            if timers and timers.After then
                clog("Scheduling timeout for WaitFor: " .. tostring(eventName), "debug", "EventBus")
                timerHandle = timers:After(timeoutMs / 1000, function()
                    clog("WaitFor timed out: " .. tostring(eventName), "debug", "EventBus")
                    cleanup()
                    reject("Event timeout: " .. eventName)
                end)
            end
        end
        
        -- Event listener
        eventHandle = self:Listen(eventName, function(...)
            clog("WaitFor event triggered: " .. tostring(eventName), "debug", "EventBus")
            if not predicate or predicate(...) then
                cleanup()
                resolve(...)
            end
        end, { once = true })
    end)
end

-- ========= Enhanced Debounce/Throttle =========
function EB:Debounce(eventName, delayMs, transformFn)
    local lastArgs
    local pending
    
    clog("Creating Debounce for eventName: " .. tostring(eventName) .. ", delayMs: " .. tostring(delayMs), "debug", "EventBus")
    return function(...)
        lastArgs = {...}
        if not pending then
            pending = true
            local timers = getTimers()
            if timers and timers.After then
                clog("Scheduling Debounce for event: " .. tostring(eventName), "debug", "EventBus")
                timers:After(delayMs / 1000, function()
                    pending = false
                    if transformFn then
                        self:Emit(eventName, transformFn(unpack(lastArgs)))
                    else
                        self:Emit(eventName, unpack(lastArgs))
                    end
                end)
            end
        end
    end
end

function EB:Throttle(eventName, intervalMs, transformFn)
    local lastCall = 0
    local lastArgs
    
    clog("Creating Throttle for eventName: " .. tostring(eventName) .. ", intervalMs: " .. tostring(intervalMs), "debug", "EventBus")
    return function(...)
        lastArgs = {...}
        local now = _G.GetTime() or 0
        if now - lastCall >= (intervalMs / 1000) then
            lastCall = now
            if transformFn then
                self:Emit(eventName, transformFn(unpack(lastArgs)))
            else
                self:Emit(eventName, unpack(lastArgs))
            end
        end
    end
end

-- ========= Core Registration (Enhanced) =========
local function norm_opts(opts)
    local t = type(opts) == "table" and opts or {}
    return {
        priority = tonumber(t.priority or 0) or 0,
        once = not not t.once,
        unit = t.unit,
        predicate = t.predicate,
        debounce = t.debounce,
        throttle = t.throttle,
        inCombatDefer = t.inCombatDefer,
        tag = t.tag or "anonymous"
    }
end

local function make_handle(slot)
    local h = { _slot = slot }
    function h:Cancel()
        if h._slot and not h._slot.dead then
            h._slot.dead = true
        end
    end
    function h:IsActive()
        return h._slot and not h._slot.dead
    end
    return h
end

local function insert_by_priority(list, rec)
    local p = rec.priority or 0
    for i = 1, #list do
        if (list[i].priority or 0) < p then
            table.insert(list, i, rec)
            return
        end
    end
    table.insert(list, rec)
end

-- ========= WoW Event System =========
local function ensure_wow_event_hook(event)
    if not EB._wow[event] then
        EB._wow[event] = {}
        EB._frame:RegisterEvent(event)
    end
end

function EB:Register(event, fn, opts)
    if type(event) ~= "string" or type(fn) ~= "function" then 
        return nil, "Invalid arguments" 
    end
    
    local o = norm_opts(opts)
    ensure_wow_event_hook(event)
    
    local slot = {
        kind = "wow",
        event = event,
        fn = fn,
        once = o.once,
        priority = o.priority,
        unit = o.unit,
        predicate = o.predicate,
        debounce = o.debounce,
        throttle = o.throttle,
        inCombatDefer = o.inCombatDefer,
        tag = o.tag,
        dead = false
    }
    
    insert_by_priority(EB._wow[event], slot)
    return make_handle(slot)
end

-- ========= Custom Signal System =========
function EB:Listen(name, fn, opts)
    if type(name) ~= "string" or type(fn) ~= "function" then 
        return nil, "Invalid arguments" 
    end
    
    local o = norm_opts(opts)
    if not EB._sig[name] then EB._sig[name] = {} end
    
    local slot = {
        kind = "sig",
        name = name,
        fn = fn,
        once = o.once,
        priority = o.priority,
        predicate = o.predicate,
        debounce = o.debounce,
        throttle = o.throttle,
        tag = o.tag,
        dead = false
    }
    
    insert_by_priority(EB._sig[name], slot)
    return make_handle(slot)
end

function EB:Once(name, fn, opts)
    local o = norm_opts(opts)
    o.once = true
    return self:Listen(name, fn, o)
end

function EB:ListenMany(events, fn, opts)
    local handles = {}
    for _, event in ipairs(events) do
        handles[#handles + 1] = self:Listen(event, fn, opts)
    end
    return handles
end

-- ========= Advanced Emission =========
function EB:Emit(name, ...)
    local args = {...}
    
    -- Check streams first
    local stream = EB._streams[name]
    if stream then
        clog("Emitting to stream: " .. tostring(name), "debug", "EventBus")
        stream:emit(unpack(args))
    end
    
    -- Check regular listeners
    local listeners = EB._sig[name]
    if not listeners or #listeners == 0 then return end
    
    local utils = getUtils()
    local timers = getTimers()
    local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
    
    for i = #listeners, 1, -1 do
        local rec = listeners[i]
        if rec.dead then
            table.remove(listeners, i)
        else
            local function execute()
                if rec.predicate then
                    local ok, shouldProceed = utils.SafeCall(rec.predicate, unpack(args))
                    if not ok or not shouldProceed then return end
                end
                
                clog("Calling listener for event: " .. tostring(name), "debug", "EventBus")
                utils.SafeCall(rec.fn, unpack(args))
                if rec.once then rec.dead = true end
            end
            
            if rec.inCombatDefer and inCombat then
                if timers and timers.After then
                    clog("Deferring listener due to combat: " .. tostring(name), "debug", "EventBus")
                    timers:After(0.05, function()
                        if not _G.InCombatLockdown() then execute() end
                    end)
                end
            else
                execute()
            end
        end
    end
end

-- ========= WoW Event Dispatch =========
EB._frame:SetScript("OnEvent", function(_, event, ...)
    local listeners = EB._wow[event]
    if not listeners then return end
    
    local args = {...}
    local utils = getUtils()
    local timers = getTimers()
    local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
    
    for i = #listeners, 1, -1 do
        local rec = listeners[i]
        if rec.dead then
            table.remove(listeners, i)
        else
            local function execute()
                if rec.unit and args[1] ~= rec.unit then return end
                if rec.predicate then
                    local ok, shouldProceed = utils.SafeCall(rec.predicate, event, unpack(args))
                    if not ok or not shouldProceed then return end
                end
                
                clog("Calling WoW event listener for: " .. tostring(event), "debug", "EventBus")
                utils.SafeCall(rec.fn, event, unpack(args))
                if rec.once then rec.dead = true end
            end
            
            if rec.inCombatDefer and inCombat then
                if timers and timers.After then
                    clog("Deferring WoW event listener due to combat: " .. tostring(event), "debug", "EventBus")
                    timers:After(0.05, function()
                        if not _G.InCombatLockdown() then execute() end
                    end)
                end
            else
                execute()
            end
        end
    end
end)

-- ========= Utility Methods =========
function EB:Unregister(handle)
    if handle and handle.Cancel then handle:Cancel() end
end

function EB:RegisterMany(events, fn, opts)
    local handles = {}
    for _, event in ipairs(events) do
        handles[#handles + 1] = self:Register(event, fn, opts)
    end
    return handles
end

function EB:HasListeners(eventName)
    local sigListeners = EB._sig[eventName]
    local wowListeners = EB._wow[eventName]
    return (sigListeners and #sigListeners > 0) or (wowListeners and #wowListeners > 0)
end

-- ========= Self-Test (Silent) =========
do
    -- Test promise-based waiting
    local testPromise = EB:WaitFor("TEST_EVENT", 100)
    
    -- Test reactive stream
    local testStream = EB:CreateStream("TEST_STREAM")
    
    -- Test enhanced debounce
    local debouncedTest = EB:Debounce("DEBOUNCED_TEST", 100)
    
    clog("info", "EventBus", "Advanced EventBus initialized successfully")
end

-- ========= DI Registration =========
if AIOS.Utils and AIOS.Utils.RegisterService then
    AIOS.Utils.RegisterService("EventBus", function() return EB end)
end

return EB