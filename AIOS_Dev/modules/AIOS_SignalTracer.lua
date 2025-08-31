--[[
AIOS_SignalTracer.lua — v1.4
Trace AIOS events/signals without chat spam.

Slash:
  /aiostrace on <EVENT|*>
  /aiostrace once <EVENT>
  /aiostrace off
  /aiostrace list
  /aiostrace level <debug|info|warn|error>
  /aiostrace tag <text>
  /aiostrace diag
  /aiostrace selftest

Notes:
- Prefers AIOS.SignalHub, falls back to AIOS.EventBus.
- Uses ListenAny when available. Otherwise:
  - Per-event listeners for named events
  - For wildcard (*), wraps Emit/Trigger to mirror events into the logger
]]--

local _G = _G
AIOS = _G.AIOS or {}

local Tr = {
  enabled = false,
  filters = {},     -- map[event]=true, '*' allowed
  once = nil,       -- string|nil
  wildcard = false, -- convenience flag
  level = "info",
  tag = "Trace",
  _bus = nil,
  _emitPatched = false,
  _pendingFilters = {},
  _retryTicker = nil,
}
AIOS.SignalTracer = Tr

-- logging helper
local function Dlog(level, tag, msg)
  if AIOS and AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log(level or "info", tag or "Trace", msg)
  end
end

-- bus helpers
local function find_bus()
  if AIOS and AIOS.SignalHub then return AIOS.SignalHub end
  if AIOS and AIOS.EventBus then return AIOS.EventBus end
  return nil
end

local function safe_listen(bus, ev, handler)
  if not bus or not ev or not handler then return false end
  for _,m in ipairs({ "Listen", "On", "Add", "Register", "Subscribe" }) do
    local f = bus[m]
    if type(f) == "function" then
      local ok = pcall(f, bus, ev, handler)
      return ok
    end
  end
  return false
end

-- core logic
local function should_log(ev)
  if not Tr.enabled then return false end
  if Tr.once and ev ~= Tr.once then return false end
  if Tr.wildcard or Tr.filters["*"] then return true end
  return Tr.filters[ev] == true
end

local function fmt_args(...)
  local n = select("#", ...)
  if n == 0 then return "" end
  local parts = {}
  for i = 1, n do parts[#parts+1] = tostring(select(i, ...)) end
  return table.concat(parts, ", ")
end

local function on_any_signal(ev, ...)
  if not should_log(ev) then return end
  Dlog(Tr.level, Tr.tag, string.format("%s  args=[%s]", tostring(ev), fmt_args(...)))
  if Tr.once and ev == Tr.once then
    -- turn everything off after first hit
    Tr.enabled = false
    Tr.filters = {}
    Tr.once = nil
    Tr.wildcard = false
    Dlog("info", "Trace", "once complete; tracing disabled")
  end
end

-- Try to hook a "listen any" if the bus supports it
local function try_listen_any()
  local EB = Tr._bus
  if not EB or Tr._emitPatched then return false end
  if type(EB.ListenAny) == "function" and not EB._aios_trace_listenAnyInstalled then
    EB._aios_trace_listenAnyInstalled = true
    local ok = pcall(EB.ListenAny, EB, function(event, ...)
      on_any_signal(event, ...)
    end)
    if ok then
      Tr._emitPatched = true
      return true
    end
  end
  return false
end

-- Fallback: wrap Emit/Trigger so wildcard can still see events
local function patch_emit_for_wildcard()
  local EB = Tr._bus
  if not EB or Tr._emitPatched then return end

  local orig = EB.Emit or EB.Trigger
  if type(orig) ~= "function" then return end

  local fn = function(self, event, ...)
    if Tr.enabled and (Tr.wildcard or Tr.filters["*"]) then
      pcall(on_any_signal, event, ...)
    end
    return orig(self, event, ...)
  end

  if EB.Emit then EB.Emit = fn else EB.Trigger = fn end
  Tr._emitPatched = true
end

local function ensure_bus_and_hooks()
  if not Tr._bus then Tr._bus = find_bus() end
  if not Tr._bus then return false end

  -- Try best-effort listen-any first
  if not try_listen_any() then
    -- For named filters we add explicit listeners
    for ev in pairs(Tr._pendingFilters) do
      safe_listen(Tr._bus, ev, function(...) on_any_signal(ev, ...) end)
    end
    Tr._pendingFilters = {}
    -- For wildcard, mirror via emit patch
    patch_emit_for_wildcard()
  end
  return true
end

local function start_retry_loop()
  if Tr._retryTicker then return end
  local tries = 0
  Tr._retryTicker = C_Timer.NewTicker(0.25, function(t)
    tries = tries + 1
    if ensure_bus_and_hooks() or tries >= 80 then
      t:Cancel()
      Tr._retryTicker = nil
    end
  end)
end

-- Initialize
ensure_bus_and_hooks()
start_retry_loop()

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  if ensure_bus_and_hooks() then return end
  start_retry_loop()
end)

