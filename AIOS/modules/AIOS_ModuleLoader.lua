--[[ 
AIOS ModuleLoader
Version: 1.0
Author: Poorkingz
Project: https://www.curseforge.com/members/aios/projects
Website: https://aioswow.info/
Discord: https://discord.gg/JMBgHA5T
Support: support@aioswow.dev

Description:
The AIOS ModuleLoader provides a safe, dependency-aware lifecycle manager
for AIOS modules. It ensures modules load in order, respects dependencies,
and exposes async lifecycle methods.

API:
  AIOS.ModuleLoader:CreateModuleState(name) → state
  AIOS.ModuleLoader:GetModuleState(name) → state
  AIOS.ModuleLoader:Register(name, module, opts) → success, error
  AIOS.ModuleLoader:CheckDependencies(name) → (ok, missingDeps)
  AIOS.ModuleLoader:ResolveDependencies(name) → Promise
  AIOS.ModuleLoader:EnableAsync(name) → Promise
  AIOS.ModuleLoader:Enable(name)
  AIOS.ModuleLoader:DisableAsync(name) → Promise
  AIOS.ModuleLoader:Disable(name)
  AIOS.ModuleLoader:EnableAll()
  AIOS.ModuleLoader:GetModule(name) → module | nil
  AIOS.ModuleLoader:GetModulesByState(state) → { name = module }
  AIOS.ModuleLoader:HasModule(name) → boolean

Lifecycle Hooks (optional per module):
  module.OnBoot(self)    -- Called once before first enable
  module.OnEnable(self)  -- Called every time enabled
  module.OnDisable(self) -- Called when disabled

Notes:
- Supports Retail 11.x, Classic Era 1.15.x, and MoP Classic 5.4.0
- Safe async execution using promises
- Dependency resolution prevents broken load order
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.ModuleLoader = AIOS.ModuleLoader or {}
local ML = AIOS.ModuleLoader

-- ========= Dependency Injection Ready =========
local function resolveService(serviceName)
    if AIOS.Utils and AIOS.Utils.ResolveService then
        return AIOS.Utils.ResolveService(serviceName)
    end
    return AIOS[serviceName] -- Fallback
end

local function getUtils() return resolveService("Utils") end
local function getEventBus() return resolveService("EventBus") end
local function getLogger() return resolveService("Logger") end

-- Safe logging with graceful fallbacks
local function dlog(level, tag, msg)
    local logger = getLogger()
    if logger and logger.Log then
        pcall(logger.Log, logger, level or "info", tag or "ModLoader", msg)
    elseif AIOS.CoreLog then
        pcall(AIOS.CoreLog, msg, level or "info", tag or "ModLoader")
    end
end

-- ========= Core Structures =========
ML._mods = ML._mods or {}           -- name -> module record
ML._deps = ML._deps or {}           -- name -> dependency list
ML._states = ML._states or {}       -- name -> reactive state
ML._started = ML._started or false
ML._pending = ML._pending or {}     -- Modules waiting for dependencies

-- ========= Reactive Module States =========
local MODULE_STATES = {
    REGISTERED = "registered",
    BOOTING = "booting", 
    ENABLING = "enabling",
    ENABLED = "enabled",
    DISABLING = "disabling",
    DISABLED = "disabled",
    ERROR = "error"
}

function ML:CreateModuleState(name)
    local utils = getUtils()
    local initialState = { status = MODULE_STATES.REGISTERED, error = nil }
    
    local state = utils.ReactiveState(initialState, function(key, newValue, oldValue)
        local eventBus = getEventBus()
        if eventBus and eventBus.Emit then
            eventBus:Emit("MODULE_STATE_CHANGED", name, key, newValue, oldValue)
        end
    end)
    
    self._states[name] = state
    return state
end

function ML:GetModuleState(name)
    return self._states[name] or self:CreateModuleState(name)
end

-- ========= Advanced Module Registration =========
function ML:Register(name, module, opts)
    if type(name) ~= "string" or name == "" then
        return false, "Invalid module name"
    end
    if type(module) ~= "table" then
        return false, "Module must be a table"
    end
    if self._mods[name] then
        return false, "Module already registered: " .. name
    end

    opts = opts or {}
    local dependencies = opts.dependencies or {}
    local rec = {
        name = name,
        module = module,
        opts = opts,
        dependencies = dependencies,
        state = self:GetModuleState(name)
    }

    self._mods[name] = rec
    self._deps[name] = dependencies
    rec.state.status = MODULE_STATES.REGISTERED

    dlog("debug", "ModLoader", "Registered module: " .. name .. " (deps: " .. table.concat(dependencies, ", ") .. ")")

    -- Emit registration event
    local eventBus = getEventBus()
    if eventBus and eventBus.Emit then
        eventBus:Emit("MODULE_REGISTERED", name, dependencies)
    end

    -- Auto-enable if system is already started
    if self._started then
        self:Enable(name)
    end

    return true
end

-- ========= Dependency Resolution =========
function ML:CheckDependencies(name)
    local deps = self._deps[name] or {}
    local missing = {}
    
    for _, depName in ipairs(deps) do
        local depModule = self._mods[depName]
        if not depModule or depModule.state.status ~= MODULE_STATES.ENABLED then
            table.insert(missing, depName)
        end
    end
    
    return #missing == 0, missing
end

function ML:ResolveDependencies(name)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve, reject)
        local deps = self._deps[name] or {}
        local promises = {}
        
        for _, depName in ipairs(deps) do
            local depModule = self._mods[depName]
            if depModule and depModule.state.status ~= MODULE_STATES.ENABLED then
                table.insert(promises, self:EnableAsync(depName))
            end
        end
        
        if #promises > 0 then
            utils.All(promises):andThen(resolve, reject)
        else
            resolve()
        end
    end)
