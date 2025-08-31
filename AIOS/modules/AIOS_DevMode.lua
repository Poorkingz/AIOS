--[[
AIOS_DevMode.lua — Master DevMode Switch
Version: 1.0
Author: Poorkingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.info/
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev

Description:
Controls whether AIOS developer tools (AIOS_Dev) are enabled. Provides persistence,
load-on-demand activation, and slash command access.

API:
  AIOS.DevMode:IsEnabled() → bool
  AIOS.DevMode:SetEnabled(v: bool)

Slash Commands (/aiosdev):
  on       – Enable DevMode and load AIOS_Dev
  off      – Disable DevMode (requires /reload to fully unload)
  status   – Show current DevMode status
  reload   – Reload the UI
--]]

local _G = _G
AIOS = _G.AIOS or {}

local SCHEMA = "CoreDevMode"
local defaults = { enabled = false }
local ADDON_NAME = "AIOS_Dev"

local function chat(msg)
  local f = _G.DEFAULT_CHAT_FRAME
  if f and f.AddMessage then f:AddMessage("|cff66ccffAIOS DevMode|r: "..tostring(msg)) end
end

local function dlog(level, tag, msg)
  if AIOS and AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log(level or "info", tag or "DevMode", msg)
  end
end

local function ensure_schema()
  local SV = AIOS and AIOS.Saved
  if SV and SV.RegisterSchema then
    pcall(function() SV:RegisterSchema(SCHEMA, defaults, { scope="profile", version=1 }) end)
  end
end

local function get_enabled_flag()
  local SV = AIOS and AIOS.Saved
  if SV and SV.Get then
    local v = SV:Get(SCHEMA, "enabled")
    if v == nil then v = defaults.enabled end
    return not not v
  end
  return defaults.enabled
end

local function set_enabled_flag(v)
  local SV = AIOS and AIOS.Saved
  if SV and SV.Set then SV:Set(SCHEMA, "enabled", not not v) end
end

local function is_loaded()
  if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
    return _G.C_AddOns.IsAddOnLoaded(ADDON_NAME)
  elseif _G.IsAddOnLoaded then
    return _G.IsAddOnLoaded(ADDON_NAME)
  end
  return false
end

local function info_by_name()
  -- Try modern API first
  if _G.C_AddOns and _G.C_AddOns.GetAddOnInfo then
    local info = _G.C_AddOns.GetAddOnInfo(ADDON_NAME)
    if info then
      return {
        name = info.name,
        title = info.title,
        notes = info.notes,
        loadable = info.loadable,
        reason = info.reason,
        -- 'enabled' may not be present on some builds
        enabled = info.enabled,
      }
    end
  end
  -- Legacy tuple API
  if _G.GetAddOnInfo then
    local name, title, notes, enabled, loadable, reason = _G.GetAddOnInfo(ADDON_NAME)
    return {
      name=name, title=title, notes=notes,
      enabled=enabled, loadable=loadable, reason=reason
    }
  end
  return {}
end

local function derive_enabled()
  -- Prefer reported enabled flag
  local inf = info_by_name()
  if inf.enabled ~= nil then return inf.enabled end

  -- Fallback to *EnableState if available
  local state
  if _G.C_AddOns and _G.C_AddOns.GetAddOnEnableState then
    local who = (_G.UnitName and _G.UnitName("player")) or nil
    local ok, val = pcall(_G.C_AddOns.GetAddOnEnableState, who, ADDON_NAME)
    state = ok and val or nil
  elseif _G.GetAddOnEnableState then
    local who = (_G.UnitName and _G.UnitName("player")) or nil
    local ok, val = pcall(_G.GetAddOnEnableState, who, ADDON_NAME)
    state = ok and val or nil
  end
  if type(state)=="number" then
    -- 0 = disabled, 1 = enabled for all, 2 = enabled for character
    return state ~= 0
  end

  -- Unknown
  return nil
end

