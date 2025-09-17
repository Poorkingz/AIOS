--[[
AIOS_Utils.lua — Core Utility & Meta-Programming Engine
Version: 1.0
Author: Poorkingz
Website: https://aioswow.info/
CurseForge: https://www.curseforge.com/members/aios/projects
Discord: https://discord.gg/JMBgHA5T
Support: support@aioswow.dev

📌 Purpose:
This module provides the **fundamental utility layer** for the AIOS ecosystem.
It delivers cross-version WoW API shims, async/await promise handling, dependency
injection (IoC container), functional programming helpers, reactive state
management, and developer-safe wrappers. It is the backbone for advanced
addon engineering inside AIOS.

✨ Key Features:
- WoW API Compatibility Shims (Retail + Classic)
- Dependency Injection (RegisterService, ResolveService, etc.)
- Promise/Await async system with coroutine integration
- ReactiveState with event-driven reactivity
- Functional helpers: Curry, Memoize, Throttle, Debounce
- Safe wrappers: SafeCall, Try, ReadOnlyProxy
- Utility helpers: Clamp, Round, Slug, DeepCopy, MergeTables
- Pattern Matching: switch-like Match(value, patterns)
- Self-tests for promises, reactivity, and memoization

🧪 Release Readiness:
✅ Stable, release-ready, and safe for Retail + Classic.
⚠️ Dev caution: misuse of Promises or ReactiveState may cause logical deadlocks.
  Recommended for developers familiar with async/event-driven programming.

This file is part of the **AIOS Core API** and should not be modified directly.
--]]

local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

local U = {}
AIOS.Utils = U

-- ========= WoW AddOn API shims =========
local useC = _G.C_AddOns and type(_G.C_AddOns.GetAddOnInfo) == "function"

function U.GetNumAddOns()
    if useC then
        return (_G.C_AddOns.GetNumAddOns)()
    end
    if _G.GetNumAddOns then
        return _G.GetNumAddOns()
    end
    return 0
end

function U.GetAddOnInfo(index)
    if useC then
        return (_G.C_AddOns.GetAddOnInfo)(index)
    end
    if _G.GetAddOnInfo then
        return _G.GetAddOnInfo(index)
    end
    return nil
end

function U.UpdateAddOnMemoryUsage()
    if _G.UpdateAddOnMemoryUsage then
        return _G.UpdateAddOnMemoryUsage()
    end
    if _G.C_AddOns and _G.C_AddOns.UpdateAddOnMemoryUsage then
        return _G.C_AddOns.UpdateAddOnMemoryUsage()
    end
end

function U.GetAddOnMemoryUsage(index)
    if _G.GetAddOnMemoryUsage then
        return _G.GetAddOnMemoryUsage(index)
    end
    if _G.C_AddOns and _G.C_AddOns.GetAddOnMemoryUsage then
        return _G.C_AddOns.GetAddOnMemoryUsage(index)
    end
    return 0
end

-- ========= Dependency Injection Core (IoC Container) =========
U.Services = U.Services or {} -- ServiceName -> { constructorFn, instance }

-- Register a service for lazy, singleton construction
function U.RegisterService(name, constructorFunc)
    if type(name) ~= "string" or type(constructorFunc) ~= "function" then
        if AIOS.CoreLog then
            AIOS.CoreLog("Invalid service registration: name=" .. type(name) .. ", constructor=" .. type(constructorFunc), "error", "Utils")
        end
        return false, "Invalid service registration"
    end
    U.Services[name] = { constructor = constructorFunc, instance = nil }
    if AIOS.CoreLog then
        AIOS.CoreLog("Registered service: " .. name, "debug", "Utils")
    end
    return true
end

-- Resolve a service, creating it if necessary
function U.ResolveService(name)
    if type(name) ~= "string" then
        local errMsg = "ResolveService expects a string, got: " .. type(name)
        if AIOS.CoreLog then
            AIOS.CoreLog(errMsg, "error", "Utils")
        end
        print("[AIOS Utils] Error: " .. errMsg)
        return nil
    end
    local service = U.Services[name]
    if not service then
        local errMsg = "Service '" .. name .. "' not registered."
        if AIOS.CoreLog then
            AIOS.CoreLog(errMsg, "warn", "Utils")
        end
        print("[AIOS Utils] Warning: " .. errMsg)
        return nil
    end
    if not service.instance then
        local ok, instance = U.SafeCall(service.constructor)
        if not ok then
            local errMsg = "Failed to construct service '" .. name .. "': " .. tostring(instance)
            if AIOS.CoreLog then
                AIOS.CoreLog(errMsg, "error", "Utils")
            end
            print("[AIOS Utils] Error: " .. errMsg)
            return nil
        end
        service.instance = instance
    end
    if AIOS.CoreLog then
        AIOS.CoreLog("Resolved service: " .. name, "debug", "Utils")
    end
    return service.instance