end

-- ========= Advanced Lifecycle Management =========
function ML:EnableAsync(name)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve, reject)
        local rec = self._mods[name]
        if not rec then
            reject("Module not found: " .. name)
            return
        end

        -- Check current state
        if rec.state.status == MODULE_STATES.ENABLED then
            resolve(rec.module)
            return
        end

        if rec.state.status == MODULE_STATES.ENABLING then
            -- Already enabling, wait for completion
            local eventBus = getEventBus()
            if eventBus then
                eventBus:WaitFor("MODULE_STATE_CHANGED", 5000, function(eventName, moduleName, key, newValue)
                    return moduleName == name and key == "status" and 
                          (newValue == MODULE_STATES.ENABLED or newValue == MODULE_STATES.ERROR)
                end):andThen(function(...)
                    if rec.state.status == MODULE_STATES.ENABLED then
                        resolve(rec.module)
                    else
                        reject("Module failed to enable: " .. name)
                    end
                end, function()
                    reject("Module enable timeout: " .. name)
                end)
            end
            return
        end

        -- Resolve dependencies first
        self:ResolveDependencies(name):andThen(function()
            rec.state.status = MODULE_STATES.ENABLING
            
            -- Execute lifecycle hooks
            local module = rec.module
            local results = {}
            
            -- OnBoot hook (if not already booted)
            if module.OnBoot and type(module.OnBoot) == "function" and not rec._booted then
                local ok, err = utils.SafeCall(module.OnBoot, module)
                if not ok then
                    rec.state.status = MODULE_STATES.ERROR
                    rec.state.error = err
                    dlog("error", "ModLoader", "OnBoot failed for " .. name .. ": " .. tostring(err))
                    reject("OnBoot failed: " .. tostring(err))
                    return
                end
                rec._booted = true
            end
            
            -- OnEnable hook
            if module.OnEnable and type(module.OnEnable) == "function" then
                local ok, err = utils.SafeCall(module.OnEnable, module)
                if not ok then
                    rec.state.status = MODULE_STATES.ERROR
                    rec.state.error = err
                    dlog("error", "ModLoader", "OnEnable failed for " .. name .. ": " .. tostring(err))
                    reject("OnEnable failed: " .. tostring(err))
                    return
                end
            end
            
            -- Success!
            rec.state.status = MODULE_STATES.ENABLED
            rec.state.error = nil
            
            dlog("info", "ModLoader", "Module enabled: " .. name)
            
            -- Emit enabled event
            local eventBus = getEventBus()
            if eventBus and eventBus.Emit then
                eventBus:Emit("MODULE_ENABLED", name)
            end
            
            resolve(module)
            
        end, function(err)
            rec.state.status = MODULE_STATES.ERROR
            rec.state.error = err
            dlog("error", "ModLoader", "Dependency resolution failed for " .. name .. ": " .. tostring(err))
            reject("Dependency failed: " .. tostring(err))
        end)
    end)
