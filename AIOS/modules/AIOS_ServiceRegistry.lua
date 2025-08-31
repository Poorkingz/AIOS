--[[
AIOS_ServiceRegistry.lua  
Version: 1.0.0  
Author: Poorkingz  

📦 Purpose:  
Central service registration and dependency management for the AIOS ecosystem.  
This ensures all core modules (Utils, Logger, EventBus, Timers, Saved, Serializer, etc.)  
are discoverable through a single registry, making dependency resolution clean and reliable.  

🌐 Links:  
CurseForge: https://www.curseforge.com/members/aios/projects  
Website:   https://aioswow.info/  
Discord:   https://discord.gg/JMBgHA5T  
Support:   support@aioswow.dev  

🔑 API Functions:
AIOS.ServiceRegistry.RegisterService()  
    • Automatically registers all core services in proper dependency order.  
    • Should only be called once, but is re-entrant safe.  

AIOS.ServiceRegistry.GetService(serviceName) → serviceRef  
    • Retrieves a registered service by name.  
    • Falls back to _G.AIOS[serviceName] if Utils.ResolveService isn’t ready.  
    • Example:  
        local Logger = AIOS.ServiceRegistry.GetService("Logger")  
        Logger:Info("Hello from my addon!")  

⚠️ Notes:  
- Must load **after Utils** but **before other core modules**.  
- Auto-registers on load if Utils is available, otherwise waits for `ADDON_LOADED`.  
]]

local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

local function registerCoreServices()
    if not AIOS.Utils or not AIOS.Utils.RegisterService then
        return false -- Utils not ready yet
    end
    
    -- Register all core services in proper dependency order
    AIOS.Utils.RegisterService("Utils", function() return AIOS.Utils end)
    AIOS.Utils.RegisterService("Logger", function() return AIOS.Logger end)
    AIOS.Utils.RegisterService("EventBus", function() return AIOS.EventBus end)
    AIOS.Utils.RegisterService("Timers", function() return AIOS.Timers end)
    AIOS.Utils.RegisterService("Saved", function() return AIOS.Saved end)
    AIOS.Utils.RegisterService("Serializer", function() return AIOS.Serializer end)
    AIOS.Utils.RegisterService("ModuleLoader", function() return AIOS.ModuleLoader end)
    AIOS.Utils.RegisterService("Locale", function() return AIOS.Locale end)
    AIOS.Utils.RegisterService("Media", function() return AIOS.Media end)
    
    return true
end

-- Auto-register on load if Utils is ready
if AIOS.Utils and AIOS.Utils.RegisterService then
    registerCoreServices()
else
    -- Wait for Utils to be available
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(_, event, addonName)
        if addonName == "AIOS" and AIOS.Utils and AIOS.Utils.RegisterService then
            registerCoreServices()
            f:UnregisterAllEvents()
        end
    end)
end

-- Public API
AIOS.ServiceRegistry = {
    RegisterService = registerCoreServices,
    GetService = function(serviceName)
        if AIOS.Utils and AIOS.Utils.ResolveService then
            return AIOS.Utils.ResolveService(serviceName)
        end
        return AIOS[serviceName]
    end
}

return AIOS.ServiceRegistry