--[[
AIOS — Advanced Interface Operating System
File: AIOS_Console.lua
Version: 1.0.0
Author: Poorkingz
License: MIT

Project Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Email: support@aioswow.dev

Purpose:
  - Provides a unified developer console for AIOS with slash commands (/aiosc, /ai).
  - Lets devs query modules, check versions, emit events, and debug AIOS easily.
  - Extensible via new handlers or future Console:RegisterCommand API.

API Reference:
  - Console:Summary() → string
      Returns version + interface + module count summary.

  - Slash Commands (/aiosc, /ai):
      • help() → Show available commands.
      • modules() → List all registered AIOS modules with versions.
      • version() → Print AIOS core version, interface, and build info.
      • ping() → Emit "AIOS_PING" through EventBus.

Integration:
  - Registered with AIOS.ServiceRegistry as "Console".
  - Console object is added to AIOS.Modules for discovery.
  - Emits events usable by other modules (ex: DevPing).

Notes:
  - Lightweight, safe for release.
  - Compatible with Retail 11.2.x, Classic Era 1.15.x, and MoP Classic 5.4.x.
--]]

local ADDON, AIOS = ...
if not AIOS then return end

local Console = {}
Console.__index = Console

local PREFIX = "|cff00aaff[AIOS]|r "  -- Blizzard blue-ish
local function say(msg) print(PREFIX .. (msg or "")) end

local function safe(t, k, default)
  local v = t and t[k]
  if v == nil then return default end
  return v
end

-- Optional: expose a tiny summary for other modules
function Console:Summary()
  local v = safe(AIOS, "__version", "1.0.0")
  local i = safe(AIOS, "__interface", "110200")
  local m = AIOS and AIOS.Modules and #AIOS.Modules or 0
  return ("AIOS v%s (IF:%s), %d modules"):format(v, i, m)
end

-- Command handlers
local handlers = {}

handlers.help = function()
  say("Console  (/aiosc <cmd>)")
  say("|cffffffffhelp|r     - Show this help")
  say("|cffffffffmodules|r  - List core modules")
  say("|cffffffffversion|r  - Show core/version info")
  say("|cffffffffping|r     - Emit 'AIOS_PING' on EventBus (for DevPing etc.)")
end

handlers.modules = function()
  if not (AIOS and AIOS.Modules) or #AIOS.Modules == 0 then
    say("No modules registered yet.")
    return
  end
  say("Modules:")
  for i, mod in ipairs(AIOS.Modules) do
    local name = mod and (mod.__name or mod.Name or ("Module" .. i)) or ("Module" .. i)
    local ver  = mod and (mod.__version or mod.Version or "")
    if ver ~= "" then
      say(("- %s |cffa0a0a0(v%s)|r"):format(name, ver))
    else
      say(("- %s"):format(name))
    end
  end
end

handlers.version = function()
  local v  = safe(AIOS, "__version", "1.0.0")
  local iv = safe(AIOS, "__interface", "110200")
  local bn = safe(AIOS, "__build", "release")
  say(("Core v%s (Interface %s, build %s)"):format(v, iv, bn))
end

handlers.ping = function()
  say("Ping → Emitting AIOS_PING")
  if AIOS.EventBus and AIOS.EventBus.Emit then
    pcall(AIOS.EventBus.Emit, AIOS.EventBus, "AIOS_PING", { ts = GetTimePreciseSec and GetTimePreciseSec() or GetTime() })
  end
end

-- Slash setup
local function run_cmd(txt)
  local cmd, rest = txt:match("^(%S+)%s*(.-)$")
  cmd = (cmd or "help"):lower()
  local fn = handlers[cmd] or handlers.help
  fn(rest)
end

SlashCmdList["AIOSC"] = run_cmd
SLASH_AIOSC1 = "/aiosc"
SLASH_AIOSC2 = "/ai"

-- Register in ServiceRegistry (optional, but nice)
if AIOS.ServiceRegistry and AIOS.ServiceRegistry.Register then
  AIOS.ServiceRegistry:Register("Console", Console)
end

-- Keep a minimal module table for listing
Console.__name = "Console"
Console.__version = "1.0.0"
AIOS.Modules = AIOS.Modules or {}
table.insert(AIOS.Modules, Console)