local function derive_loadable()
  -- Prefer reported loadable flag
  local inf = info_by_name()
  if inf.loadable ~= nil then return inf.loadable end

  -- Fallback API
  local ok, val
  if _G.C_AddOns and _G.C_AddOns.IsAddOnLoadOnDemand then
    ok, val = pcall(_G.C_AddOns.IsAddOnLoadOnDemand, ADDON_NAME)
  elseif _G.IsAddOnLoadOnDemand then
    ok, val = pcall(_G.IsAddOnLoadOnDemand, ADDON_NAME)
  end
  if ok then return not not val end
  return nil
end

local function derive_reason()
  local inf = info_by_name()
  if inf.reason ~= nil then return inf.reason end
  return nil
end

local function try_enable()
  if _G.C_AddOns and _G.C_AddOns.EnableAddOn then
    _G.C_AddOns.EnableAddOn(ADDON_NAME); return true
  elseif _G.EnableAddOn then
    _G.EnableAddOn(ADDON_NAME); return true
  end
  return false
end

local function do_load_raw()
  if _G.C_AddOns and _G.C_AddOns.LoadAddOn then
    return _G.C_AddOns.LoadAddOn(ADDON_NAME)  -- returns loaded(bool), reason(string|nil)
  elseif _G.LoadAddOn then
    return _G.LoadAddOn(ADDON_NAME)           -- returns loaded(bool), reason(string|nil)
  else
    return false, "API_UNAVAILABLE"
  end
end

local function load_dev_addon()
  if is_loaded() then return true end

  -- Try to ensure enabled first
  try_enable()

  local ok, loaded, why = pcall(do_load_raw)
  if not ok then
    local emsg = tostring(loaded)
    dlog("error","DevMode","LoadAddOn pcall failed: "..emsg)
    chat("Failed to load AIOS_Dev: "..emsg)
    return false
  end

  if not loaded then
    why = tostring(why or "UNKNOWN")
    dlog("warn","DevMode","LoadAddOn did not load: "..why)
    if why == "ADDON_MISSING" then
      chat("Not found. Ensure folder is Interface/AddOns/AIOS_Dev/AIOS_Dev.toc")
    elseif why == "ADDON_DISABLED" then
      chat("Disabled. Enable it on the AddOns screen and /reload.")
    else
      chat("Could not load ("..why.."). Check TOC and dependencies.")
    end
    return false
  end

  dlog("info","DevMode","Loaded AIOS_Dev")
  chat("Loaded AIOS_Dev")
  return true
end

AIOS.DevMode = AIOS.DevMode or {}
function AIOS.DevMode:IsEnabled() return get_enabled_flag() end
function AIOS.DevMode:SetEnabled(v)
  set_enabled_flag(v)
  dlog("info","DevMode","DevMode -> "..(v and "ON" or "OFF"))
  chat("DevMode "..(v and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
  if v then load_dev_addon() end
end

-- lifecycle
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, evt)
  if evt == "ADDON_LOADED" then
    ensure_schema()
  elseif evt == "PLAYER_LOGIN" then
    if get_enabled_flag() then C_Timer.After(0.2, load_dev_addon) end
  end
end)

-- slash
_G.SLASH_AIOSDEV1 = "/aiosdev"
SlashCmdList["AIOSDEV"] = function(msg)
  msg = tostring(msg or ""):lower()
  if msg == "on" then
    AIOS.DevMode:SetEnabled(true)
  elseif msg == "off" then
    AIOS.DevMode:SetEnabled(false)
    dlog("info","DevMode","Turned OFF. /reload to fully unload dev tools.")
    chat("Turned OFF. /reload to fully unload dev tools.")
  elseif msg == "status" then
    local on = AIOS.DevMode:IsEnabled()
    local loaded = is_loaded()
    local enabled = derive_enabled()
    local loadable = derive_loadable()
    local reason = derive_reason()
    local function v(x) if x==nil then return "?" elseif type(x)=="boolean" then return x and "true" or "false" else return tostring(x) end end
    chat(string.format("Status: %s | loaded:%s | enabled:%s | loadable:%s | reason:%s",
      on and "ON" or "OFF", v(loaded), v(enabled), v(loadable), v(reason)))
  elseif msg == "reload" then
    if _G.ReloadUI then _G.ReloadUI() end
  else
    chat("Usage: /aiosdev on|off|status|reload")
  end
end
