--[[
AIOS_SVInspector.lua — Snapshot AIOS.Saved and export via CopyBox
(Backdrop-safe version)
]]--
local _G=_G
AIOS=_G.AIOS or {}

local function Dlog(level, tag, msg) if AIOS and AIOS.Debug and AIOS.Debug.Log then AIOS.Debug:Log(level or "info", tag or "SVInspector", msg) end end

local function templateBackdrop() return _G.BackdropTemplateMixin and "BackdropTemplate" or nil end
local function SafeSkinFrame(f)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface/Tooltips/UI-Tooltip-Border",edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
    f:SetBackdropColor(0,0,0,1); f:SetBackdropBorderColor(0.1,0.6,1,0.9)
  end
end

local function open_copy(text)
  if _G.AIOS_CopyBox and _G.AIOS_CopyBox.Open then _G.AIOS_CopyBox.Open(text) return end
  local f=CreateFrame("Frame","AIOS_SVInspectorCopy",UIParent, templateBackdrop())
  f:SetSize(600,360); f:SetPoint("CENTER"); SafeSkinFrame(f)
  local scroll=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate"); scroll:SetPoint("TOPLEFT",12,-12); scroll:SetPoint("BOTTOMRIGHT",-12,12)
  if scroll.ScrollBar then scroll.ScrollBar:Hide(); scroll.ScrollBar.Show=function() end end
  local edit=CreateFrame("EditBox",nil,scroll); edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal or SystemFont_Shadow_Med1); edit:SetAutoFocus(false); edit:SetWidth(560); edit:SetText(tostring(text or "")); scroll:SetScrollChild(edit); f:Show()
end

local function short(v)
  local t=type(v)
  if t=="string" then if #v>60 then return string.format("%q…", v:sub(1,57)) end return string.format("%q", v) end
  if t=="number" or t=="boolean" or t=="nil" then return tostring(v) end
  return "["..t.."]"
end

local function dump_table(t, depth, maxDepth, seen, lines, prefix)
  if depth>maxDepth then lines[#lines+1]=prefix.."..."; return end
  seen = seen or {}
  if seen[t] then lines[#lines+1]=prefix.."<cycle>" return end
  seen[t]=true

  local keys = {}
  for k in pairs(t) do keys[#keys+1]=k end
  table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)

  for _,k in ipairs(keys) do
    local v = t[k]; local kt = tostring(k)
    if type(v)=="table" then
      lines[#lines+1]=prefix..kt.." = {"
      dump_table(v, depth+1, maxDepth, seen, lines, prefix.."  ")
      lines[#lines+1]=prefix.."}"
    else
      lines[#lines+1]=prefix..kt.." = "..short(v)
    end
  end
end

local function snapshot_saved()
  local SV = AIOS and AIOS.Saved
  local lines = {}
  if not SV then
    lines[#lines+1]="(AIOS.Saved not available)"
  else
    lines[#lines+1]="AIOS.Saved snapshot:"
    dump_table(SV, 1, 3, {}, lines, "")
  end
  return table.concat(lines, "\n")
end

_G.SLASH_AIOSSV1="/aiossv"
SlashCmdList["AIOSSV"]=function() open_copy(snapshot_saved()) end

Dlog("info","SVInspector","Ready. Use /aiossv")