end

function ML:Enable(name)
    local utils = getUtils()
    utils.RunAsync(function()
        return self:EnableAsync(name)
    end)
end

function ML:DisableAsync(name)
    local utils = getUtils()
    return utils.CreatePromise(function(resolve, reject)
        local rec = self._mods[name]
        if not rec or rec.state.status == MODULE_STATES.DISABLED then
            resolve()
            return
        end

        rec.state.status = MODULE_STATES.DISABLING
        
        local module = rec.module
        if module.OnDisable and type(module.OnDisable) == "function" then
            local ok, err = utils.SafeCall(module.OnDisable, module)
            if not ok then
                rec.state.status = MODULE_STATES.ERROR
                rec.state.error = err
                dlog("error", "ModLoader", "OnDisable failed for " .. name .. ": " .. tostring(err))
                reject("OnDisable failed: " .. tostring(err))
                return
            end
        end
        
        rec.state.status = MODULE_STATES.DISABLED
        rec.state.error = nil
        
        dlog("info", "ModLoader", "Module disabled: " .. name)
        
        -- Emit disabled event
        local eventBus = getEventBus()
        if eventBus and eventBus.Emit then
            eventBus:Emit("MODULE_DISABLED", name)
        end
        
        resolve()
    end)
end

function ML:Disable(name)
    local utils = getUtils()
    utils.RunAsync(function()
        return self:DisableAsync(name)
    end)
end

-- ========= Batch Operations =========
function ML:EnableAll()
    local utils = getUtils()
    local promises = {}
    
    for name, rec in pairs(self._mods) do
        if rec.state.status ~= MODULE_STATES.ENABLED then
            table.insert(promises, self:EnableAsync(name))
        end
    end
    
    if #promises > 0 then
        utils.All(promises):andThen(function()
            self._started = true
            dlog("info", "ModLoader", "All modules enabled")
            
            local eventBus = getEventBus()
            if eventBus and eventBus.Emit then
                eventBus:Emit("ALL_MODULES_ENABLED")
            end
        end, function(err)
            dlog("error", "ModLoader", "Failed to enable all modules: " .. tostring(err))
        end)
    else
        self._started = true
        dlog("info", "ModLoader", "All modules already enabled")
    end
end

-- ========= Module Discovery =========
function ML:GetModule(name)
    local rec = self._mods[name]
    return rec and rec.module or nil
end

function ML:GetModulesByState(state)
    local results = {}
    for name, rec in pairs(self._mods) do
        if rec.state.status == state then
            results[name] = rec.module
        end
    end
    return results
end

function ML:HasModule(name)
    return self._mods[name] ~= nil
end

-- ========= Startup Handler =========
local function initializeEventListeners()
    local eventBus = getEventBus()
    if not eventBus then return end
    
    eventBus:Listen("AIOS_CORE_READY", function()
        if not ML._started then
            ML:EnableAll()
        end
    end)
end

-- Traditional login handler as fallback
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    if not ML._started then
        ML:EnableAll()
    end
end)

-- Initialize event listeners
initializeEventListeners()

-- ========= DI Registration =========
if AIOS.Utils and AIOS.Utils.RegisterService then
    AIOS.Utils.RegisterService("ModuleLoader", function() return ML end)
end

-- ========= Self-Test (Silent) =========
do
    -- Test reactive state creation
    local testState = ML:CreateModuleState("TEST_MODULE")
    
    -- Test promise creation
    local testPromise = ML:EnableAsync("NONEXISTENT_MODULE"):andThen(nil, function() end)
    
    dlog("info", "ModLoader", "Advanced ModuleLoader initialized")
end

return ML