--[[
AIOS_EventBus.lua — Advanced Reactive Event System
Version: 1.0.0
Author: Poorkingz
Links:
  • CurseForge: https://www.curseforge.com/members/aios/projects
  • Website:    https://aioswow.info/
  • Discord:    https://discord.gg/JMBgHA5T
  • Support:    support@aioswow.dev

API Functions:
  AIOS.EventBus.Observe(eventName [, predicate]) : subscription
  AIOS.EventBus.CreateStream(eventName) : stream
  AIOS.EventBus.WaitFor(eventName [, timeoutMs, predicate]) : promise
  AIOS.EventBus.Debounce(eventName, delayMs [, transformFn]) : function
  AIOS.EventBus.Throttle(eventName, intervalMs [, transformFn]) : function
  AIOS.EventBus.Register(eventName, fn [, opts]) : handle
  AIOS.EventBus.Listen(name, fn [, opts]) : handle
  AIOS.EventBus.Once(name, fn [, opts]) : handle
  AIOS.EventBus.Emit(name, ...)
  AIOS.EventBus.Unregister(handle)
  AIOS.EventBus.RegisterMany(events, fn [, opts]) : handles[]
  AIOS.EventBus.HasListeners(eventName) : bool
]]

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

-- ========= Advanced Pattern: Event Streams =========
function EB:Observe(eventName, predicate)
    return {
        event = eventName,
        predicate = predicate,
        subscribe = function(callback)
            return self:Listen(eventName, function(...)
                if not predicate or predicate(...) then
                    callback(...)
                end
            end)
        end
    }
end

function EB:CreateStream(eventName)
    local stream = {
        subscribers = {},
        emit = function(...)
            for _, callback in ipairs(stream.subscribers) do
                getUtils().SafeCall(callback, ...)
            end
        end
    }
    
    EB._streams[eventName] = stream
    return stream
end

-- ========= Promise-Based Event Waiting =========
function EB:WaitFor(eventName, timeoutMs, predicate)
    local utils = getUtils()
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
                timerHandle = timers:After(timeoutMs / 1000, function()
                    cleanup()
                    reject("Event timeout: " .. eventName)
                end)
            end
        end
        
        -- Event listener
        eventHandle = self:Listen(eventName, function(...)
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
    
    return function(...)
        lastArgs = {...}
        if not pending then
            pending = true
            local timers = getTimers()
            if timers and timers.After then
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

-- ========= Advanced Emission =========
function EB:Emit(name, ...)
    local args = {...}
    
    -- Check streams first
    local stream = EB._streams[name]
    if stream then
        stream.emit(unpack(args))
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
                    local ok, shouldProceed = utils.SafeCall(rec.predicate, name, unpack(args))
                    if not ok or not shouldProceed then return end
                end
                
                utils.SafeCall(rec.fn, name, unpack(args))
                if rec.once then rec.dead = true end
            end
            
            if rec.inCombatDefer and inCombat then
                if timers and timers.After then
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
                
                utils.SafeCall(rec.fn, event, unpack(args))
                if rec.once then rec.dead = true end
            end
            
            if rec.inCombatDefer and inCombat then
                if timers and timers.After then
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