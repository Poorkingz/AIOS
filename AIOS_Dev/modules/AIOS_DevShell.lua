--[[
AIOS_DevShell.lua — v3 (guild-style layout)
- Vertical buttons (left)
- Live log viewer (center) + command input box
- Top dropdown: pick Kernel or any AIOS plugin
- Right list: modules for selected target (best-effort)
- Footer matches AIOS Debug style
- Uses AIOS_UIStyles if present (header/lines)
- All actions reflect live in the embedded log
Slash: /aiosdevui
]]--

local _G=_G
AIOS=_G.AIOS or {}

local UI = AIOS and AIOS.UIStyle or nil
local function has(fn) return type(fn)=="function" end
local function Dlog(level, tag, msg) if AIOS and AIOS.Debug and AIOS.Debug.Log then AIOS.Debug:Log(level or "info", tag or "DevShell", msg) end end

-- Backdrop safety
local function tpl() return _G.BackdropTemplateMixin and "BackdropTemplate" or nil end
local function SkinBox(f)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface/Tooltips/UI-Tooltip-Border",edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
    f:SetBackdropColor(0,0,0,1); f:SetBackdropBorderColor(0.1,0.6,1,0.9)
  end
end

-- Lines + header/footer
local function header(frame, title)
  if UI and has(UI.ApplyStandardHeader) then pcall(function() UI:ApplyStandardHeader(frame, title or "AIOS Dev Suite") end)
  else
    local t = frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
    t:SetPoint("TOPLEFT", 14, -10); t:SetText(title or "AIOS Dev Suite")
  end
  local l = frame:CreateTexture(nil,"ARTWORK"); l:SetColorTexture(0.1,0.6,1.0,0.8); l:SetHeight(1)
  l:SetPoint("TOPLEFT",12,-44); l:SetPoint("TOPRIGHT",-12,-44)
end

local function footer(frame)
  local l = frame:CreateTexture(nil,"ARTWORK"); l:SetColorTexture(0.1,0.6,1.0,0.8); l:SetHeight(1)
  l:SetPoint("BOTTOMLEFT",12,32); l:SetPoint("BOTTOMRIGHT",-12,32)
  local left = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  left:SetPoint("BOTTOMLEFT", 14, 12); left:SetText("AIOS Dev Suite")
  local right = frame:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  right:SetPoint("BOTTOMRIGHT", -14, 12); right:SetText("powered by AIOS")
end

-- Data helpers
local function export_debug()
  if AIOS and AIOS.Debug and AIOS.Debug.Export then return AIOS.Debug:Export() end
  return "(AIOS.Debug not available)"
end

local function list_targets()
  local items = { {text="Kernel (AIOS)", value="__KERNEL"} }
  if AIOS and AIOS.Plugins then
    for name,_ in pairs(AIOS.Plugins) do table.insert(items, {text=name, value=name}) end
  end
  table.sort(items, function(a,b) return a.text<b.text end)
  return items
end

local function list_modules_for(target)
  local out = {}
  -- Adapters first
  if AIOS and AIOS.DevSuite and AIOS.DevSuite.Adapters and target and AIOS.DevSuite.Adapters[target] then
    local A = AIOS.DevSuite.Adapters[target]
    if type(A.ListFiles)=="function" then
      local ok, arr = pcall(A.ListFiles, A)
      if ok and type(arr)=="table" then
        for _,v in ipairs(arr) do table.insert(out, tostring(v)) end
      end
    end
  end
  -- ModuleLoader registry
  local REG = AIOS and AIOS.ModuleLoader and AIOS.ModuleLoader.Registry
  if REG and type(REG)=="table" then
    for name,info in pairs(REG) do
      local owner = (info and info.owner) or (info and info.plugin) or ""
      if target=="__KERNEL" then
        table.insert(out, tostring(name))
      else
        if owner==target or (type(name)=="string" and name:find(target)) then
          table.insert(out, tostring(name))
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- Embedded log
local LogView = { frame=nil, edit=nil, lastLen=0, ticker=nil }
local function log_refresh(force)
  if not LogView.edit then return end
  local txt = export_debug()
  if force or #txt ~= LogView.lastLen then
    LogView.edit:SetText(txt); LogView.lastLen=#txt
  end
end
local function log_start()
  if LogView.ticker then return end
  if _G.C_Timer and _G.C_Timer.NewTicker then
    LogView.ticker = _G.C_Timer.NewTicker(0.5, function() if LogView.frame and LogView.frame:IsShown() then log_refresh(false) end end)
  end
end
local function log_stop() if LogView.ticker then LogView.ticker:Cancel(); LogView.ticker=nil end end

-- Command execution
local function run_command(line)
  line = tostring(line or "")
  if line=="" then return end
  -- Prefer RunMacroText (executes slash commands safely)
  if _G.RunMacroText then _G.RunMacroText(line); return end
  -- Fallback: try slash table
  local cmd = line:match("^%s*/(%S+)")
  if cmd and _G.SlashCmdList then
    local key = cmd:upper()
    local fn = _G.SlashCmdList[key]
    if type(fn)=="function" then
      local rest = line:gsub("^%s*/%S+%s*", "")
      fn(rest)
    end
  end
end

