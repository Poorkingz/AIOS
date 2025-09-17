--[[
AIOS — Advanced Interface Operating System
File: AIOS_Core.lua
Version: 1.0.0
Author: Poorkingz
License: MIT

Project Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Email: support@aioswow.dev

Purpose:
  - The quantum kernel of AIOS — no external dependencies.
  - Unified replacement for legacy frameworks (Ace3, LibStub).
  - Provides: Events, Signals, Plugins, Dependency Injection, Diagnostics.
  - Optimized for WoW Retail 11.2, Classic Era, and Mists Classic.

API Reference:
  - AIOS:RegisterEvent(event, fn, priority) → handle
  - AIOS:UnregisterEvent(event)
  - AIOS.SignalHub:Listen(signal, handler, opts) → handle
  - AIOS.SignalHub:Emit(signal, ...)
  - AIOS:Provide(serviceName, providerFn)
  - AIOS:Inject(serviceName) → service
  - AIOS:RegisterPlugin(id, plugin, dependencies)
  - AIOS:EnablePlugin(id)
  - AIOS:DisablePlugin(id)
  - AIOS:GetDiagnostics() → table
  - AIOS:SetPerformanceTracking(enabled)
  - AIOS:ThrottleFn(fn, interval, id) → throttledFn
  - AIOS:DebounceFn(fn, delay, id) → debouncedFn

Notes:
- Bootstraps automatically on PLAYER_LOGIN.
- Includes smoke tests and slash commands (/aioscore, /aiosmodules, /aiostest).
- All modules register via AIOS Core to ensure consistency.
- Logs and diagnostics are throttled for performance.
--]]


local _G = _G
local assert, type, pcall, tonumber, tostring = _G.assert, _G.type, _G.pcall, _G.tonumber, _G.tostring
local math_max, math_min, table_sort, table_remove, string_format = _G.math.max, _G.math.min, _G.table.sort, _G.table.remove, _G.string.format
local GetTime, UnitName, GetRealmName, CreateFrame = _G.GetTime, _G.UnitName, _G.GetRealmName, _G.CreateFrame

-- Global namespace
AIOS = _G.AIOS or {}
AIOS.__core_v = math_max(AIOS.__core_v or 0, 10020) -- 1.0.0-alpha

-- ==========================================================================
-- Quantum Logger™
-- ==========================================================================
AIOS._quietBoot = (AIOS._quietBoot ~= false)
AIOS._logLevel = AIOS._logLevel or 3
local LEVEL = { error=1, warn=2, info=3, debug=4, trace=5 }

local function _lvl(x)
  if type(x) == "number" then return math_min(5, math_max(1, x)) end
  if type(x) == "string" then return LEVEL[x:lower()] or 3 end
  return 3
end

function AIOS:SetLogLevel(nameOrNum)
  self._logLevel = _lvl(nameOrNum)
  self:CoreLog("Log level set to " .. self._logLevel, "debug")
end

function AIOS:GetLogLevel()
  return self._logLevel
end

function AIOS:SetQuietBoot(flag)
  self._quietBoot = not not flag
  self:CoreLog("Quiet boot " .. (self._quietBoot and "enabled" or "disabled"), "debug")
end

function AIOS:CoreLog(msg, level, tag)
  level = _lvl(level or "info")
  if level > (self._logLevel or 3) then return end
  local Debug = self.Debug
  if Debug and Debug.Log then
    Debug:Log(level, tag or "Core", tostring(msg))
  end
end

function AIOS:_Scope(tag)
  local Debug = self.Debug
  if Debug and Debug.Scope then return Debug:Scope(tag) end
  return setmetatable({}, { __index = function() return function() end end })
end

local Log = AIOS:_Scope("Core")



-- ==========================================================================
-- Neural Signal Network™
-- ==========================================================================
AIOS.SignalHub = AIOS.SignalHub or {}
local Hub = AIOS.SignalHub
Hub._reg = Hub._reg or {}

local _sid = 0
local function _sigid()
  _sid = _sid + 1
  if _sid > 2^52 then _sid = 1 end
  return _sid
end

