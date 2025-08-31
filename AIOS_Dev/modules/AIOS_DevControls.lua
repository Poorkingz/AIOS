--[[
AIOS_DevControls.lua — Headless dev controls (no menu, zero chat spam)
Version: 1.0
Path: modules/AIOS_DevControls.lua

Slash: /aiosctl
  dbg on|off|toggle
  lvl debug|info|warn|error
  size <n>            -- debug ring buffer size
  export              -- dumps logs to AIOS_CopyBox (if available), else temp frame
  clear               -- clears logs
  test                -- opens QA tester or triggers its toggle
--]]

local _G = _G
AIOS = _G.AIOS or {}

local function dlog(lvl, tag, msg)
  if AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log(lvl, tag, msg)
  end
end

local function parse_args(msg)
  local t = {}
  for w in tostring(msg or ""):gmatch("%S+") do t[#t+1] = w end
  return t
end

-- optional tiny feedback (kept off to avoid chat spam)
local QUIET = true
local function feedback(txt)
  if not QUIET then _G.print("|cff66ccffAIOS|r "..tostring(txt)) end
  dlog("info", "DevCtl", txt)
end

local function set_debug_enabled(on)
  local D = AIOS.Debug
  if not D then return end
  if on then D:Enable() else D:Disable() end
  feedback("Debug "..(on and "ON" or "OFF"))
end

local function set_debug_level(lvl)
  local D = AIOS.Debug
  if not D then return end
  D:SetLevel(lvl)
  feedback("Debug level -> "..tostring(lvl))
end

local function set_buffer_size(n)
  local D = AIOS.Debug
  if not D then return end
  n = tonumber(n or 0) or 0
  if n < 100 then n = 100 end
  if n > 10000 then n = 10000 end
  D._max = n
  feedback("Log buffer size -> "..n)
end

local function export_logs_via_copybox(text)
  -- Prefer AIOS_CopyBox if available
  if _G.AIOS_CopyBox and _G.AIOS_CopyBox.Open then
    _G.AIOS_CopyBox.Open(text)
    return true
  end
  -- Fallback minimal viewer
  local f = CreateFrame("Frame", "AIOS_LogExportFrame", UIParent, "BackdropTemplate")
  f:SetSize(700, 420); f:SetPoint("CENTER")
  f:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8x8",
                  edgeFile="Interface/Tooltips/UI-Tooltip-Border", edgeSize=16,
                  insets={left=4,right=4,top=4,bottom=4} })
  f:SetBackdropColor(0,0,0,1); f:SetBackdropBorderColor(0.1,0.6,1,0.9)
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -12); scroll:SetPoint("BOTTOMRIGHT", -12, 12)
  if scroll.ScrollBar then scroll.ScrollBar:Hide(); scroll.ScrollBar.Show=function() end end
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal or SystemFont_Shadow_Med1)
  edit:SetAutoFocus(false); edit:SetWidth(660); edit:SetText(text or ""); edit:HighlightText(0,0)
  scroll:SetScrollChild(edit)
  f:Show()
  return true
end

local function export_logs()
  if not (AIOS.Debug and AIOS.Debug.Export) then return end
  local text = AIOS.Debug:Export() or ""
  export_logs_via_copybox(text)
  feedback("Logs exported")
end

local function clear_logs()
  if AIOS.Debug and AIOS.Debug.Clear then AIOS.Debug:Clear() end
  feedback("Logs cleared")
end

local function run_tests()
  -- Toggle QA window via its slash handler if present
  if _G.SlashCmdList and _G.SlashCmdList["AIOSTEST"] then
    _G.SlashCmdList["AIOSTEST"]()
    feedback("QA window toggled")
    return
  end
  feedback("QA tester not loaded")
end

-- ---------------- slash dispatcher ----------------
_G.SLASH_AIOSCTL1 = "/aiosctl"
SlashCmdList["AIOSCTL"] = function(msg)
  local args = parse_args(msg)
  local sub = (args[1] or ""):lower()
  if sub == "dbg" then
    local v = (args[2] or ""):lower()
    if v == "on" then set_debug_enabled(true)
    elseif v == "off" then set_debug_enabled(false)
    else
      local cur = AIOS.Debug and AIOS.Debug:IsEnabled()
      set_debug_enabled(not cur)
    end
  elseif sub == "lvl" or sub == "level" then
    local lvl = (args[2] or "debug"):lower()
    set_debug_level(lvl)
  elseif sub == "size" then
    set_buffer_size(args[2])
  elseif sub == "export" then
    export_logs()
  elseif sub == "clear" then
    clear_logs()
  elseif sub == "test" then
    run_tests()
  else
    feedback("Usage: /aiosctl dbg on|off|toggle | lvl <debug|info|warn|error> | size <n> | export | clear | test")
  end
end

dlog("info", "DevCtl", "AIOS_DevControls ready. Use /aiosctl")
