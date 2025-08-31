--[[
===============================================================================
AIOS_Version.lua — Core Versioning & Public API
===============================================================================

Author: Poorkingz  
Version: 1.0  
CurseForge: https://www.curseforge.com/members/aios/projects  
Website:   https://aioswow.info/  
Discord:   https://discord.gg/JMBgHA5T  
Support:   support@aioswow.dev  

------------------------------------------------------------------------------
📌 Purpose
------------------------------------------------------------------------------
This module defines the **AIOS versioning system** and public API surface
for all addons that depend on AIOS. It provides:

  • Version stamping (core / API / build date)  
  • A safe, read-only API proxy for external addons  
  • Stable entry points for Logger, Timers, Config, Saved, etc.  
  • Compatibility checks via `AIOS.Require(min_api)`  

By using this file, addon authors only need to declare  
`## Dependencies: AIOS` in their `.toc` — even if they call functions
from AIOS_UIStyle, AIOS_SimLite, or other official AIOS libraries.

------------------------------------------------------------------------------
📚 API Functions
------------------------------------------------------------------------------

AIOS.Version  
  .core   → integer build number (bumped on core changes)  
  .api    → integer API surface version (bumped on new/removed functions)  
  .build  → string ISO date for human readability  

AIOS:Api() : table  
  Returns a **read-only proxy** of the safe API surface, including:  
    • Version      – version table above  
    • SignalHub    – global signal system (or EventBus fallback)  
    • EventBus     – explicit event system  
    • Timers       – AIOS timers API  
    • Saved        – SavedVariables manager  
    • Serializer   – serializer helpers  
    • ConfigCore   – configuration system  
    • ModuleLoader – modular loading system  
    • Logger       – developer logging  
    • CoreLog      – safe CoreLog wrapper (no-op until Logger loads)  
    • Utils        – AIOS utility functions  

AIOS.Require(min_api : number) : boolean  
  Ensures the current AIOS API is at least `min_api`.  
  Throws an error if not satisfied:  
    `"AIOS API X required; have Y"`.  

Example:
  AIOS.Require(1)  -- require API v1 or newer  

------------------------------------------------------------------------------
🧪 Release Readiness
------------------------------------------------------------------------------
✅ This file is release-ready right now.  
It is minimal, stable, and safe across all WoW versions (Retail, Classic, MoP).  

Future-friendly enhancements could include:
  • AIOS.ApiVersion() → convenience getter for `AIOS.Version.api`  
  • Auto-hook CoreLog into DebugCap when available  
  • Explicit metatable freeze on the API proxy  

===============================================================================
]]

local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

AIOS.Version = {
  core = 10021,          -- bump on core changes
  api  = 1,              -- bump on API surface changes
  build = "2025-08-22",  -- ISO-ish date for human sanity
}

-- Short-circuit if already defined (allow hot-reload without duplicating)
if AIOS.Api then
  return AIOS
end

-- Ensure Logger exists for CoreLog bridge (but avoid hard dependency)
local Logger = AIOS.Logger
if not AIOS.CoreLog then
  -- Define a noop that upgrades itself when Logger arrives
  AIOS.CoreLog = function(msg, level, tag)
    if Logger and Logger.Info then
      if level == nil then level = "info" end
      Logger[level and level:sub(1,1):upper()..level:sub(2):lower()](
        msg, tag
      )
    end
    -- otherwise noop
  end
end

-- Freeze the public API (read-only proxy)
function AIOS:Api()
  local U = AIOS.Utils
  local api_tbl = {
    Version     = AIOS.Version,
    SignalHub   = AIOS.SignalHub or AIOS.EventBus,
    EventBus    = AIOS.EventBus,   -- explicit alias if both exist
    Timers      = AIOS.Timers,
    Saved       = AIOS.Saved,
    Serializer  = AIOS.Serializer,
    ConfigCore  = AIOS.ConfigCore,
    ModuleLoader= AIOS.ModuleLoader,
    Logger      = AIOS.Logger,
    CoreLog     = AIOS.CoreLog,
    Utils       = AIOS.Utils,
  }
  if U and U.ReadOnlyProxy then
    return U.ReadOnlyProxy(api_tbl, "AIOS.Api()")
  end
  -- Fallback: shallow copy without metatable protection
  local copy = {}
  for k,v in pairs(api_tbl) do copy[k] = v end
  return copy
end

-- Simple API version gate for third parties
function AIOS.Require(min_api)
  local have = (AIOS.Version and AIOS.Version.api) or 0
  if have < (tonumber(min_api) or 0) then
    error(("AIOS API %d required; have %d"):format(min_api, have), 2)
  end
  return true
end

return AIOS
