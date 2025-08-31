--[[
AIOS Locale API
Version: 1.0
Author: Poorkingz
Links: 
  CurseForge - https://www.curseforge.com/members/aios/projects
  Website    - https://aioswow.info/
  Discord    - https://discord.gg/JMBgHA5T
  Support    - support@aioswow.dev

Purpose:
Ultra-light translation engine for AIOS and addons. 
Per-namespace locale tables with runtime switch. 
Fallback to key if missing. Silent unless debug enabled.

-------------------------------------------------------------------
Public API:

Locale:New(namespace) : L  
  - Creates a new locale namespace.  
  - Returns a callable table `L` that acts as translator.

L(key[, args]) : string  
  - Translate `key` in the active locale.  
  - Supports {placeholders} replaced with args.  
  - Falls back to `key` if no translation.

L:NewLocale(locale[, isDefault]) : dict  
  - Defines a new locale table for this namespace.  
  - `isDefault = true` sets fallback locale.  
  - Returns the dict for populating key/value pairs.

L:SetActive(locale) : success  
  - Sets the active locale if available.  
  - Returns true on success, false if no table exists.

L:n(singularKey, pluralKey, n[, args]) : string  
  - Pluralization helper. Uses singular if n == 1, else plural.  

L:GetDict(locale) : dict  
  - Returns raw locale table for a given locale (read-only suggested).  

-------------------------------------------------------------------
Metrics:
Locale._metrics.lookups : number  
Locale._metrics.misses  : number  
  - Counts lookups vs. misses for debug/analysis.  

-------------------------------------------------------------------
Usage Example:

local L = AIOS.Locale:New("MyAddon")
local en = L:NewLocale("enUS", true)
en["HELLO"] = "Hello {name}!"

L:SetActive("enUS")
print(L("HELLO", { name="Poorkingz" }))  -- "Hello Poorkingz!"
--]]

local _G = _G
local AIOS = _G.AIOS or {}; _G.AIOS = AIOS

local Locale = rawget(AIOS, "Locale") or {}
AIOS.Locale = Locale

-- local logger (silent unless Debug enabled)
local function log(level, tag, msg)
  if AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log(level or "info", tag or "Locale", msg)
  end
end

-- Internal state: ns -> { active="enUS", dict = { localeCode -> table } }
Locale._ns = Locale._ns or {}

local function getActive(nsrec)
  local active = nsrec.active or GetLocale() or "enUS"
  return nsrec.dict[active] or nsrec.dict["enUS"]
end

local function fmt(template, args)
  if type(template) ~= "string" or type(args) ~= "table" then return template end
  return (template:gsub("{([%w_]+)}", function(k)
    local v = args[k]
    if v == nil then return "{"..k.."}" end
    return tostring(v)
  end))
end

-- Public API ------------------------------------------------------------

function Locale:New(namespace)
  assert(type(namespace) == "string" and namespace ~= "", "Locale:New requires a namespace")
  local nsrec = self._ns[namespace]
  if not nsrec then
    nsrec = { active = nil, dict = {} }
    self._ns[namespace] = nsrec
  end

  local L = {}

  -- Provide a callable table to translate keys
  setmetatable(L, {
    __call = function(_, key, args)
      local dict = getActive(nsrec)
      local s = (dict and dict[key]) or key
      if type(s) ~= "string" then return key end
      return fmt(s, args)
    end
  })

  function L:NewLocale(locale, isDefault)
    assert(type(locale) == "string" and locale ~= "", "NewLocale: locale required")
    local t = nsrec.dict[locale]
    if not t then
      t = setmetatable({}, { __index = function(_, k) return k end })
      nsrec.dict[locale] = t
    end
    if isDefault then nsrec.default = locale end
    return t
  end

  function L:SetActive(locale)
    if nsrec.dict[locale] then
      nsrec.active = locale
      return true
    else
      log("warn", "Locale", "SetActive failed (no dict for "..tostring(locale)..")")
      return false
    end
  end

  -- Simple plural helper (English-like; allow override via custom keys).
  function L:n(singularKey, pluralKey, n, args)
    if tonumber(n) == 1 then
      return L(singularKey, args)
    else
      return L(pluralKey, args)
    end
  end

  -- Expose raw table (read-only suggested) in case devs need to populate
  function L:GetDict(locale)
    return nsrec.dict[locale]
  end

  return L
end

-- Metrics (lightweight)
Locale._metrics = Locale._metrics or { lookups = 0, misses = 0 }
do
  local oldNew = Locale.New
  Locale.New = function(self, namespace)
    local L = oldNew(self, namespace)
    local mt = getmetatable(L)
    local callOld = mt.__call
    mt.__call = function(t, key, args)
      self._metrics.lookups = (self._metrics.lookups or 0) + 1
      local dict = self._ns[namespace]; dict = dict and (dict.dict[dict.active or GetLocale()] or dict.dict["enUS"])
      local has = dict and dict[key]
      if not has then self._metrics.misses = (self._metrics.misses or 0) + 1 end
      return callOld(t, key, args)
    end
    return L
  end
end

-- No return; module mutates AIOS.Locale
