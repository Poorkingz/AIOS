--[[
AIOS_DebugCap (v1.0.0)
Author: Poorkingz
Project: https://www.curseforge.com/members/aios/projects
Website: https://aioswow.info/
Discord: https://discord.gg/JMBgHA5T
Support: support@aioswow.dev

Purpose:
  • In release builds, this module caps/clears AIOS.Debug ring buffers to minimize memory usage.
  • Runs automatically at PLAYER_LOGIN.
  • Safe: no output. Does nothing if AIOS.Debug is not loaded.

API Functions:
  (none public) – this file only provides automated cleanup logic.

Developer Notes:
  • Recommended for release: keep unloaded unless in AIOS_Dev.
  • Will silently cap logs at login for performance.
  • Future extensibility: Add hooks into DebugLog or allow custom ring-size values.
]]

local _G = _G
local AIOS = _G.AIOS or {}

local function cap()
  local D = AIOS and AIOS.Debug
  if not D then return end

  -- Preferred API: ring size setter
  if type(D.SetRingSize) == "function" then
    pcall(function() D:SetRingSize(0) end)
  end

  -- Clear common buffers if present
  if type(D.buffer) == "table" then
    for k in pairs(D.buffer) do D.buffer[k] = nil end
  end
  if type(D.logs) == "table" then
    for k in pairs(D.logs) do D.logs[k] = nil end
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() cap() end)
