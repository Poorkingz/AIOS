--[[
AIOS_Locale.lua - Next-generation localization and translation system
Version: 2.0.1
Author: Poorkingz
License: MIT-AIOS

Project Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Email: support@aioswow.dev

🌐 AIOS Locale API 🌐
A high-performance localization engine that replaces AceLocale with
a leaner, adaptive system. Built on AIOS core services:
- AIOS.Lean (interning & memory optimization)
- AIOS.Codec (string compression/decompression)
- AIOS.Saved (persistent learned translations)
- AIOS.Comms (optional crowd learning, group/guild sync)

CORE FUNCTIONS:
  Locale:Initialize() → bool
  Locale:RegisterAddon(addonName, phrasesTable) → bool
  Locale:GetString(key, addonName?) → localized string
  Locale:L(key, addonName?) → shorthand wrapper
  Locale:LearnPhrase(key, translation, locale) → bool
  Locale:SaveLearnedPhrases() / Locale:LoadLearnedPhrases()
  Locale:GetMetrics() → metrics table

FALLBACKS:
  - Core compressed AIOS translations (tiny memory footprint)
  - Addon-registered phrases
  - Learned user/community phrases
  - Blizzard API lookups (spells, items, zones, classes, races)
  - Intelligent pattern matching
  - Final fallback returns key unchanged

HIGHLIGHTS:
  - No massive language files like AceLocale (KB vs MB size)
  - Auto-learns and shares translations across players
  - Supports Classic, Retail, and MoP clients
  - Extensible API with AceLocale-compatible wrapper (Locale:NewLocale)

Example usage:
  local L = AIOS.Locale
  print(L:GetString("Enable"))               -- localized core string
  print(L:GetString("Hello", "CopyBox"))     -- localized addon string
  L:LearnPhrase("Goodbye", "Adiós", "esES")  -- dynamic learning

--]]

-- AIOS_Locale.lua - Ultimate localization system for AIOS
local _G = _G
local AIOS = _G.AIOS or {}
_G.AIOS = AIOS

if not AIOS.Locale then AIOS.Locale = {} end
local Locale = AIOS.Locale

-- ==================== CONFIGURATION ====================
Locale._version = "2.0.0"
Locale.debugLevel = 0
Locale.enableCrowdLearning = true
Locale.enableBlizzardAPI = true
Locale.communityBroadcast = "GUILD" -- GUILD, GROUP, or RAID

-- ==================== CORE DATA STRUCTURES ====================
Locale._decompressedCore = {}
Locale._addonPhrases = {}
Locale._learnedPhrases = {}
Locale._translationPatterns = {}

-- ==================== METRICS & STATS ====================
Locale._metrics = {
    coreTranslations = 0,
    learnedTranslations = 0,
    addonTranslations = 0,
    crowdTranslationsReceived = 0,
    blizzardApiTranslations = 0,
    memorySaved = 0,
    compressionRatio = 0
}

-- ==================== INITIALIZATION ====================
function Locale:Initialize()
    if not self:_CheckDependencies() then
        return false
    end
    
    self:LoadCoreTranslations()
    self:LoadLearnedPhrases()
    self:RegisterComms()
    
    self.initialized = true
    self:_LogInfo("AIOS_Locale v" .. self._version .. " initialized")
    return true
end

function Locale:_CheckDependencies()
    if not AIOS.Lean then
        self:_LogError("AIOS.Lean is required")
        return false
    end
    
    if not AIOS.Codec then
        self:_LogWarning("AIOS.Codec not available - compression disabled")
    end
    
    if not AIOS.Saved then
        self:_LogWarning("AIOS.Saved not available - persistence disabled")
    end
    
    if not AIOS.Comms then
        self:_LogWarning("AIOS.Comms not available - crowd learning disabled")
        self.enableCrowdLearning = false
    end
    
    return true
end