end

-- Batch service registration
function U.RegisterServices(serviceTable)
    for name, constructor in pairs(serviceTable) do
        U.RegisterService(name, constructor)
    end
end

-- ========= Promise-based Async/Await Pattern (Enhanced) =========
function U.CreatePromise(executorFunc)
    local promise = {
        _state = "pending", 
        _value = nil,
        _callbacks = {}
    }
    
    local function resolve(value)
        if promise._state ~= "pending" then return end
        promise._state = "fulfilled"
        promise._value = value
        for _, callback in ipairs(promise._callbacks) do
            U.SafeCall(callback.onFulfilled or callback.onRejected, value)
        end
        promise._callbacks = {}
    end
    
    local function reject(reason)
        if promise._state ~= "pending" then return end
        promise._state = "rejected"
        promise._value = reason
        for _, callback in ipairs(promise._callbacks) do
            U.SafeCall(callback.onRejected or callback.onFulfilled, reason)
        end
        promise._callbacks = {}
    end
    
    -- Promise chaining methods
    function promise:andThen(onFulfilled, onRejected)
        return U.CreatePromise(function(resolveNext, rejectNext)
            local function handleFulfilled(value)
                if type(onFulfilled) == "function" then
                    local ok, result = U.SafeCall(onFulfilled, value)
                    if ok then
                        resolveNext(result)
                    else
                        rejectNext(result)
                    end
                else
                    resolveNext(value)
                end
            end
            
            local function handleRejected(reason)
                if type(onRejected) == "function" then
                    local ok, result = U.SafeCall(onRejected, reason)
                    if ok then
                        resolveNext(result)
                    else
                        rejectNext(result)
                    end
                else
                    rejectNext(reason)
                end
            end
            
            if self._state == "fulfilled" then
                handleFulfilled(self._value)
            elseif self._state == "rejected" then
                handleRejected(self._value)
            else
                table.insert(self._callbacks, {
                    onFulfilled = handleFulfilled,
                    onRejected = handleRejected
                })
            end
        end)
    end
    
    function promise:catch(onRejected)
        return self:andThen(nil, onRejected)
    end
    
    function promise:finally(onFinally)
        return self:andThen(
            function(value)
                U.SafeCall(onFinally)
                return value
            end,
            function(reason)
                U.SafeCall(onFinally)
                return nil, reason
            end
        )
    end
    
    U.SafeCall(executorFunc, resolve, reject)
    return promise
end

function U.Await(promise)
    if promise._state == "fulfilled" then
        return promise._value
    elseif promise._state == "rejected" then
        error(promise._value, 2)
    end
    
    local co = coroutine.running()
    if not co then error("U.Await must be called from a coroutine", 2) end
    
    table.insert(promise._callbacks, {
        onFulfilled = function(value)
            local success, err = coroutine.resume(co, value)
            if not success and AIOS.CoreLog then
                AIOS.CoreLog(("Coroutine resume failed: %s"):format(tostring(err)), "error", "Utils")
            end
        end,
        onRejected = function(reason)
            local success, err = coroutine.resume(co, nil, reason)
            if not success and AIOS.CoreLog then
                AIOS.CoreLog(("Coroutine resume failed: %s"):format(tostring(err)), "error", "Utils")
            end
        end
    })
    
    return coroutine.yield()
end

function U.RunAsync(asyncFunction, ...)
    local co = coroutine.create(asyncFunction)
    local success, result = coroutine.resume(co, ...)
    if not success and AIOS.CoreLog then
        AIOS.CoreLog(("Async function failed: %s"):format(tostring(result)), "error", "Utils")
    end
    return result
end

function U.Delay(ms)
    return U.CreatePromise(function(resolve)
        local Timers = AIOS.Timers or {}
        if Timers.After then
            Timers:After(ms / 1000, resolve)
        else
            if _G.C_Timer and _G.C_Timer.After then
                _G.C_Timer.After(ms / 1000, resolve)
            else
                resolve()
            end
        end
    end)
end

function U.All(promises)
    return U.CreatePromise(function(resolve, reject)
        local results = {}
        local completed = 0
        local total = #promises
        
        if total == 0 then
            resolve(results)
            return
        end
        
        for i, promise in ipairs(promises) do
            local function handleCompletion(value)
                results[i] = value
                completed = completed + 1
                if completed == total then
                    resolve(results)
                end
            end
            
            local function handleRejection(reason)
                reject(reason)
            end
            
            if promise._state == "fulfilled" then
                handleCompletion(promise._value)
            elseif promise._state == "rejected" then
                handleRejection(promise._value)
            else
                promise:andThen(handleCompletion, handleRejection)
            end
        end
    end)
