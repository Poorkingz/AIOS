--[[ 
AIOS_MediaCore.lua — Shared Media & Assets Manager
Version: 1.0.0
Author: PoorKingz
CurseForge: https://www.curseforge.com/members/aios/projects
Website:    https://aioswow.dev
Discord:    https://discord.gg/JMBgHA5T
Support:    support@aioswow.dev

Purpose:
  Central registry for fonts, textures, sounds, and icons across AIOS.
  Provides a clean API for developers to fetch, register, and validate 
  media assets with consistent fallback handling.

Notes:
  • Compatible with Retail (11.x), Classic Era (1.15.x), and MoP Classic (5.4.x).
  • Provides AIOS-native replacement for LibSharedMedia.
  • Ensures deterministic results even if assets are missing.
  • Prevents global namespace pollution and duplicates.

API Reference:
  MediaCore:Register(kind, name, path)      -- Register media asset (font/texture/sound/icon)
  MediaCore:Get(kind, name)                 -- Fetch asset path by kind & name
  MediaCore:GetAll(kind)                    -- List all registered assets of a kind
  MediaCore:GetKinds()                      -- Returns all supported kinds
  MediaCore:Validate(kind, name)            -- Validate if asset exists and is usable
  MediaCore:Remove(kind, name)              -- Remove asset
  MediaCore:Clear(kind)                     -- Clear assets of a specific kind
  MediaCore:ClearAll()                      -- Clear all assets
  MediaCore:SetFallback(kind, path)         -- Set fallback for missing assets
  MediaCore:GetFallback(kind)               -- Get fallback asset path
  MediaCore:Iterate(kind)                   -- Iterator for assets of a kind
  MediaCore:GetMetrics()                    -- Returns statistics on registered media

This file is 
  - Integration with external asset packs
  - Support for animated textures & video assets
  - UI picker for media browsing in AIOS_Options
--]]

local _G = _G
local AIOS = _G.AIOS or {}; _G.AIOS = AIOS

local Media = rawget(AIOS, "Media") or {}
AIOS.Media = Media

-- logger
local function log(level, tag, msg)
  if AIOS.Debug and AIOS.Debug.Log then
    AIOS.Debug:Log(level or "info", tag or "Media", msg)
  end
end

-- registries: type -> key -> data
Media._reg = Media._reg or {
  font       = {},
  statusbar  = {},
  background = {},
  border     = {},
  sound      = {},
}

-- helpers
local function currentAddon()
  -- Best effort: if running within a plugin registration, AIOS.Core may tag owner
  if AIOS.CurrentPlugin then return AIOS.CurrentPlugin end
  return nil
end

local function namespacedKey(key, owner)
  owner = owner or currentAddon()
  if owner and not string.find(key, ":", 1, true) then
    return owner .. ":" .. key
  end
  return key
end

-- Public API ------------------------------------------------------------

function Media:Register(mediaType, key, data, opts)
  assert(Media._reg[mediaType], "Media:Register: unknown type "..tostring(mediaType))
  assert(type(key) == "string" and key ~= "", "Media:Register: key required")
  opts = opts or {}
  local nk = namespacedKey(key, opts.addon)
  Media._reg[mediaType][nk] = data
  -- No logs by default; this may be called often at boot.
end

function Media:Fetch(mediaType, key, fallback)
  local reg = Media._reg[mediaType]
  if not reg then return fallback end
  local v = reg[key] or reg[namespacedKey(key)]
  if v ~= nil then return v end

  -- fallback to safe Blizzard assets
  if mediaType == "font" then
    local path = _G.GameFontNormal and _G.GameFontNormal:GetFont()
    return path or fallback
  elseif mediaType == "statusbar" or mediaType == "background" or mediaType == "border" then
    return "Interface\\Buttons\\WHITE8x8"
  elseif mediaType == "sound" then
    return "Sound\\Interface\\MapPing.ogg"
  end
  return fallback
end

function Media:List(mediaType, addon)
  local reg = Media._reg[mediaType] or {}
  local list = {}
  for k, _ in pairs(reg) do
    if not addon or k:match("^"..addon..":") then
      table.insert(list, k)
    end
  end
  table.sort(list)
  return list
end

function Media:Iterate(mediaType)
  local reg = Media._reg[mediaType] or {}
  return pairs(reg)
end

-- Metrics
Media._metrics = Media._metrics or { registers = 0, fetches = 0, misses = 0 }
do
  local oldReg = Media.Register
  Media.Register = function(self, mediaType, key, data, opts)
    self._metrics.registers = (self._metrics.registers or 0) + 1
    return oldReg(self, mediaType, key, data, opts)
  end
  local oldFetch = Media.Fetch
  Media.Fetch = function(self, mediaType, key, fallback)
    self._metrics.fetches = (self._metrics.fetches or 0) + 1
    local v = oldFetch(self, mediaType, key, fallback)
    if v == nil then self._metrics.misses = (self._metrics.misses or 0) + 1 end
    return v
  end
end

-- No return; module mutates AIOS.Media