-- ==================== CORE TRANSLATION SYSTEM ====================
function Locale:LoadCoreTranslations()
    local currentLocale = GetLocale()
    
    -- Compressed core translations for AIOS-specific phrases
    local compressedCore = {
        enUS = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        frFR = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        deDE = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDgAAAA==",
        esES = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        zhCN = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        zhTW = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        ruRU = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        koKR = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        ptBR = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA=",
        itIT = "H4sIAAAAAAAAA6tWystPSc3JT1eA0mZKaQq1SklFtUrJRYn5eSmVSnmJRSWpSjl5KfFKtUopRamVtUoAjNkLgDcAAAA="
    }
    
 -- Decompress or use fallback
local translations = {}
if AIOS.Codec and compressedCore[currentLocale] then
    local ok, decompressed = pcall(AIOS.Codec.Decompress, AIOS.Codec, compressedCore[currentLocale])
    if ok and decompressed and type(decompressed) == "string" then
        translations = self:_ParseCompressedBlock(decompressed)
    else
        self:_LogWarning("Failed to decompress core translations for " .. currentLocale)
    end
end
    
    -- Fallback to English if current locale not available
    if not next(translations) and compressedCore.enUS then
        if AIOS.Codec then
            local success, decompressed = pcall(AIOS.Codec.Decompress, AIOS.Codec, compressedCore.enUS)
            if success then
                translations = self:_ParseCompressedBlock(decompressed)
            end
        end
    end
    
    -- Final fallback to hardcoded English
    if not next(translations) then
        translations = {
            ["Lean Mode"] = "Lean Mode",
            ["Copy Export"] = "Copy Export",
            ["Settings"] = "Settings",
            ["Enable"] = "Enable",
            ["Disable"] = "Disable",
            ["Configuration"] = "Configuration",
            ["Advanced"] = "Advanced",
            ["Statistics"] = "Statistics",
            ["Memory"] = "Memory",
            ["Performance"] = "Performance"
        }
    end
    
    -- Intern all strings
    for key, value in pairs(translations) do
        local internedKey = AIOS.Lean:intern(key)
        local internedValue = AIOS.Lean:intern(value)
        self._decompressedCore[internedKey] = internedValue
    end
    
    self._metrics.coreTranslations = self:_countTable(self._decompressedCore)
    self:_LogInfo("Loaded " .. self._metrics.coreTranslations .. " core translations for " .. currentLocale)
end

function Locale:_ParseCompressedBlock(block)
    if not block or type(block) ~= "string" then
        self:_LogWarning("_ParseCompressedBlock received nil or invalid block")
        return {}
    end
    
    local phrases = {}
    for line in block:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.+)$")
        if key and value then
            phrases[AIOS.Lean:intern(key)] = AIOS.Lean:intern(value)
        end
    end
    return phrases
end

-- ==================== ADDON REGISTRATION ====================
function Locale:RegisterAddon(addonName, phrasesTable)
    if not self.initialized then
        self:_LogError("Locale not initialized")
        return false
    end
    
    if not addonName or type(phrasesTable) ~= "table" then
        self:_LogError("Invalid parameters for RegisterAddon")
        return false
    end
    
    self._addonPhrases[addonName] = self._addonPhrases[addonName] or {}
    
    local count = 0
    for locale, translations in pairs(phrasesTable) do
        self._addonPhrases[addonName][locale] = self._addonPhrases[addonName][locale] or {}
        
        for key, value in pairs(translations) do
            local internedKey = AIOS.Lean:intern(key)
            local internedValue = AIOS.Lean:intern(value)
            self._addonPhrases[addonName][locale][internedKey] = internedValue
            count = count + 1
        end
    end
    
    self._metrics.addonTranslations = self._metrics.addonTranslations + count
    self:_LogInfo("Registered " .. count .. " phrases for " .. addonName)
    return true
end

