--[[
AIOS_ServiceRegistry.lua — Central Service Registration
Version: 1.0.0
Author: PoorKingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:   https://aioswow.info/
Discord:   https://discord.gg/JMBgHA5T
Support:   support@aioswow.dev

Purpose:
  Provides a single registry for all AIOS core services (Utils, Logger, EventBus,
  Timers, Saved, Serializer, etc.). Ensures consistent dependency resolution
  across the ecosystem with safe fallback and debug output.

Notes:
  • Must load after Utils but before dependent modules.
  • Auto-registers immediately if Utils is ready; otherwise waits for ADDON_LOADED.
  • DebugPrint uses Blizzard blue unless quietBoot is enabled.

API Reference:
  ServiceRegistry.RegisterService()       -- Registers all core services in dependency order.
  ServiceRegistry.GetService(name) → ref  -- Retrieves service by name (fallbacks to _G).

Example:
  local Logger = AIOS.ServiceRegistry.GetService("Logger")
  Logger:Info("Hello from my addon!")

This file is 
  - Allow third-party addons to register into AIOS.ServiceRegistry
  - Optional diagnostics hook to list all active services
--]]

local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

-- Silent-safe print wrapper
local function DebugPrint(tag, msg, level)
    if AIOS._quietBoot then
        if AIOS.Debug and AIOS.Debug.Log then
            AIOS.Debug:Log(level or "info", tag, msg)
        end
    else
        print("|cFF00BFFF[" .. tag .. "]|r " .. msg) -- Blizzard blue
    end
end

-- Register all services
local function registerCoreServices()
    if not AIOS.Utils or not AIOS.Utils.RegisterService then
        DebugPrint("AIOS ServiceRegistry", "Error: AIOS.Utils or RegisterService not ready", "error")
        return false
    end

    -- Register in dependency order
    AIOS.Utils.RegisterService("Utils", function() return AIOS.Utils end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Utils")
	
	AIOS.Utils.RegisterService("Config", function() return AIOS.Config end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Config")

    AIOS.Utils.RegisterService("Logger", function() return AIOS.Logger end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Logger")
	
    AIOS.Utils.RegisterService("EventBus", function() return AIOS.EventBus end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: EventBus")

    AIOS.Utils.RegisterService("Timers", function() return AIOS.Timers end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Timers")

    AIOS.Utils.RegisterService("Saved", function() return AIOS.Saved end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Saved")

    AIOS.Utils.RegisterService("Serializer", function() return AIOS.Serializer end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Serializer")

    AIOS.Utils.RegisterService("ModuleLoader", function() return AIOS.ModuleLoader end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: ModuleLoader")

    AIOS.Utils.RegisterService("Locale", function() return AIOS.Locale end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Locale")

    AIOS.Utils.RegisterService("Media", function() return AIOS.Media end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Media")

    AIOS.Utils.RegisterService("Lean", function() return AIOS.Lean end)
    DebugPrint("AIOS ServiceRegistry", "Registered service: Lean")

    return true
end

-- Auto-register
if AIOS.Utils and AIOS.Utils.RegisterService then
    DebugPrint("AIOS ServiceRegistry", "Attempting immediate registration")
    registerCoreServices()
else
    DebugPrint("AIOS ServiceRegistry", "Waiting for ADDON_LOADED")
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(_, _, addonName)
        if addonName == "AIOS" and AIOS.Utils and AIOS.Utils.RegisterService then
            DebugPrint("AIOS ServiceRegistry", "ADDON_LOADED triggered, registering services")
            registerCoreServices()
            f:UnregisterAllEvents()
        end
    end)
end

-- Public API
AIOS.ServiceRegistry = {
    RegisterService = registerCoreServices,
    GetService = function(serviceName)
        if type(serviceName) ~= "string" then
            DebugPrint("AIOS ServiceRegistry", "Error: GetService expects a string, got: " .. type(serviceName), "error")
            return nil
        end
        if AIOS.Utils and AIOS.Utils.ResolveService then
            return AIOS.Utils.ResolveService(serviceName)
        end
        DebugPrint("AIOS ServiceRegistry", "GetService fallback for: " .. serviceName, "warning")
        return AIOS[serviceName]
    end
}