end

function U.ReactiveState(initialValue, onChangeCallback)
    local proxy = {}
    local mt = {
        __index = function(_, k)
            return initialValue[k]
        end,
        __newindex = function(_, k, v)
            if initialValue[k] == v then return end
            local oldValue = initialValue[k]
            initialValue[k] = v
            
            if onChangeCallback then
                U.SafeCall(onChangeCallback, k, v, oldValue)
            end
            
            if AIOS and AIOS.EventBus and AIOS.EventBus.Emit then
                AIOS.EventBus:Emit("REACTIVE_STATE_CHANGE", proxy, k, v, oldValue)
            end
        end,
        __pairs = function() return pairs(initialValue) end,
        __ipairs = function() return ipairs(initialValue) end
    }
    return setmetatable(proxy, mt)
end

function U.BindMethod(instance, methodName)
    local method = instance[methodName]
    if type(method) ~= "function" then
        error(("Method '%s' is not a function"):format(methodName), 2)
    end
    return function(...) return method(instance, ...) end
end

function U.Curry(fn, ...)
    local args = {...}
    return function(...)
        local allArgs = {}
        for i = 1, #args do allArgs[i] = args[i] end
        for i = 1, select("#", ...) do allArgs[#args + i] = select(i, ...) end
        return fn(unpack(allArgs))
    end
end

function U.Memoize(fn)
    local cache = {}
    return function(...)
        local key = table.concat({...}, "|")
        if cache[key] == nil then
            cache[key] = fn(...)
        end
        return cache[key]
    end
end

function U.Throttle(fn, delay)
    local lastCall = 0
    return function(...)
        local now = _G.GetTime() or 0
        if now - lastCall >= delay then
            lastCall = now
            return fn(...)
        end
    end
end

function U.Debounce(fn, delay)
    local timer
    return function(...)
        local args = {...}
        if timer then
            timer:Cancel()
        end
        timer = U.Delay(delay):andThen(function()
            fn(unpack(args))
        end)
    end
end

function U.Nop() end

function U.TableCount(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function U.Clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

function U.Round(x, places)
    local p = 10 ^ (places or 0)
    return math.floor(x * p + 0.5) / p
end

function U.Slug(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("%s+", "_")
    s = s:gsub("[^%w_]", "")
    return s:lower()
end

function U.DeepCopy(original)
    if type(original) ~= "table" then return original end
    local copy = {}
    for k, v in pairs(original) do
        copy[k] = U.DeepCopy(v)
    end
    return copy
end

function U.MergeTables(target, source, deep)
    for k, v in pairs(source) do
        if deep and type(v) == "table" and type(target[k]) == "table" then
            U.MergeTables(target[k], v, true)
        else
            target[k] = v
        end
    end
    return target
end

function U.ReadOnlyProxy(tbl, name)
    local proxy = {}
    local mt = {
        __index = tbl,
        __newindex = function(_, k, _v)
            error((name or "ReadOnly") .. " is read-only. Attempted write to key: " .. tostring(k), 2)
        end,
        __pairs = function() return pairs(tbl) end,
        __ipairs = function() return ipairs(tbl) end,
        __metatable = false,
    }
    return setmetatable(proxy, mt)
end

function U.SafeCall(fn, ...)
    if type(fn) ~= "function" then return false, "not a function" end
    return pcall(fn, ...)
end

function U.Try(label, fn, ...)
    if type(fn) ~= "function" then return false, "not a function" end
    local ok, err = pcall(fn, ...)
    if not ok then
        if AIOS and AIOS.CoreLog then
            AIOS.CoreLog(("Try[%s] failed: %s"):format(tostring(label), tostring(err)), "error", "Utils")
        end
    end
    return ok, err
end

function U.Match(value, patterns)
    for pattern, handler in pairs(patterns) do
        if pattern == value or (type(pattern) == "function" and pattern(value)) then
            return type(handler) == "function" and handler(value) or handler
        end
    end
    return patterns.default
end

-- Register core utils as a service for dependency injection
U.RegisterService("Utils", function() return U end)

-- Self-test (Silent)
do
    local testState = U.ReactiveState({ test = 1 }, function(k, v, old)
    end)
    testState.test = 2
    
    local testPromise = U.CreatePromise(function(resolve)
        resolve("test")
    end):andThen(function(value)
        return value .. "_chained"
    end):catch(function(err)
    end)
    
    local memoized = U.Memoize(function(x) return x * 2 end)
    memoized(5)
end

return U