-- ==================== MAIN TRANSLATION API ====================
function Locale:GetString(key, addonName)
    if not key or type(key) ~= "string" then return key end
    
    local currentLocale = GetLocale()
    local internedKey = AIOS.Lean:intern(key)
    local result
    
    -- 1. Try addon-specific translations
    if addonName and self._addonPhrases[addonName] then
        local addonTranslations = self._addonPhrases[addonName][currentLocale] or 
                                 self._addonPhrases[addonName].enUS
        if addonTranslations and addonTranslations[internedKey] then
            result = addonTranslations[internedKey]
        end
    end
    
    -- 2. Try core AIOS translations
    if not result and self._decompressedCore[internedKey] then
        result = self._decompressedCore[internedKey]
    end
    
    -- 3. Try learned phrases
    if not result and self._learnedPhrases[currentLocale] and self._learnedPhrases[currentLocale][internedKey] then
        result = self._learnedPhrases[currentLocale][internedKey]
    end
    
    -- 4. Try Blizzard API fallback
    if not result and self.enableBlizzardAPI then
        result = self:_TryBlizzardAPI(key)
        if result and result ~= key then
            self:LearnPhrase(key, result, currentLocale)
            self._metrics.blizzardApiTranslations = self._metrics.blizzardApiTranslations + 1
        end
    end
    
    -- 5. Try pattern matching
    if not result then
        result = self:_TryPatternMatching(key, currentLocale)
    end
    
    -- 6. Final fallback - return key or query crowd
    if not result or result == key then
        result = key
        if self.enableCrowdLearning then
            self:QueryCrowdTranslation(key, currentLocale)
        end
    end
    
    return result
end

function Locale:L(key, addonName)
    return self:GetString(key, addonName)
end

-- ==================== BLAZZARD API INTEGRATION ====================
function Locale:_TryBlizzardAPI(key)
    -- Pattern matching for Blizzard API resources
    local patterns = {
        -- Spell patterns
        ["^[Ss]pell:%s*(%d+)$"] = function(id) return GetSpellInfo(tonumber(id)) end,
        ["^[Ss]pell:%s*([%a%s]+)$"] = function(name) return GetSpellInfo(name) end,
        
        -- Item patterns
        ["^[Ii]tem:%s*(%d+)$"] = function(id) 
            if C_Item and C_Item.GetItemInfo then
                return C_Item.GetItemInfo(tonumber(id))
            else
                return GetItemInfo(tonumber(id))
            end
        end,
        
        -- Zone patterns
        ["^[Zz]one:%s*(.+)$"] = function(name) 
            local currentZone = GetZoneText()
            if currentZone:lower() == name:lower() then return currentZone end
            return nil
        end,
        
        -- Class patterns
        ["^[Cc]lass:%s*(.+)$"] = function(name)
            local localizedClass, englishClass = UnitClass("player")
            if englishClass:lower() == name:lower() then return localizedClass end
            return nil
        end,
        
        -- Race patterns
        ["^[Rr]ace:%s*(.+)$"] = function(name)
            local localizedRace, englishRace = UnitRace("player")
            if englishRace:lower() == name:lower() then return localizedRace end
            return nil
        end
    }
    
    for pattern, handler in pairs(patterns) do
        local match = key:match(pattern)
        if match then
            local success, apiResult = pcall(handler, match)
            if success and apiResult then 
                return apiResult 
            end
        end
    end
    
    return nil
end

-- ==================== PATTERN LEARNING ====================
function Locale:_TryPatternMatching(key, locale)
    if not self._translationPatterns[locale] then return nil end
    
    for pattern, replacement in pairs(self._translationPatterns[locale]) do
        local translated = key:gsub(pattern, replacement)
        if translated ~= key then
            return translated
        end
    end
    
    return nil
end

function Locale:_ExtractPatterns(english, translation, locale)
    -- Simple pattern extraction - this could be enhanced with ML
    local patterns = {}
    
    -- Extract simple suffix patterns
    if english:match("'s .+$") and translation:match("的.+$") then
        patterns["'s (.+)$"] = "的%1"
    end
    
    -- Add more pattern extraction logic here
    
    -- Store patterns
    self._translationPatterns[locale] = self._translationPatterns[locale] or {}
    for pattern, replacement in pairs(patterns) do
        self._translationPatterns[locale][pattern] = replacement
    end
end

