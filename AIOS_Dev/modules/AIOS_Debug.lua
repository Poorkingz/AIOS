--[[ AIOS_Debug.lua (condensed working copy, header/footer/dividers) ]]--
local _G=_G; AIOS=_G.AIOS or {}; AIOS.Debug=AIOS.Debug or {}; local D=AIOS.Debug
D._enabled=true; D._levelMap={debug=10,info=20,warn=30,error=40}; D._level=D._levelMap.debug; D._max=800; D._buf=D._buf or {}; D._head=D._head or 0
local function now() return (_G.GetTime and _G.GetTime()) or 0 end
local function levelValue(lvl) if type(lvl)=="number" then return lvl end local s=tostring(lvl or "debug"):lower() return D._levelMap[s] or D._levelMap.debug end
function D:IsEnabled() return self._enabled end; function D:Enable() self._enabled=true end; function D:Disable() self._enabled=false end
function D:SetLevel(lvl) self._level=levelValue(lvl) end; function D:GetLevel() return self._level end
local function add_entry(lvl,tag,msg) local n=(D._head % D._max)+1; D._head=n; D._buf[n]={t=now(),lvl=lvl,tag=tag or "AIOS",msg=tostring(msg)} end
function D:Clear() D._buf={}; D._head=0; if self._edit then self._edit:SetText("") end end
local function lvlName(v) if v<=10 then return "DEBUG" elseif v<=20 then return "INFO" elseif v<=30 then return "WARN" else return "ERROR" end end
function D:Log(lvl,tag,msg) if not self._enabled then return end local v=levelValue(lvl); if v<self._level then return end add_entry(v,tag,msg); if self._frame and self._frame:IsShown() then self:RefreshView() end end
function D:Debug(tag,msg) self:Log("debug",tag,msg) end; function D:Info(tag,msg) self:Log("info",tag,msg) end; function D:Warn(tag,msg) self:Log("warn",tag,msg) end; function D:Error(tag,msg) self:Log("error",tag,msg) end
function D:Export() local out={} local c=math.min(self._max,#self._buf) local idx=(self._head-c+self._max)%self._max for i=1,c do idx=(idx%self._max)+1 local e=self._buf[idx]; if e then out[#out+1]=string.format("[%0.3f] %-5s %-12s %s",e.t,lvlName(e.lvl),tostring(e.tag or ""),tostring(e.msg or "")) end end return table.concat(out,"\n") end
local function addBackdrop(str) if BackdropTemplateMixin then return str and "BackdropTemplate,"..str or "BackdropTemplate" end return str end
local function apply_header(f) local S=AIOS and AIOS.UIStyle; if S and S.ApplyStandardHeader then pcall(function() S:ApplyStandardHeader(f,"AIOS Debug") end) end end
local function make_divider(p,off,fromBottom) local l=p:CreateTexture(nil,"ARTWORK"); l:SetColorTexture(0.1,0.6,1.0,0.65); l:SetHeight(1); if fromBottom then l:SetPoint("BOTTOMLEFT",12,off or 36); l:SetPoint("BOTTOMRIGHT",-12,off or 36) else l:SetPoint("TOPLEFT",12,off or -44); l:SetPoint("TOPRIGHT",-12,off or -44) end return l end
local function build_view() local f=CreateFrame("Frame","AIOS_DebugFrame",UIParent,addBackdrop("BackdropTemplate")); f:SetSize(740,440); f:SetPoint("CENTER")
f:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface/Tooltips/UI-Tooltip-Border",edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
f:SetBackdropColor(0,0,0,1); f:SetBackdropBorderColor(0.1,0.6,1,0.9); f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing); f:SetFrameStrata("DIALOG"); f:Hide()
apply_header(f); f:SetScript("OnShow", function(self) apply_header(self) end); make_divider(f,-44,false); make_divider(f,36,true)
local scroll=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate"); scroll:SetPoint("TOPLEFT",15,-52); scroll:SetPoint("BOTTOMRIGHT",-15,56); if scroll.ScrollBar then if scroll.ScrollBar.ScrollUpButton then scroll.ScrollBar.ScrollUpButton:Hide() end if scroll.ScrollBar.ScrollDownButton then scroll.ScrollBar.ScrollDownButton:Hide() end scroll.ScrollBar:Hide(); scroll.ScrollBar.Show=function() end end
local edit=CreateFrame("EditBox",nil,scroll); edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal or SystemFont_Shadow_Med1); edit:SetAutoFocus(false); edit:SetWidth(690); edit:SetText(""); edit:ClearFocus(); scroll:SetScrollChild(edit)
local footer=f:CreateFontString(nil,"OVERLAY"); footer:SetFont("Fonts\\FRIZQT__.TTF",12,"OUTLINE"); footer:SetText("|cffffffffpowered by |r|cff66ccffAIOS|r"); footer:SetPoint("BOTTOM",0,14); footer:SetShadowOffset(1,-1)
local exit=CreateFrame("Button",nil,f); exit:SetSize(48,22); exit:SetPoint("BOTTOMRIGHT",-15,12); exit.text=exit:CreateFontString(nil,"OVERLAY","GameFontNormal"); exit.text:SetPoint("CENTER"); exit.text:SetText("Exit"); exit.text:SetTextColor(1,1,1); exit:SetScript("OnEnter",function() exit.text:SetTextColor(1,0,0) end); exit:SetScript("OnLeave",function() exit.text:SetTextColor(1,1,1) end); exit:SetScript("OnClick",function() f:Hide() end)
D._frame,D._edit=f,edit end
function D:RefreshView() if not self._frame then return end local text=self:Export(); self._edit:SetText(text); self._edit:SetCursorPosition(#text) end
local function ensure_view() if not D._frame then build_view() end end; _G.SLASH_AIOSDBG1="/aiosdbg"; SlashCmdList["AIOSDBG"]=function() ensure_view(); if D._frame:IsShown() then D._frame:Hide() else D._frame:Show(); D:RefreshView() end end
local fe=CreateFrame("Frame"); fe:RegisterEvent("ADDON_LOADED"); fe:SetScript("OnEvent",function(_,evt,name) if name=="AIOS_UIStyle" or name=="AIOS_UIStyles" then if D._frame then apply_header(D._frame) end end end)
if not AIOS.CoreLog then function AIOS:CoreLog(msg,level,tag) D:Log(level or "debug", tag or "Core", tostring(msg)) end end
D:Info("Debug","AIOS_Debug initialized")