-- Actions
local function act_debug_on() if AIOS and AIOS.Debug and AIOS.Debug.Enable then AIOS.Debug:Enable(); log_refresh(true) else run_command("/aiosdbg") end end
local function act_debug_off() if AIOS and AIOS.Debug and AIOS.Debug.Disable then AIOS.Debug:Disable(); log_refresh(true) end end
local function act_trace_all() run_command("/aiostrace on *"); log_refresh(true) end
local function act_trace_off() run_command("/aiostrace off"); log_refresh(true) end
local function act_qatest() run_command("/aiostest"); log_refresh(true) end
local function act_bench() run_command("/aiosbench"); log_refresh(true) end
local function act_tracer_diag() run_command("/aiostrace diag"); log_refresh(true) end
local function act_export() local txt=export_debug(); if _G.AIOS_CopyBox and _G.AIOS_CopyBox.Open then _G.AIOS_CopyBox.Open(txt) end end
local function act_popout() run_command("/aiosdbg") end

-- UI Build
local DevShell = { _frame=nil, _dropdown=nil, _rightList=nil, _rightChildren={} }
AIOS.DevShell = DevShell

local function clear_right(parent)
  for _,c in ipairs(DevShell._rightChildren) do if c and c.Hide then c:Hide() end end
  DevShell._rightChildren = {}
end

local function fill_right(parent, items)
  clear_right(parent)
  local y = -76
  for i,txt in ipairs(items) do
    local fs = parent:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    fs:SetPoint("TOPRIGHT", -18, y); fs:SetJustifyH("RIGHT"); fs:SetText(txt)
    y = y - 18
    table.insert(DevShell._rightChildren, fs)
  end
end

local function refresh_lists()
  if not DevShell._frame then return end
  local sel = DevShell._selected or "__KERNEL"
  local items = list_modules_for(sel)
  fill_right(DevShell._frame, items)
end

local function on_select_target(value, text)
  DevShell._selected = value
  Dlog("info","DevShell","Target -> "..tostring(text))
  refresh_lists()
end

local function build_dropdown(parent)
  local dd = CreateFrame("Frame", "AIOS_DevShell_Dropdown", parent, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", 16, -58)
  local function init(self, level, menuList)
    local data = list_targets()
    for _,it in ipairs(data) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = it.text
      info.arg1 = it.value
      info.func = function(_, val) UIDropDownMenu_SetText(dd, it.text); on_select_target(val, it.text) end
      info.checked = (DevShell._selected or "__KERNEL") == it.value
      UIDropDownMenu_AddButton(info)
    end
  end
  UIDropDownMenu_Initialize(dd, init)
  UIDropDownMenu_SetWidth(dd, 180)
  UIDropDownMenu_SetText(dd, "Kernel (AIOS)")
  DevShell._dropdown = dd
end

local function makeBtn(parent, x, y, label, onclick)
  local b=CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(140,22); b:SetPoint("TOPLEFT", x, y); b:SetText(label); b:SetScript("OnClick", onclick)
  return b
end

local function build()
  if DevShell._frame then return DevShell._frame end
  local f=CreateFrame("Frame","AIOS_DevShell",UIParent,tpl())
  f:SetSize(920,560); f:SetPoint("CENTER"); SkinBox(f); f:SetFrameStrata("DIALOG"); f:Hide()
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)

  header(f,"AIOS Dev Suite"); footer(f)

  build_dropdown(f)

  -- Left vertical buttons
  local x, y = 18, -90
  makeBtn(f, x, y, "Debug ON", act_debug_on); y=y-26
  makeBtn(f, x, y, "Debug OFF", act_debug_off); y=y-26
  makeBtn(f, x, y, "Trace *", act_trace_all); y=y-26
  makeBtn(f, x, y, "Trace OFF", act_trace_off); y=y-26
  makeBtn(f, x, y, "Run QA", act_qatest); y=y-26
  makeBtn(f, x, y, "Bench", act_bench); y=y-26
  makeBtn(f, x, y, "Tracer Diag", act_tracer_diag); y=y-26
  makeBtn(f, x, y, "Export Logs", act_export); y=y-26
  makeBtn(f, x, y, "Pop-out", act_popout)

  -- Center live log panel
  local box = CreateFrame("Frame", nil, f, tpl()); box:SetSize(540, 380); box:SetPoint("TOPLEFT", 180, -90); SkinBox(box)
  local scroll=CreateFrame("ScrollFrame",nil,box,"UIPanelScrollFrameTemplate"); scroll:SetPoint("TOPLEFT",12,-12); scroll:SetPoint("BOTTOMRIGHT",-12,36)
  if scroll.ScrollBar then scroll.ScrollBar:Hide(); scroll.ScrollBar.Show=function() end end
  local edit=CreateFrame("EditBox",nil,scroll); edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal or SystemFont_Shadow_Med1); edit:SetAutoFocus(false); edit:SetWidth(500); scroll:SetScrollChild(edit)
  LogView.frame=box; LogView.edit=edit; log_refresh(true); log_start()

  -- Command input box
  local input = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
  input:SetAutoFocus(false); input:SetPoint("BOTTOMLEFT", 12, 8); input:SetPoint("BOTTOMRIGHT", -12, 8); input:SetHeight(20)
  input:SetScript("OnEnterPressed", function(self) run_command(self:GetText()); self:SetText(""); log_refresh(true) end)

  -- Right module/file list
  DevShell._frame = f
  refresh_lists()

  return f
end

function AIOS.OpenDevSuite()
  if not DevShell._frame then build() end
  if DevShell._frame:IsShown() then DevShell._frame:Hide(); log_stop() else DevShell._frame:Show(); log_start(); log_refresh(true) end
end

_G.SLASH_AIOSDEVUI1 = "/aiosdevui"
SlashCmdList["AIOSDEVUI"] = function() AIOS.OpenDevSuite() end

Dlog("info","DevShell","AIOS_DevShell v3 ready. /aiosdevui")