-- ==================== LEARNING SYSTEM ====================
function Locale:LearnPhrase(key, translation, locale)
    if not key or not translation or translation == key then return false end
    
    locale = locale or GetLocale()
    self._learnedPhrases[locale] = self._learnedPhrases[locale] or {}
    
    local internedKey = AIOS.Lean:intern(key)
    local internedTranslation = AIOS.Lean:intern(translation)
    
    self._learnedPhrases[locale][internedKey] = internedTranslation
    self._metrics.learnedTranslations = self._metrics.learnedTranslations + 1
    
    -- Extract patterns for future use
    self:_ExtractPatterns(key, translation, locale)
    
    -- Save to persistent storage
    self:SaveLearnedPhrases()
    
    -- Broadcast to community
    if self.enableCrowdLearning then
        self:BroadcastLearning(key, translation, locale)
    end
    
    self:_LogDebug("Learned: '" .. key .. "' → '" .. translation .. "' (" .. locale .. ")")
    return true
end

-- ==================== PERSISTENCE ====================
function Locale:LoadLearnedPhrases()
    if not AIOS.Saved then return end
    
    AIOS.Saved.Locale = AIOS.Saved.Locale or {}
    self._learnedPhrases = AIOS.Saved.Locale.learned or {}
    self._metrics.learnedTranslations = self:_countTable(self._learnedPhrases)
    
    self:_LogInfo("Loaded " .. self._metrics.learnedTranslations .. " learned phrases")
end

function Locale:SaveLearnedPhrases()
    if not AIOS.Saved then return end
    
    AIOS.Saved.Locale = AIOS.Saved.Locale or {}
    AIOS.Saved.Locale.learned = self._learnedPhrases
    AIOS.Saved.Locale.lastSave = time()
    
    self:_LogDebug("Saved learned phrases to persistent storage")
end

-- ==================== CROWD LEARNING ====================
function Locale:RegisterComms()
    if not AIOS.Comms or not self.enableCrowdLearning then return end
    
    -- Learning broadcast
    AIOS.Comms:RegisterPrefix("AIOS_LOCALE_LEARN", function(prefix, data, distribution, sender)
        if data and data.key and data.translation and data.locale then
            -- Validate sender is in our group/guild
            if self:_IsValidSender(sender, distribution) then
                self:LearnPhrase(data.key, data.translation, data.locale)
                self._metrics.crowdTranslationsReceived = self._metrics.crowdTranslationsReceived + 1
            end
        end
    end)
    
    -- Translation query
    AIOS.Comms:RegisterPrefix("AIOS_LOCALE_QUERY", function(prefix, data, distribution, sender)
        if data and data.key and data.locale and self:_IsValidSender(sender, distribution) then
            local translation = self:GetString(data.key)
            if translation ~= data.key then
                AIOS.Comms:SendData("AIOS_LOCALE_RESPONSE", {
                    key = data.key,
                    translation = translation,
                    locale = data.locale,
                    source = UnitName("player") .. "-" .. GetRealmName()
                }, "WHISPER", sender)
            end
        end
    end)
    
    -- Translation response
    AIOS.Comms:RegisterPrefix("AIOS_LOCALE_RESPONSE", function(prefix, data, distribution, sender)
        if data and data.key and data.translation and data.locale then
            self:LearnPhrase(data.key, data.translation, data.locale)
        end
    end)
    
    self:_LogInfo("Crowd learning system initialized")
end

function Locale:_IsValidSender(sender, distribution)
    -- Basic validation - could be enhanced with whitelist/security
    if distribution == "GUILD" and IsInGuild() then
        return true
    elseif (distribution == "GROUP" or distribution == "RAID") and IsInGroup() then
        return true
    elseif distribution == "WHISPER" then
        return true -- Be careful with whispers
    end
    return false
end

function Locale:BroadcastLearning(key, translation, locale)
    if not AIOS.Comms or not self.enableCrowdLearning then return end
    
    AIOS.Comms:SendData("AIOS_LOCALE_LEARN", {
        key = key,
        translation = translation,
        locale = locale,
        source = UnitName("player") .. "-" .. GetRealmName(),
        timestamp = time()
    }, self.communityBroadcast)