-- Slash command
_G.SLASH_AIOSTRACE1 = "/aiostrace"
SlashCmdList["AIOSTRACE"] = function(msg)
  local args = {}
  for w in tostring(msg or ""):gmatch("%S+") do args[#args+1] = w end
  local sub = (args[1] or ""):lower()

  if sub == "on" and args[2] then
    local ev = args[2]
    Tr.enabled = true
    Tr.filters = {}
    Tr.filters[ev] = true
    Tr.once = nil
    Tr.wildcard = (ev == "*")
    if ev == "*" then
      ensure_bus_and_hooks()
      start_retry_loop()
    else
      if Tr._bus then
        safe_listen(Tr._bus, ev, function(...) on_any_signal(ev, ...) end)
      else
        Tr._pendingFilters[ev] = true
        start_retry_loop()
      end
    end
    Dlog("info","Trace","Tracing ON for: "..ev)

  elseif sub == "once" and args[2] then
    local ev = args[2]
    Tr.enabled = true
    Tr.filters = {}
    Tr.filters[ev] = true
    Tr.once = ev
    Tr.wildcard = (ev == "*")
    if ev == "*" then
      ensure_bus_and_hooks()
      start_retry_loop()
    else
      if Tr._bus then
        safe_listen(Tr._bus, ev, function(...) on_any_signal(ev, ...) end)
      else
        Tr._pendingFilters[ev] = true
        start_retry_loop()
      end
    end
    Dlog("info","Trace","Tracing ONCE for: "..ev)

  elseif sub == "off" then
    Tr.enabled = false
    Tr.filters = {}
    Tr.once = nil
    Tr.wildcard = false
    Dlog("info","Trace","Tracing OFF")

  elseif sub == "list" then
    local keys = {}
    for e,v in pairs(Tr.filters) do if v then keys[#keys+1] = e end end
    table.sort(keys)
    Dlog("info","Trace", (#keys == 0) and "No active filters" or ("Active filters: "..table.concat(keys, ", ")))

  elseif sub == "level" and args[2] then
    local lvl = args[2]:lower()
    if lvl=="debug" or lvl=="info" or lvl=="warn" or lvl=="error" then
      Tr.level = lvl
      Dlog("info","Trace","level -> "..lvl)
    else
      Dlog("info","Trace","Usage: /aiostrace level debug|info|warn|error")
    end

  elseif sub == "tag" and args[2] then
    Tr.tag = args[2]
    Dlog("info","Trace","tag -> "..Tr.tag)

  elseif sub == "diag" then
    local bus = (AIOS and (AIOS.SignalHub or AIOS.EventBus)) or nil
    local busName = (bus == AIOS.SignalHub and "SignalHub") or (bus == AIOS.EventBus and "EventBus") or "nil"
    local keys = {}
    for e,v in pairs(Tr.filters) do if v then keys[#keys+1]=e end end
    table.sort(keys)
    Dlog("info","Trace", ("diag: bus=%s emitPatched=%s wildcard=%s enabled=%s"):format(busName, tostring(Tr._emitPatched), tostring(Tr.wildcard), tostring(Tr.enabled)))
    Dlog("info","Trace", "diag: filters={"..table.concat(keys, ",").."}")

  elseif sub == "selftest" then
    ensure_bus_and_hooks()
    local bus = Tr._bus
    if not bus then Dlog("error","Trace","selftest: no bus"); return end
    local emit = bus.Emit or bus.Trigger
    if type(emit) ~= "function" then Dlog("error","Trace","selftest: bus has no Emit/Trigger"); return end
    emit(bus, "TRACE_DEMO", "selftest", (_G.GetTime and GetTime()) or 0)
    C_Timer.After(0.05, function() emit(bus, "TRACE_DEMO", "after", (_G.GetTime and GetTime()) or 0) end)
    Dlog("info","Trace","selftest: emitted TRACE_DEMO twice")

  else
    Dlog("info","Trace","Usage: /aiostrace on <EVENT|*> | once <EVENT> | off | list | level <lvl> | tag <txt> | diag | selftest")
  end
end

Dlog("info","Trace","AIOS_SignalTracer v1.4 ready. Use /aiostrace")