function Hub:Listen(signal, handler, opts)
  if type(signal) ~= "string" or type(handler) ~= "function" then
    AIOS:CoreLog("Invalid signal registration parameters", "error")
    return nil
  end
  opts = opts or {}
  local pri = tonumber(opts.priority) or 0
  local rec = { fn = handler, once = not not opts.once, pri = pri, filter = opts.filter, id = _sigid() }
  local arr = self._reg[signal]
  if not arr then
    arr = {}
    self._reg[signal] = arr
  end
  arr[#arr + 1] = rec
  table_sort(arr, function(a, b) return a.pri > b.pri end)
  Log.debug("Listener added for signal: %s (priority: %d)", signal, pri)
  function rec:Cancel()
    local A = Hub._reg[signal]
    if not A then return end
    for i = #A, 1, -1 do
      if A[i] == self then
        table_remove(A, i)
        break
      end
    end
    if #A == 0 then Hub._reg[signal] = nil end
  end
  return rec
end

function Hub:Clear(signal)
  self._reg[signal] = nil
end

function Hub:Emit(signal, ...)
  Log.debug("Emitting signal: %s", signal)
  local arr = self._reg[signal]
  if not arr then return end
  local args = { ... }
  local nArgs = select("#", ...)
  local survivors = {}  -- ADD THIS LINE - FIXES THE BUG
  for i = 1, #arr do
    local h = arr[i]
    local allowed = true
    if h.filter and type(h.filter) == "function" then
      local ok, pass = pcall(h.filter, unpack(args, 1, nArgs))
      if ok then allowed = not not pass
      else AIOS:CoreLog("[SignalHub] filter error: " .. tostring(pass), "error")
      end
    end
    if allowed then
      local ok, err = pcall(h.fn, unpack(args, 1, nArgs))
      if not ok then
        AIOS:CoreLog("[SignalHub] handler error: " .. tostring(err), "error")
      end
    end
    if not h.once then survivors[#survivors + 1] = h end
  end
  self._reg[signal] = (#survivors > 0) and survivors or nil
end


function Hub:DebouncedEmit(signal, delay, ...)
  if not AIOS.Timers then
    AIOS:CoreLog("DebouncedEmit requires AIOS.Timers", "error")
    return
  end
  self._debounceTimers = self._debounceTimers or {}
  local timer = self._debounceTimers[signal]
  if timer then timer:Cancel() end
  local args = { ... }
  self._debounceTimers[signal] = AIOS.Timers:After(delay or 0.2, function()
    self._debounceTimers[signal] = nil
    self:Emit(signal, unpack(args))
  end)
end

function Hub:ThrottledEmit(signal, interval, ...)
  if not AIOS.Timers then
    AIOS:CoreLog("ThrottledEmit requires AIOS.Timers", "error")
    return
  end
  self._throttleTimers = self._throttleTimers or {}
  local lastEmit = self._throttleTimers[signal]
  local now = GetTime()
  if not lastEmit or (now - lastEmit) >= interval then
    self._throttleTimers[signal] = now
    self:Emit(signal, ...)
  end
end

-- ==========================================================================
-- Quantum Event System™
-- ==========================================================================
AIOS.Events = AIOS.Events or CreateFrame("Frame")
AIOS.Events._handlers = AIOS.Events._handlers or {}

local _nextH = 0
local function _hid()
  _nextH = _nextH + 1
  if _nextH > 2^52 then _nextH = 1 end
  return _nextH
end

AIOS.Events:SetScript("OnEvent", function(_, event, ...)
  local list = AIOS.Events._handlers[event]
  if not list or #list == 0 then return end
  local args = AIOS._eventArgs or {}
  AIOS._eventArgs = nil
  for i = 1, select("#", ...) do args[i] = select(i, ...) end
  for i = 1, #list do
    local h = list[i]
    if h and h.fn then
      local ok, err = pcall(h.fn, unpack(args))
      if not ok then
        AIOS:CoreLog(string_format("[Events] %s handler %d error: %s", event, h.id, tostring(err)), "error")
      end
    end
  end
  AIOS._eventArgs = args
end)

function AIOS:RegisterEvent(event, fn, priority)
  if type(event) ~= "string" or type(fn) ~= "function" then
    self:CoreLog("Invalid event registration parameters", "error")
  end
  local list = self.Events._handlers[event]
  if not list then
    list = {}
    self.Events._handlers[event] = list
    self.Events:RegisterEvent(event)
  end
  local h = { id = _hid(), fn = fn, priority = tonumber(priority) or 0 }
  list[#list + 1] = h
  table_sort(list, function(a, b) return a.priority > b.priority end)
  function h:Unregister()
    local L = AIOS.Events._handlers[event]
    if not L then return end
    for i = #L, 1, -1 do
      if L[i] == self then
        table_remove(L, i)
        break
      end
    end
    if #L == 0 then
      AIOS.Events:UnregisterEvent(event)
      AIOS.Events._handlers[event] = nil
    end
  end
  return h
end

function AIOS:UnregisterEvent(event)
  local L = self.Events._handlers[event]
  self.Events._handlers[event] = nil
  if L then self.Events:UnregisterEvent(event) end
end

-- ==========================================================================
-- Plugin Ecosystem™
-- ==========================================================================
AIOS.Plugins = AIOS.Plugins or {}

local function _toon()
  local name = (UnitName and UnitName("player")) or "Unknown"
  local realm = (GetRealmName and GetRealmName()) or "Realm"
  return name .. "-" .. realm:gsub("%s+", "")
end

local function _persistPluginMeta(id, plugin)
  _G.AIOS_Saved = _G.AIOS_Saved or {}
  local S = _G.AIOS_Saved
  S.plugins = S.plugins or {}
  local meta = S.plugins[id] or {}
  meta.lastSeen = date("%Y-%m-%d %H:%M:%S")
  meta.version = plugin.version or plugin.__v or "1.0.0"
  meta.modules = plugin.modules or nil
  meta.author = plugin.author or "Anonymous"
  S.plugins[id] = meta
end

function AIOS:RegisterPlugin(id, plugin, dependencies)
  if not id or type(plugin) ~= "table" then
    self:CoreLog("[PluginHost] invalid plugin registration", "error")
    return
  end
  if self.Plugins[id] then
    self:CoreLog("[PluginHost] plugin '"..id.."' already registered, upgrading", "warn")
  end
  if dependencies and type(dependencies) == "table" then
    local missing = {}
    for _, dep in ipairs(dependencies) do
      if not self.Plugins[dep] then table.insert(missing, dep) end
    end
    if #missing > 0 then
      self:CoreLog(string_format("[PluginHost] Plugin '%s' missing dependencies: %s", id, table.concat(missing, ", ")), "warn")
      self._pendingPlugins = self._pendingPlugins or {}
      self._pendingPlugins[id] = {plugin = plugin, deps = dependencies}
      return
    end
  end
  self:_registerPluginInternal(id, plugin)
end

function AIOS:_registerPluginInternal(id, plugin)
  self.Plugins[id] = plugin
  plugin.id = id
  local toon = _toon()
  _G.AIOS_Saved = _G.AIOS_Saved or {}
  _G.AIOS_Saved.char = _G.AIOS_Saved.char or {}
  _G.AIOS_Saved.char[toon] = _G.AIOS_Saved.char[toon] or {}
  if not _G.AIOS_Saved.char[toon][id] then
    _G.AIOS_Saved.char[toon][id] = {}
  end
  plugin.Memory = _G.AIOS_Saved.char[toon][id]
  _persistPluginMeta(id, plugin)
  if type(plugin.OnInitialize) == "function" then
    local ok, err = pcall(plugin.OnInitialize, plugin)
    if not ok then
      self:CoreLog("[PluginHost] "..id.." OnInitialize error: "..tostring(err), "error")
    end
  end
  if type(plugin.OnBoot) == "function" then
    local ok, err = pcall(plugin.OnBoot, plugin)
    if not ok then
      self:CoreLog("[PluginHost] "..id.." OnBoot error: "..tostring(err), "error")
    end
  end
  AIOS.SignalHub:Emit("PluginRegistered", id)
  if type(plugin.OnEnable) == "function" then
    local ok, err = pcall(plugin.OnEnable, plugin)
    if not ok then
      self:CoreLog("[PluginHost] "..id.." OnEnable error: "..tostring(err), "error")
    end
  end
  self:_checkPendingPlugins(id)
end

function AIOS:_checkPendingPlugins(registeredId)
  if not self._pendingPlugins then return end
  for id, data in pairs(self._pendingPlugins) do
    local allDepsMet = true
    for _, dep in ipairs(data.deps) do
      if not self.Plugins[dep] then
        allDepsMet = false
        break
      end
    end
    if allDepsMet then
      self:_registerPluginInternal(id, data.plugin)
      self._pendingPlugins[id] = nil
    end
  end
end

function AIOS:EnablePlugin(id)
  local p = self.Plugins[id]
  if p and type(p.OnEnable) == "function" then
    local ok, err = pcall(p.OnEnable, p)
    if not ok then
      self:CoreLog("[PluginHost] "..id.." OnEnable error: "..tostring(err), "error")
    end
  end
end

function AIOS:DisablePlugin(id)
  local p = self.Plugins[id]
  if p and type(p.OnDisable) == "function" then
    local ok, err = pcall(p.OnDisable, p)
    if not ok then
      self:CoreLog("[PluginHost] "..id.." OnDisable error: "..tostring(err), "error")
    end
  end
end

-- ==========================================================================
-- Dependency Injection System™
-- ==========================================================================
AIOS.DI = AIOS.DI or {}

function AIOS:Provide(serviceName, providerFn)
  self.DI[serviceName] = providerFn
  self:CoreLog("Service provided: " .. serviceName, "debug")
end

function AIOS:Inject(serviceName)
  local provider = self.DI[serviceName]
  if not provider then
    self:CoreLog("Service not available: " .. serviceName, "error")
    return nil
  end
  if type(provider) == "function" then
    return provider()
  else
    return provider
  end
end

-- ==========================================================================
-- Thermal Throttling System™
-- ==========================================================================
AIOS.Throttle = AIOS.Throttle or {}

function AIOS:ThrottleFn(fn, interval, id)
  id = id or tostring(fn):match("function: (.-)%]") or "anonymous"
  self.Throttle._lastCall = self.Throttle._lastCall or {}
  return function(...)
    local now = GetTime()
    local last = self.Throttle._lastCall[id] or 0
    if now - last >= interval then
      self.Throttle._lastCall[id] = now
      return fn(...)
    end
    return nil, "throttled"
  end
end

function AIOS:DebounceFn(fn, delay, id)
  if not AIOS.Timers then
    self:CoreLog("DebounceFn requires AIOS.Timers", "error")
    return fn
  end
  id = id or tostring(fn):match("function: (.-)%]") or "anonymous"
  self.Throttle._timers = self.Throttle._timers or {}
  return function(...)
    local timer = self.Throttle._timers[id]
    if timer then timer:Cancel() end
    local args = { ... }
    self.Throttle._timers[id] = AIOS.Timers:After(delay, function()
      self.Throttle._timers[id] = nil
      fn(unpack(args))
    end)
  end
end

-- ==========================================================================
-- Quantum Diagnostics™ (Simplified)
-- ==========================================================================
AIOS.CoreDiag = AIOS.CoreDiag or { events=0, signals=0, plugins=0, performance={ enabled=false } }

function AIOS:GetDiagnostics()
  local function countTableKeys(tbl)
    if not tbl then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
  end
  
  return {
    core_v = self.__core_v,
    signals = self.CoreDiag.signals or 0,
    events = self.CoreDiag.events or 0,
    plugins = self.CoreDiag.plugins or 0,
    quiet = self._quietBoot,
    level = self._logLevel or 3,
    performance = self.CoreDiag.performance.enabled and self.CoreDiag.performance or {},
    memory = {
      events = countTableKeys(self.Events._handlers),
      signals = countTableKeys(self.SignalHub._reg),
      plugins = countTableKeys(self.Plugins),
      services = countTableKeys(self.DI)
    }
  }
end

function AIOS:SetPerformanceTracking(enabled)
  self.CoreDiag.performance.enabled = not not enabled
  self:CoreLog("Performance tracking " .. (enabled and "enabled" or "disabled"), "debug")
end

-- Wrap SignalHub emit for diagnostics (safe version)
local _emit_orig = Hub.Emit
Hub.Emit = function(self, sig, ...)
  if AIOS.CoreDiag.performance.enabled then
    local start = GetTime()
    AIOS.CoreDiag.signals = (AIOS.CoreDiag.signals or 0) + 1
    local result = {_emit_orig(self, sig, ...)}
    local duration = GetTime() - start
    
    -- Safe metric tracking - avoid complex nested tables
    if not AIOS.CoreDiag.performance.signals then
      AIOS.CoreDiag.performance.signals = {}
    end
    if not AIOS.CoreDiag.performance.signals[sig] then
      AIOS.CoreDiag.performance.signals[sig] = {count=0, totalTime=0, maxTime=0}
    end
    
    local metric = AIOS.CoreDiag.performance.signals[sig]
    metric.count = metric.count + 1
    metric.totalTime = metric.totalTime + duration
    metric.maxTime = math_max(metric.maxTime, duration)
    
    return unpack(result)
  else
    return _emit_orig(self, sig, ...)
  end
end

-- Wrap event handler for diagnostics (safe version)
local _onEvent_orig = AIOS.Events:GetScript("OnEvent")
AIOS.Events:SetScript("OnEvent", function(...)
  if AIOS.CoreDiag.performance.enabled then
    local start = GetTime()
    AIOS.CoreDiag.events = (AIOS.CoreDiag.events or 0) + 1
    local result = {_onEvent_orig(...)}
    local duration = GetTime() - start
    local event = select(2, ...)
    
    -- Safe metric tracking
    if not AIOS.CoreDiag.performance.events then
      AIOS.CoreDiag.performance.events = {}
    end
    if not AIOS.CoreDiag.performance.events[event] then
      AIOS.CoreDiag.performance.events[event] = {count=0, totalTime=0, maxTime=0}
    end
    
    local metric = AIOS.CoreDiag.performance.events[event]
    metric.count = metric.count + 1
    metric.totalTime = metric.totalTime + duration
    metric.maxTime = math_max(metric.maxTime, duration)
    
    return unpack(result)
  else
    return _onEvent_orig(...)
  end
end)

-- Wrap plugin registration for diagnostics
local _registerPlugin_orig = AIOS.RegisterPlugin
AIOS.RegisterPlugin = function(self, id, plugin, deps)
  AIOS.CoreDiag.plugins = (AIOS.CoreDiag.plugins or 0) + 1
  return _registerPlugin_orig(self, id, plugin, deps)
end
-- ==========================================================================
-- Boot Sequence™
-- ==========================================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  local toon = (UnitName and UnitName("player") or "Unknown").."-"..((GetRealmName and GetRealmName():gsub("%s+", "")) or "Realm")
  _G.AIOS_Saved = _G.AIOS_Saved or {}
  _G.AIOS_Saved.char = _G.AIOS_Saved.char or {}
  _G.AIOS_Saved.global = _G.AIOS_Saved.global or {}
  _G.AIOS_Saved.char[toon] = _G.AIOS_Saved.char[toon] or {}
  AIOS.char = _G.AIOS_Saved.char[toon]
  AIOS.SignalHub:Emit("AIOS_Core_Ready")
  boot:UnregisterAllEvents()
  boot:Hide()
  AIOS:CoreLog("AIOS Core initialized successfully. Welcome to the future.", "info")
end)

-- ==========================================================================
-- Smoke test (silent)
-- ==========================================================================
do
  local ok, err = pcall(function()
    local h = AIOS:RegisterEvent("PLAYER_LOGIN", function() end)
    h:Unregister()
    AIOS.SignalHub:Listen("TEST_SIGNAL", function() end, {once=true}):Cancel()
    AIOS:RegisterPlugin("TEST_PLUGIN", {OnInitialize=function() end, OnBoot=function() end, OnEnable=function() end})
    AIOS:Provide("TEST_SERVICE", function() return {} end)
    assert(AIOS:Inject("TEST_SERVICE") ~= nil)
  end)
  if not ok then
    AIOS:CoreLog("Core smoke test failed: " .. tostring(err), "error")
  end
end

-- ==========================================================================
-- Debug slash command (remove in final release)
-- ==========================================================================
_G.SLASH_AIOSCORE1 = "/aioscore"
SlashCmdList["AIOSCORE"] = function()
  local diag = AIOS:GetDiagnostics()
  AIOS:CoreLog(string_format("Core v%d: %d events, %d signals, %d plugins", diag.core_v, diag.events, diag.signals, diag.plugins), "info")
end

-- ==========================================================================
-- AIOS API Testing System (Removable)
-- ==========================================================================
AIOS._TestSystem = AIOS._TestSystem or {}

function AIOS:_RunAPITests()
    if not self.DevMode or not self.DevMode:IsEnabled() then
        self:CoreLog("API tests require DevMode to be enabled", "warn")
        return
    end
    
    local tests = {}
    local passed = 0
    local failed = 0
    
    -- Test 1: Core API
    table.insert(tests, function()
        local success, result = pcall(function()
            assert(self.RegisterEvent, "RegisterEvent missing")
            assert(self.UnregisterEvent, "UnregisterEvent missing")
            assert(self.SignalHub, "SignalHub missing")
            assert(self.SignalHub.Listen, "SignalHub.Listen missing")
            assert(self.SignalHub.Emit, "SignalHub.Emit missing")
            return true
        end)
        return success, result
    end)
    
    -- Test 2: Event System
    table.insert(tests, function()
        local success, result = pcall(function()
            local eventFired = false
            local handle = self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
                eventFired = true
            end)
            assert(handle, "Event registration failed")
            assert(handle.Unregister, "Event handle missing Unregister method")
            handle:Unregister()
            return true
        end)
        return success, result
    end)
    
    -- Test 3: Signal System
    table.insert(tests, function()
        local success, result = pcall(function()
            local signalReceived = false
            local handle = self.SignalHub:Listen("TEST_SIGNAL", function(data)
                signalReceived = (data == "test_data")
            end)
            assert(handle, "Signal registration failed")
            assert(handle.Cancel, "Signal handle missing Cancel method")
            self.SignalHub:Emit("TEST_SIGNAL", "test_data")
            handle:Cancel()
            return signalReceived
        end)
        return success, result
    end)
    
    -- Test 4: Plugin System
    table.insert(tests, function()
        local success, result = pcall(function()
            local pluginInitialized = false
            local testPlugin = {
                OnInitialize = function() pluginInitialized = true end,
                OnEnable = function() end
            }
            self:RegisterPlugin("TEST_PLUGIN", testPlugin)
            assert(self.Plugins["TEST_PLUGIN"], "Plugin registration failed")
            return pluginInitialized
        end)
        return success, result
    end)
    
    -- Test 5: Dependency Injection
    table.insert(tests, function()
        local success, result = pcall(function()
            self:Provide("TEST_SERVICE", function() return {value = 42} end)
            local service = self:Inject("TEST_SERVICE")
            assert(service, "Service injection failed")
            assert(service.value == 42, "Service value incorrect")
            return true
        end)
        return success, result
    end)
    
    -- Test 6: Throttling System
    table.insert(tests, function()
        local success, result = pcall(function()
            local callCount = 0
            local throttledFn = self:ThrottleFn(function() 
                callCount = callCount + 1 
            end, 1, "test_throttle")
            
            throttledFn()
            throttledFn() -- Should be throttled
            return callCount == 1
        end)
        return success, result
    end)
    
    -- Test 7: Diagnostics
    table.insert(tests, function()
        local success, result = pcall(function()
            local diag = self:GetDiagnostics()
            assert(diag, "Diagnostics failed")
            assert(type(diag.core_v) == "number", "Core version missing")
            return true
        end)
        return success, result
    end)
    
    -- Run all tests
    self:CoreLog("Running AIOS API Tests...", "info")
    
    for i, test in ipairs(tests) do
        local success, result = test()
        if success and result then
            self:CoreLog(string.format("Test %d: PASSED", i), "info")
            passed = passed + 1
        else
            self:CoreLog(string.format("Test %d: FAILED - %s", i, tostring(result)), "error")
            failed = failed + 1
        end
    end
    
    -- Summary
    self:CoreLog(string.format("API Tests Complete: %d passed, %d failed", passed, failed), 
                failed == 0 and "info" or "error")
    
    return passed, failed
end

-- Test command
_G.SLASH_AIOSTEST1 = "/aiostest"
SlashCmdList["AIOSTEST"] = function()
    AIOS:_RunAPITests()
end

-- Auto-run tests on boot if in dev mode (optional)
local testBoot = CreateFrame("Frame")
testBoot:RegisterEvent("PLAYER_LOGIN")
testBoot:SetScript("OnEvent", function()
    if AIOS.DevMode and AIOS.DevMode:IsEnabled() then
        C_Timer.After(2, function()  -- Delay to let everything load
            AIOS:_RunAPITests()
        end)
    end
end)

-- ==========================================================================
-- Module Availability Checker
-- ==========================================================================
function AIOS:CheckModuleAvailability()
    local availableModules = {}
    local missingModules = {}
    
    local expectedModules = {
        "Lean", "Serializer", "Utils", "Services", "Logger", "EventBus",
        "Timers", "Version", "Saved", "Codec", "ModuleLoader", "DevMode",
        "Config", "Locale", "Media", "Profile", "DebugCap", "Console"
    }
    
    for _, module in ipairs(expectedModules) do
        if self[module] then
            table.insert(availableModules, module)
        else
            table.insert(missingModules, module)
        end
    end
    
    self:CoreLog("Available Modules: " .. table.concat(availableModules, ", "), "debug")
    if #missingModules > 0 then
        self:CoreLog("Missing Modules: " .. table.concat(missingModules, ", "), "debug")
    end
    
    return availableModules, missingModules
end

-- Module check command
_G.SLASH_AIOSMODULES1 = "/aiosmodules"
SlashCmdList["AIOSMODULES"] = function()
    AIOS:CheckModuleAvailability()
end

-- ==========================================================================
-- AIOS API Testing System (Ultra Simple)
-- ==========================================================================
AIOS._TestSystem = AIOS._TestSystem or {}
AIOS._TestSystem.enabled = true

-- Simple test function
function AIOS:RunSimpleTest()
    self:CoreLog("Running simple API test...", "info")
    
    -- Test 1: Basic API existence
    if self.RegisterEvent and self.SignalHub then
        self:CoreLog("✓ Core API present", "info")
    else
        self:CoreLog("✗ Core API missing", "error")
    end
    
    -- Test 2: Signal system
    local signalWorked = false
    local handle = self.SignalHub:Listen("SIMPLE_TEST", function()
        signalWorked = true
    end)
    self.SignalHub:Emit("SIMPLE_TEST")
    if handle then handle:Cancel() end
    
    if signalWorked then
        self:CoreLog("✓ Signal system working", "info")
    else
        self:CoreLog("✗ Signal system failed", "error")
    end
    
    -- Test 3: Module check
    local available = {}
    local missing = {}
    local modules = {"Logger", "Timers", "Utils", "EventBus"}
    
    for _, mod in pairs(modules) do
        if self[mod] then
            table.insert(available, mod)
        else
            table.insert(missing, mod)
        end
    end
    
    self:CoreLog("Available: " .. table.concat(available, ", "), "info")
    if #missing > 0 then
        self:CoreLog("Missing: " .. table.concat(missing, ", "), "debug")
    end
    
    self:CoreLog("Simple test complete!", "info")
end

-- ==========================================================================
-- ENHANCED SLASH COMMANDS WITH TESTING
-- ==========================================================================

SLASH_AIOSCORE1 = "/aioscore"
SLASH_AIOSMODULES1 = "/aiosmodules"
SLASH_AIOSTEST1 = "/aios"  -- Main test command

-- Enhanced diagnostics command
SlashCmdList["AIOSCORE"] = function()
    local core_v = AIOS.__core_v or "unknown"
    local event_count = 0
    local signal_count = 0
    local plugin_count = 0
    
    -- Count events
    local event_names = {}
    if AIOS.Events and AIOS.Events._handlers then
        for event_name in pairs(AIOS.Events._handlers) do 
            event_count = event_count + 1
            table.insert(event_names, event_name)
        end
    end
    
    -- Count signals and get signal names
    local signal_names = {}
    if AIOS.SignalHub and AIOS.SignalHub._reg then
        for signal_name in pairs(AIOS.SignalHub._reg) do 
            signal_count = signal_count + 1
            table.insert(signal_names, signal_name)
        end
    end
    
    -- Count plugins and get plugin names
    local plugin_names = {}
    if AIOS.Plugins then
        for plugin_name in pairs(AIOS.Plugins) do 
            plugin_count = plugin_count + 1
            table.insert(plugin_names, plugin_name)
        end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage(string.format("AIOS Core v%s: %d events, %d signals, %d plugins", 
        tostring(core_v), event_count, signal_count, plugin_count))
    
    -- Show details
    if #signal_names > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("Signals: " .. table.concat(signal_names, ", "))
    end
    
    if #plugin_names > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("Plugins: " .. table.concat(plugin_names, ", "))
    end
    
    if #event_names > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("Events: " .. table.concat(event_names, ", "))
    end
end

-- Enhanced module availability command
SlashCmdList["AIOSMODULES"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== AIOS Modules ===")
    
    local modules = {
        "Events", "SignalHub", "Plugins", "DI", "Throttle", 
        "Timers", "Logger", "EventBus", "Utils", "Serializer"
    }
    local found = {}
    local missing = {}
    
    for _, mod in ipairs(modules) do
        if AIOS[mod] then
            table.insert(found, mod)
        else
            table.insert(missing, mod)
        end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("Available: " .. table.concat(found, ", "))
    if #missing > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("Missing: " .. table.concat(missing, ", "))
    end
end

-- TEST COMMANDS

SLASH_UISTYLETEST1 = "/uistytest"
SlashCmdList["UISTYLETEST"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== AIOS_UIStyles Comprehensive Test ===")
    
    if not AIOS_UIStyle then
        DEFAULT_CHAT_FRAME:AddMessage("✗ AIOS_UIStyle not found!")
        return
    end
    
    -- Basic info
    DEFAULT_CHAT_FRAME:AddMessage("Version: " .. (AIOS_UIStyle.__version or "unknown"))
    DEFAULT_CHAT_FRAME:AddMessage("State: " .. (AIOS_UIStyle:GetState() or "unknown"))
    
    -- Components
    if AIOS_UIStyle.GetComponentNames then
        local comps = AIOS_UIStyle:GetComponentNames()
        DEFAULT_CHAT_FRAME:AddMessage("Components: " .. #comps .. " registered")
    end
    
    -- Themes
    if AIOS_UIStyle.GetThemeNames then
        local themes = AIOS_UIStyle:GetThemeNames()
        DEFAULT_CHAT_FRAME:AddMessage("Themes: " .. #themes .. " available")
    end
    
    -- Test panel creation
    if AIOS_UIStyle.CreatePanel then
        local panel = AIOS_UIStyle:CreatePanel("UISTestPanel", UIParent)
        if panel then
            panel:SetPoint("CENTER")
            panel:SetSize(150, 80)
            DEFAULT_CHAT_FRAME:AddMessage("✓ Test panel created & styled")
        else
            DEFAULT_CHAT_FRAME:AddMessage("✗ Panel creation failed")
        end
    end
    
    -- Check capabilities
    if AIOS_UIStyle.Capabilities then
        local caps = AIOS_UIStyle:Capabilities()
        DEFAULT_CHAT_FRAME:AddMessage("Batching: " .. (caps.batching and "✓" or "✗"))
        DEFAULT_CHAT_FRAME:AddMessage("DevHooks: " .. (caps.devHooks and "✓" or "✗"))
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("=== Test Complete ===")
end

-- Add this to your slash command section
SLASH_AIOSDEBUG1 = "/aiosdebug"
SlashCmdList["AIOSDEBUG"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== AIOS DEBUG INFO ===")
    
    -- Detailed plugin info
    if AIOS.Plugins then
        for pluginName, plugin in pairs(AIOS.Plugins) do
            DEFAULT_CHAT_FRAME:AddMessage("Plugin: " .. pluginName)
            if plugin.Memory then
                DEFAULT_CHAT_FRAME:AddMessage("  Memory: " .. tostring(plugin.Memory))
            end
        end
    end
    
    -- Check if SimLite has submodules
    if AIOS_SimLite then
        DEFAULT_CHAT_FRAME:AddMessage("SimLite Submodules:")
        for key, value in pairs(AIOS_SimLite) do
            if type(value) == "table" and key ~= "Memory" then
                DEFAULT_CHAT_FRAME:AddMessage("  " .. key)
            end
        end
    end
end

SLASH_SIMLITEMODS1 = "/simlitemods"
SlashCmdList["SIMLITEMODS"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== SimLite Internal Modules ===")
    
    -- Access through AIOS plugins instead of global
    local simlite = AIOS.Plugins and AIOS.Plugins["AIOS_SimLite"]
    
    if simlite then
        DEFAULT_CHAT_FRAME:AddMessage("SimLite found in AIOS plugins!")
        
        -- Check if it has submodules
        local moduleCount = 0
        for key, value in pairs(simlite) do
            if type(value) == "table" and key ~= "Memory" and key ~= "id" then
                DEFAULT_CHAT_FRAME:AddMessage("• " .. key)
                moduleCount = moduleCount + 1
            end
        end
        
        if moduleCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("No internal modules found (might be private)")
            DEFAULT_CHAT_FRAME:AddMessage("Available keys: " .. table.concat({}, ", "))
        end
        
    else
        DEFAULT_CHAT_FRAME:AddMessage("SimLite not found in AIOS plugins!")
    end
end

SLASH_SIMLITEINFO1 = "/simliteinfo"
SlashCmdList["SIMLITEINFO"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== SimLite Plugin Structure ===")
    
    local simlite = AIOS.Plugins and AIOS.Plugins["AIOS_SimLite"]
    
    if simlite then
        DEFAULT_CHAT_FRAME:AddMessage("Plugin ID: " .. tostring(simlite.id))
        DEFAULT_CHAT_FRAME:AddMessage("Memory: " .. tostring(simlite.Memory))
        
        -- List all keys in the plugin
        local keys = {}
        for key in pairs(simlite) do
            table.insert(keys, key)
        end
        DEFAULT_CHAT_FRAME:AddMessage("Keys: " .. table.concat(keys, ", "))
    else
        DEFAULT_CHAT_FRAME:AddMessage("SimLite plugin not found!")
    end
end

SLASH_SIMLITELOADED1 = "/simliteloaded"
SlashCmdList["SIMLITELOADED"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("=== SimLite Loaded Components ===")
    
    local simlite = AIOS.Plugins and AIOS.Plugins["AIOS_SimLite"]
    if simlite and simlite.Memory then
        DEFAULT_CHAT_FRAME:AddMessage("Checking Memory for loaded modules...")
        
        -- Check if memory contains module info
        for key, value in pairs(simlite.Memory) do
            if type(value) == "table" then
                DEFAULT_CHAT_FRAME:AddMessage("Memory." .. key .. ": " .. tostring(value))
            else
                DEFAULT_CHAT_FRAME:AddMessage("Memory." .. key .. " = " .. tostring(value))
            end
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("No memory storage found")
    end
end

SlashCmdList["AIOSTEST"] = function(msg)
    local command = msg and string.lower(string.trim(msg)) or ""
    
    if command == "testevent" then
        -- Test event system
        local handle = AIOS:RegisterEvent("UNIT_HEALTH", function(unit)
            DEFAULT_CHAT_FRAME:AddMessage("Health event: " .. tostring(unit))
        end)
        DEFAULT_CHAT_FRAME:AddMessage("Event registered! Use /aioscore to see event count")
        
    elseif command == "testsignal" then
        -- Test signal system
        AIOS.SignalHub:Listen("TEST_SIGNAL", function(data)
            DEFAULT_CHAT_FRAME:AddMessage("Signal received: " .. tostring(data))
        end)
        AIOS.SignalHub:Emit("TEST_SIGNAL", "Hello from test!")
        DEFAULT_CHAT_FRAME:AddMessage("Signal test completed!")
        
    elseif command == "testdi" then
        -- Test dependency injection
        AIOS:Provide("MathService", function()
            return {
                add = function(a, b) return a + b end,
                multiply = function(a, b) return a * b end
            }
        end)
        local math = AIOS:Inject("MathService")
        if math then
            DEFAULT_CHAT_FRAME:AddMessage("DI Test: 2 + 3 = " .. math.add(2, 3))
            DEFAULT_CHAT_FRAME:AddMessage("DI Test: 2 * 3 = " .. math.multiply(2, 3))
        else
            DEFAULT_CHAT_FRAME:AddMessage("DI Test failed!")
        end
        
    elseif command == "testthrottle" then
        -- Test throttling
        local callCount = 0
        local throttledFn = AIOS:ThrottleFn(function()
            callCount = callCount + 1
            DEFAULT_CHAT_FRAME:AddMessage("Throttled function called: " .. callCount)
        end, 2) -- 2 second throttle
        
        throttledFn() -- Should work
        throttledFn() -- Should be throttled
        throttledFn() -- Should be throttled
        
        DEFAULT_CHAT_FRAME:AddMessage("Throttling test started. Only first call should show.")
        
    else
        DEFAULT_CHAT_FRAME:AddMessage("AIOS Test Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("/aios testevent - Test event system")
        DEFAULT_CHAT_FRAME:AddMessage("/aios testsignal - Test signal system") 
        DEFAULT_CHAT_FRAME:AddMessage("/aios testdi - Test dependency injection")
        DEFAULT_CHAT_FRAME:AddMessage("/aios testthrottle - Test throttling system")
    end
end

-- Global access
_G.AIOS_Core = AIOS
return AIOS