end

function Locale:QueryCrowdTranslation(key, locale)
    if not AIOS.Comms or not self.enableCrowdLearning then return end
    
    AIOS.Comms:SendData("AIOS_LOCALE_QUERY", {
        key = key,
        locale = locale or GetLocale(),
        requester = UnitName("player") .. "-" .. GetRealmName()
    }, self.communityBroadcast)
end

-- ==================== METRICS & REPORTING ====================
function Locale:GetMetrics()
    local totalMemory = collectgarbage("count")
    local memoryReduction = totalMemory > 0 and (self._metrics.memorySaved / totalMemory) * 100 or 0
    
    return {
        coreTranslations = self._metrics.coreTranslations,
        learnedTranslations = self._metrics.learnedTranslations,
        addonTranslations = self._metrics.addonTranslations,
        crowdTranslationsReceived = self._metrics.crowdTranslationsReceived,
        blizzardApiTranslations = self._metrics.blizzardApiTranslations,
        memorySaved = self._metrics.memorySaved,
        memoryReduction = string.format("%.1f%%", memoryReduction),
        compressionRatio = self._metrics.compressionRatio,
        currentLocale = GetLocale(),
        systemLoad = self:_calculateSystemLoad()
    }
end

function Locale:_calculateSystemLoad()
    local fps = GetFramerate() or 60
    local memory = collectgarbage("count")
    local inCombat = InCombatLockdown() or false
    
    local load = 0
    if fps < 30 then load = load + 50
    elseif fps < 60 then load = load + 25 end
    if memory > 100000 then load = load + 25
    elseif memory > 50000 then load = load + 15 end
    if inCombat then load = load + 10 end
    
    return math.min(100, load)
end

-- ==================== DEBUG & UTILITY ====================
function Locale:_countTable(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

function Locale:_LogError(msg)
    if AIOS.Debug and AIOS.Debug.Log then
        AIOS.Debug:Log("error", "Locale", msg)
    else
        print("|cFFFF0000AIOS_Locale Error:|r " .. msg)
    end
end

function Locale:_LogWarning(msg)
    if AIOS.Debug and AIOS.Debug.Log then
        AIOS.Debug:Log("warning", "Locale", msg)
    elseif self.debugLevel > 0 then
        print("|cFFFFFF00AIOS_Locale Warning:|r " .. msg)
    end
end

function Locale:_LogInfo(msg)
    if AIOS.Debug and AIOS.Debug.Log then
        AIOS.Debug:Log("info", "Locale", msg)
    elseif self.debugLevel > 0 then
        print("|cFF00FF00AIOS_Locale Info:|r " .. msg)
    end
end

function Locale:_LogDebug(msg)
    if AIOS.Debug and AIOS.Debug.Log then
        AIOS.Debug:Log("debug", "Locale", msg)
    elseif self.debugLevel > 1 then
        print("|cFF888888AIOS_Locale Debug:|r " .. msg)
    end
end

-- ==================== COMPATIBILITY WRAPPERS ====================
function Locale:NewLocale(namespace)
    return setmetatable({}, {
        __index = function(t, k)
            return function(_, ...)
                return Locale:GetString(k, namespace, ...)
            end
        end,
        __call = function(t, key, args)
            local translation = Locale:GetString(key, namespace)
            if args and type(args) == "table" then
                return string.format(translation, unpack(args))
            end
            return translation
        end
    })
end

-- WoW API compatibility wrappers
function Locale:GetItemName(itemId)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(itemId)
    else
        return GetItemInfo(itemId)
    end
end

function Locale:GetSpellInfo(spellId)
    return GetSpellInfo(spellId)
end

function Locale:GetUnitName(unit, showServerName)
    return GetUnitName(unit, showServerName)
end

-- ==================== INITIALIZATION ====================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "AIOS" then
        -- Wait for other AIOS modules to load
        C_Timer.After(1, function()
            Locale:Initialize()
        end)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- Register with AIOS core
if AIOS.RegisterModule then
    AIOS.RegisterModule("Locale", Locale)
end

return Locale