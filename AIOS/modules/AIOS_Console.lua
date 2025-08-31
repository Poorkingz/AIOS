--[[ 
AIOS_Console.lua  
Version: 1.0.0  
Author: Poorkingz  
Links:  
  • CurseForge: https://www.curseforge.com/members/aios/projects  
  • Website: https://aioswow.info/  
  • Discord: https://discord.gg/JMBgHA5T  
  • Support: support@aioswow.dev  

Description:  
The AIOS Console provides a central developer console with slash commands 
(/aiosc, /ai) for interacting with the AIOS ecosystem. It’s lightweight, 
safe for release, and extensible for module developers.

============================================================
Available API Functions
============================================================

Console Commands (via /aiosc or /ai):
  • help()  
    → Prints available commands.  

  • modules()  
    → Lists all registered AIOS modules and their versions.  

  • ping()  
    → Emits an "AIOS_PING" event through the EventBus and confirms in chat.  

  • version()  
    → Prints the AIOS core version currently running.  

Internal Functions:
  • handlers[name](args)  
    → Lookup table of console commands. Developers can extend this by 
      adding entries directly or (future) via Console:RegisterCommand().  

  • Console:Summary()  
    → Returns formatted version + module list (for logging or UI).  

Integration:
  • Registered with AIOS.Services as "Console".  
  • Emits EventBus signals for "AIOS_PING".  
  • Supports extension by other modules through handlers or future 
    RegisterCommand API.  

============================================================
Release Readiness
============================================================
✔ Works on Retail (11.2.x), Classic Era (1.15.x), and MoP Classic (5.4.x).  
✔ Minimal CPU/memory usage.  
✔ Safe for public release.  
============================================================
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
