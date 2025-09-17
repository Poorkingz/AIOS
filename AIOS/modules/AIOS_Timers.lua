--[[ 
AIOS_Timers.lua — Advanced Timer Engine
Version: 1.0
Author: Poorkingz
Project: https://www.curseforge.com/members/aios/projects
Website: https://aioswow.info/
Discord: https://discord.gg/JMBgHA5T
Support: support@aioswow.dev


Description:
  • Anchored, drift-free repeating timers (`Every`).
  • One-shot delayed timers (`After`).
  • Debounce and Throttle utilities (per-key).
  • Microtask queue with per-frame time budgeting.
  • Coroutine Sleep for async-like flow.
  • Safe error handling routed through AIOS:CoreLog.

API:
  AIOS.Timers:After(seconds, fn, ...) -> handle:Cancel()
  AIOS.Timers:Every(seconds, fn, opts?) -> handle:Cancel()
      opts = { now=false, maxLate=0.25 }
  AIOS.Timers:Debounce(key, interval, fn, ...)
  AIOS.Timers:Throttle(key, interval, fn, ...)
  AIOS.Timers:Microtask(fn, ...)
  AIOS.Timers.Sleep(seconds)   -- yield inside coroutine
  AIOS.Timers:RunCo(fn, ...)   -- run coroutine with Sleep support
]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Timers = AIOS.Timers or {}
local T = AIOS.Timers

local function clog(msg, level, tag)
  if AIOS and AIOS.CoreLog then AIOS:CoreLog(msg, level or "debug", tag or "Timers") end
end

-- Driver frame
T._driver = T._driver or CreateFrame("Frame")
T._driver:Hide()
T._driverTasks = T._driverTasks or {}  -- heap-ish array of timers
T._microQ = T._microQ or {}
T._coWait = T._coWait or {}            -- coroutine -> wakeTime

local function now() return _G.GetTime and _G.GetTime() or (debugprofilestop() / 1000) end

-- ============================ Timer handles ===============================
local function make_handle(id)
  local h = { id=id, _cancelled=false }
  function h:Cancel() self._cancelled = true end
  return h
end

-- scheduled entry: {time=nextFire, interval=0 or >0, fn=, args=, handle=, anchor=startTime, maxLate}
local _nextId = 0
local function schedule(delay, repeatInterval, fn, args, opts)
  _nextId = _nextId + 1
  local anchor = now()
  local entry = {
    time = anchor + delay,
    interval = repeatInterval or 0,
    fn = fn, args = args or {},
    handle = make_handle(_nextId),
    anchor = anchor,
    maxLate = (opts and opts.maxLate) or 0.25,
    nowFire = (opts and opts.now) and true or false,
  }
  table.insert(T._driverTasks, entry)
  T._driver:Show()
  return entry.handle
end

-- ============================ Public API ==================================
function T:After(seconds, fn, ...)
  seconds = math.max(0, tonumber(seconds) or 0)
  return schedule(seconds, 0, fn, {...})
end

function T:Every(seconds, fn, opts)
  seconds = math.max(0.001, tonumber(seconds) or 0.001)
  local h = schedule(seconds, seconds, fn, {}, opts)
  if opts and opts.now then
    -- immediate fire is simulated by scheduling at (now), but still anchored
    -- we mark entry.nowFire; driver will invoke once instantly and then proceed anchored
    for i=#T._driverTasks,1,-1 do
      local e = T._driverTasks[i]
      if e.handle == h then e.time = now(); break end
    end
  end
  return h
end

-- Debounce / Throttle registries
T._debounce = T._debounce or {}   -- key -> handle
T._throttle = T._throttle or {}   -- key -> {next=t, queuedArgs=table, waiting=false}

function T:Debounce(key, interval, fn, ...)
  key = tostring(key or "")
  interval = math.max(0, tonumber(interval) or 0)
  local prev = T._debounce[key]
  if prev and prev.Cancel then prev:Cancel() end
  local args = {...}
  local h = self:After(interval, function()
    T._debounce[key] = nil
    local ok, err = pcall(fn, unpack(args))
    if not ok then clog("Debounce error: "..tostring(err), "error") end
  end)
  T._debounce[key] = h
  return h
end

function T:Throttle(key, interval, fn, ...)
  key = tostring(key or "")
  interval = math.max(0.001, tonumber(interval) or 0.001)
  local rec = T._throttle[key] or { next = 0, waiting=false, queuedArgs=nil }
  T._throttle[key] = rec
  local args = {...}
  local t = now()
  if t >= rec.next and not rec.waiting then
    rec.next = t + interval
    local ok, err = pcall(fn, unpack(args))
    if not ok then clog("Throttle error: "..tostring(err), "error") end
  else
    rec.queuedArgs = args
    if not rec.waiting then
      rec.waiting = true
      T:After(math.max(0, rec.next - t), function()
        rec.waiting = false
        local a = rec.queuedArgs; rec.queuedArgs = nil
        rec.next = now() + interval
        if a then
          local ok, err = pcall(fn, unpack(a))
          if not ok then clog("Throttle error: "..tostring(err), "error") end
        end
      end)
    end
  end
end

-- Microtasks
function T:Microtask(fn, ...)
  if type(fn) ~= "function" then return end
  T._microQ[#T._microQ+1] = { fn=fn, args={...} }
  T._driver:Show()
end

-- Coroutine Sleep
function T.Sleep(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  local co = coroutine.running()
  if not co then return end
  T._coWait[co] = now() + seconds
  return coroutine.yield("AIOS_Sleep")
end

-- =========================== Driver (OnUpdate) ============================
local function process_microtasks(budgetSec)
  local start = now()
  local count = 0
  while #T._microQ > 0 do
    local item = table.remove(T._microQ, 1)
    local ok, err = pcall(item.fn, unpack(item.args))
    if not ok then clog("Microtask error: "..tostring(err), "error") end
    count = count + 1
    if (now() - start) > budgetSec then break end
  end
end

local function process_coroutines()
  if not next(T._coWait) then return end
  local t = now()
  for co, wake in pairs(T._coWait) do
    if t >= wake then
      T._coWait[co] = nil
      local ok, err = coroutine.resume(co)
      if not ok then clog("Coroutine resume error: "..tostring(err), "error") end
    end
  end
end

local function process_timers()
  if #T._driverTasks == 0 then return end
  local t = now()
  local i = 1
  while i <= #T._driverTasks do
    local e = T._driverTasks[i]
    if e.handle._cancelled then
      table.remove(T._driverTasks, i)
    elseif t >= e.time then
      local ok, err = pcall(e.fn, unpack(e.args))
      if not ok then clog("Timer error: "..tostring(err), "error") end
      if e.interval and e.interval > 0 then
        -- drift-free: next tick = anchor + k*interval
        local k = math.floor((t - e.anchor) / e.interval) + 1
        e.time = e.anchor + k * e.interval
        -- clamp if we got too late
        if e.maxLate and e.maxLate > 0 and (e.time - t) < -e.maxLate then
          e.time = t + e.interval
          e.anchor = t -- reset anchor to avoid runaway catch-up
        end
        i = i + 1
      else
        table.remove(T._driverTasks, i)
      end
    else
      i = i + 1
    end
  end
end

T._driver:SetScript("OnUpdate", function(_, elapsed)
  process_timers()
  process_coroutines()
  process_microtasks(0.0015) -- ~1.5ms budget per frame for microtasks
  if #T._driverTasks == 0 and #T._microQ == 0 and not next(T._coWait) then
    T._driver:Hide()
  end
end)

-- Optional helper: run a function in a coroutine that can Sleep()
function T:RunCo(fn, ...)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co, ...)
  if not ok and err ~= "AIOS_Sleep" then
    clog("RunCo error: "..tostring(err), "error")
  end
end

-- Smoke tests (silent)
do
  local fired = 0
  T:Every(0.05, function() fired = fired + 1; if fired >= 3 then end end, { now=true })
  T:Debounce("x", 0.1, function() end)
  T:Throttle("y", 0.1, function() end)
  T:Microtask(function() local _=1 end)
end
