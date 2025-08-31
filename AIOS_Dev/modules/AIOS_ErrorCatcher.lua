--[[
AIOS_ErrorCatcher.lua — capture Lua errors into AIOS.Debug
]]--
local _G=_G
AIOS=_G.AIOS or {}

local prev = _G.geterrorhandler and _G.geterrorhandler() or nil

local function handler(err)
  local msg = tostring(err or "(nil error)")
  local trace = (_G.debugstack and _G.debugstack(3)) or ""
  if AIOS and AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log("error","LuaError", msg .. "\n" .. trace)
  end
  if type(prev)=="function" then pcall(prev, err) end
end

if _G.seterrorhandler then _G.seterrorhandler(handler) end

_G.SLASH_AIOSERR1="/aioserr"
SlashCmdList["AIOSERR"]=function()
  if AIOS and AIOS.Debug and AIOS.Debug.Export then
    local txt = AIOS.Debug:Export()
    if _G.AIOS_CopyBox and _G.AIOS_CopyBox.Open then _G.AIOS_CopyBox.Open(txt) end
  end
end
