--[[
AIOS_Core.lua — The Future of WoW Addon Development (Retail 11.2, Classic Era, Mists of Pandaria Classic)
Author: AIOS Team

The One Core to Rule Them All:
  - Original replacement for Ace3, no external dependencies.
  - Optimized for Retail (11.2), Classic Era, Mists of Pandaria Classic.
  - Features: events, signals, plugins, dependency injection, diagnostics.

API:
  - AIOS:RegisterEvent(event, fn, priority) -> handle
  - AIOS:UnregisterEvent(event)
  - AIOS.SignalHub:Listen(signal, handler, opts) -> handle
  - AIOS:RegisterPlugin(id, plugin, dependencies)
  - AIOS:Provide(serviceName, providerFn)
  - AIOS:Inject(serviceName) -> service
  - AIOS:GetDiagnostics() -> table
  - AIOS:SetPerformanceTracking(enabled)
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
  local survivors = {}
  local nArgs = select("#", ...)
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
    return nil
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
-- Quantum Diagnostics™
-- ==========================================================================
AIOS.CoreDiag = AIOS.CoreDiag or { events=0, signals=0, plugins=0, performance={ enabled=false } }

local _emit_orig = Hub.Emit
Hub.Emit = function(self, sig, ...)
  if AIOS.CoreDiag.performance.enabled then
    local start = GetTime()
    AIOS.CoreDiag.signals = (AIOS.CoreDiag.signals or 0) + 1
    local result = {_emit_orig(self, sig, ...)}
    local duration = GetTime() - start
    AIOS.CoreDiag.performance.signals = AIOS.CoreDiag.performance.signals or {}
    AIOS.CoreDiag.performance.signals[sig] = AIOS.CoreDiag.performance.signals[sig] or {count=0, totalTime=0, maxTime=0}
    local metric = AIOS.CoreDiag.performance.signals[sig]
    metric.count = metric.count + 1
    metric.totalTime = metric.totalTime + duration
    metric.maxTime = math_max(metric.maxTime, duration)
    return unpack(result)
  else
    return _emit_orig(self, sig, ...)
  end
end

local _onEvent_orig = AIOS.Events:GetScript("OnEvent")
AIOS.Events:SetScript("OnEvent", function(...)
  if AIOS.CoreDiag.performance.enabled then
    local start = GetTime()
    AIOS.CoreDiag.events = (AIOS.CoreDiag.events or 0) + 1
    local result = {_onEvent_orig(...)}
    local duration = GetTime() - start
    local event = select(1, ...)
    AIOS.CoreDiag.performance.events = AIOS.CoreDiag.performance.events or {}
    AIOS.CoreDiag.performance.events[event] = AIOS.CoreDiag.performance.events[event] or {count=0, totalTime=0, maxTime=0}
    local metric = AIOS.CoreDiag.performance.events[event]
    metric.count = metric.count + 1
    metric.totalTime = metric.totalTime + duration
    metric.maxTime = math_max(metric.maxTime, duration)
    return unpack(result)
  else
    return _onEvent_orig(...)
  end
end)

local _registerPlugin_orig = AIOS.RegisterPlugin
AIOS.RegisterPlugin = function(self, id, plugin, deps)
  AIOS.CoreDiag.plugins = (AIOS.CoreDiag.plugins or 0) + 1
  return _registerPlugin_orig(self, id, plugin, deps)
end

function AIOS:GetDiagnostics()
  local function countTableKeys(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
  end
  return {
    core_v = AIOS.__core_v,
    signals = AIOS.CoreDiag.signals or 0,
    events = AIOS.CoreDiag.events or 0,
    plugins = AIOS.CoreDiag.plugins or 0,
    quiet = AIOS._quietBoot and true or false,
    level = AIOS._logLevel or 3,
    performance = AIOS.CoreDiag.performance.enabled and AIOS.CoreDiag.performance or {},
    memory = {
      events = self.Events._handlers and countTableKeys(self.Events._handlers) or 0,
      signals = self.SignalHub._reg and countTableKeys(self.SignalHub._reg) or 0,
      plugins = self.Plugins and countTableKeys(self.Plugins) or 0,
      services = self.DI and countTableKeys(self.DI) or 0
    }
  }
end

function AIOS:SetPerformanceTracking(enabled)
  AIOS.CoreDiag.performance.enabled = not not enabled
  self:CoreLog("Performance tracking " .. (enabled and "enabled" or "disabled"), "debug")
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

-- Global access
_G.AIOS_Core = AIOS
return AIOS