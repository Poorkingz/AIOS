--[[
AIOS_RuntimeProfile.lua — Runtime Memory & Lean Controls
Version: 1.0.0
Author: Poorkingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website: https://aioswow.info/
Discord: https://discord.gg/JMBgHA5T
Support: support@aioswow.dev

Description:
  Provides runtime profiling and memory management tools for AIOS.
  Includes slash commands for memory inspection, garbage collection,
  and toggling Lean mode.

API / Slash Commands:
  /aiosmem     - Print current AIOS memory usage (with delta).
  /aiosgc      - Force garbage collection and print memory usage after GC.
  /aioslean on - Enable Lean mode (trims config schemas).
  /aioslean off- Disable Lean mode (stops trims).
--]]

local _G = _G
local AIOS = _G.AIOS or {}; _G.AIOS = AIOS

local last = nil

local function kb(v) return string.format("%.1f KB", v) end

local function currentAddonKB(name)
  UpdateAddOnMemoryUsage()
  local n = name or "AIOS"
  local bytes = GetAddOnMemoryUsage(n) or 0
  return bytes
end

local function printMem(prefix)
  local b = currentAddonKB("AIOS")
  local diff = last and (b - last) or 0
  last = b
  local line = string.format("%s %s (Δ %s)", prefix or "", kb(b), kb(diff))
  if AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log("info", "Mem", line)
  else
    DEFAULT_CHAT_FRAME:AddMessage("[AIOS] "..line)
  end
end

SLASH_AIOSMEM1 = "/aiosmem"
SlashCmdList["AIOSMEM"] = function()
  printMem("AddOn memory:")
end

SLASH_AIOSGC1 = "/aiosgc"
SlashCmdList["AIOSGC"] = function()
  collectgarbage(); collectgarbage()
  printMem("After GC:")
end

SLASH_AIOSLEAN1 = "/aioslean"
SlashCmdList["AIOSLEAN"] = function(msg)
  local arg = (msg or ""):lower():match("^%s*(%S*)")
  AIOS.Lean = AIOS.Lean or { enabled = true }
  if arg == "off" then
    AIOS.Lean.enabled = false
    if AIOS.Debug and AIOS.Debug.Log then AIOS.Debug:Log("info","Mem","Lean: OFF") end
    DEFAULT_CHAT_FRAME:AddMessage("[AIOS] Lean mode OFF (no further trims)")
  elseif arg == "on" then
    AIOS.Lean.enabled = true
    DEFAULT_CHAT_FRAME:AddMessage("[AIOS] Lean mode ON — applying trims now")
    if AIOS.Config and AIOS.Config._schemas then
      for k in pairs(AIOS.Config._schemas) do AIOS.Config._schemas[k] = nil end
    end
  else
    DEFAULT_CHAT_FRAME:AddMessage("[AIOS] /aioslean on|off")
  end
end

-- IMPORTANT: No automatic post-login print.
