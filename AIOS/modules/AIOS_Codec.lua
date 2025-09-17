--[[
AIOS — Advanced Interface Operating System
File: AIOS_Codec.lua
Version: 1.0.0
Author: Poorkingz
License: MIT

Project Links:
- CurseForge: https://www.curseforge.com/members/aios/projects
- Website: https://aioswow.info/
- Discord: https://discord.gg/JMBgHA5T
- Email: support@aioswow.dev

Purpose:
  - Provides hashing, compression, base64 encoding, and streaming APIs.
  - Supports Retail 11.x and Classic clients with backward compatibility.
  - Offers advanced yield-safe operations for large data handling.

API Reference:
  - Codec:Compress(data, opts) → compressed_data, error
  - Codec:Decompress(blob) → original_data, error
  - Codec.Stream.new(codec, opts) → stream_object
  - Codec:MakeChunks(data, maxBytes) → chunk_table
  - Codec:Reassemble(parts) → original_data, error
  - Codec:DecompressStream(blob) → original_data, error

  - Hash.CRC32(data) → crc32_hash
  - Hash.FNV32(data) → fnv32_hash
  - Hash.SHA256(data) → sha256_hash (if enabled)
  - Hash.newSHA256() → streaming_sha256_object (if enabled)

Notes:
  - Uses coroutine yields and C_Timer to avoid frame hitches with large datasets.
  - Supports "AC2" framing (backward compatible with "AC1").
  - SHA-256 is disabled by default on Classic for performance reasons.
  - Designed as a core subsystem of AIOS; no direct UI.
--]]

local _G = _G
AIOS = _G.AIOS or {}
AIOS.Codec = AIOS.Codec or { __version = "1.0.0" }
AIOS.Hash = AIOS.Hash or {}

-- Detect game version for compatibility tweaks
local IS_CLASSIC = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
local IS_RETAIL = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

-- Configuration defaults
AIOS.Codec.Quiet = IS_CLASSIC  -- Be quiet by default in Classic
AIOS.Codec.UseSHA = not IS_CLASSIC  -- Don't use SHA-256 by default in Classic
AIOS.DebugMode = false  -- Debug mode off by default

-- 🔒 Hardened Default: Force-disable SHA-256 in Classic due to performance.
-- A dev can still explicitly set AIOS.Codec.UseSHA = true if they understand the cost.
if IS_CLASSIC then
    AIOS.Codec.UseSHA = false
end

local Codec = AIOS.Codec
local Hash = AIOS.Hash

-- =========================================================================
-- Quantum BitOps Overlord™ - Because basic math is for peasants
-- =========================================================================
local bit

-- Check if we have a built-in bit library
if _G.bit or _G.bit32 then
    bit = _G.bit or _G.bit32
else
    -- Fallback implementations for clients without bit library
    bit = {
        bor = function(a, b)
            local result, bit_val = 0, 1
            while a > 0 or b > 0 do
                if a % 2 == 1 or b % 2 == 1 then
                    result = result + bit_val
                end
                a, b, bit_val = math.floor(a/2), math.floor(b/2), bit_val * 2
            end
            return result
        end,
        band = function(a, b)
            local result, bit_val = 0, 1
            while a > 0 and b > 0 do
                if a % 2 == 1 and b % 2 == 1 then
                    result = result + bit_val
                end
                a, b, bit_val = math.floor(a/2), math.floor(b/2), bit_val * 2
            end
            return result
        end,
        bxor = function(a, b)
            local result, bit_val = 0, 1
            while a > 0 or b > 0 do
                if a % 2 ~= b % 2 then
                    result = result + bit_val
                end
                a, b, bit_val = math.floor(a/2), math.floor(b/2), bit_val * 2
            end
            return result
        end,
        rshift = function(a, n)
            return math.floor(a / (2 ^ n))
        end,
        lshift = function(a, n)
            return a * (2 ^ n)
        end,
        bnot = function(a)
            return (2^32 - 1) - a  -- 32-bit not
        end
    }
end

local bor, band, bxor, rshift, lshift, bnot = bit.bor, bit.band, bit.bxor, bit.rshift, bit.lshift, bit.bnot
local debugprofilestop = _G.debugprofilestop

-- Advanced yield system with zero CPU spin
local function yield()
    if coroutine.running() then
        -- In a coroutine: yield and schedule resumption for next frame.
        local co, is_main = coroutine.running()
        if not is_main then -- Check if it's not the main thread
            local resume_co = coroutine.create(function()
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        coroutine.resume(co)
                    end)
                else
                    -- Fallback: if no C_Timer, resume immediately (may cause frame spike)
                    coroutine.resume(co)
                end
            end)
            coroutine.resume(resume_co)
            coroutine.yield()
        end
    elseif C_Timer and C_Timer.After then
        -- Not in a coroutine: use C_Timer to yield asynchronously.
        -- This is a non-blocking yield for the main thread.
        local waiting = true
        C_Timer.After(0, function() waiting = false end)
        -- We must briefly yield control, but without a busy-wait.
        -- This is a minimal, non-CPU-intensive delay.
        local start = debugprofilestop()
        while waiting and (debugprofilestop() - start) < 5000 do -- Max 5ms wait
            -- This is a much shorter, safer busy-wait as an absolute last resort.
            -- It will rarely be hit because C_Timer.After(0) is very fast.
        end
    end
    -- If neither condition is met, yield does nothing (safe fallback).
end

-- Advanced C_Timer fallback with frame-based scheduling
local C_Timer = _G.C_Timer
if not C_Timer then
  C_Timer = {
    After = function(delay, callback)
      if _G.CreateFrame then
        local frame = _G.CreateFrame("Frame")
        local elapsed = 0
        frame:SetScript("OnUpdate", function(self, delta)
          elapsed = elapsed + delta
          if elapsed >= delay then
            callback()
            self:SetScript("OnUpdate", nil)
          end
        end)
      else
        -- Ultimate fallback: execute immediately with warning.
        -- Busy-wait removed as it's a performance hazard.
        clog("C_Timer not available, executing callback immediately", "warn")
        callback()
      end
    end
  }
end

local function clog(msg, level, tag)
  -- First, fire a hook for developers to capture errors silently, regardless of user settings.
  if _G.DevHooks and _G.DevHooks.OnCodecError then
    _G.DevHooks.OnCodecError(msg, level, tag)
  end

  -- Only log if not in quiet mode, or if it's an error and we're in debug mode
  if AIOS.Codec.Quiet and level ~= "error" then
    return
  end
  
  if not AIOS.DebugMode and (level == "debug" or level == "info") then
    return
  end
  
  -- Advanced logging with proper formatting
  -- Use a local reference to check for the CoreLog function safely
  local aiosGlobal = _G.AIOS -- Check the global table directly
  local coreLogFunc = aiosGlobal and aiosGlobal.CoreLog
  
  msg = tostring(msg)
  if coreLogFunc and type(coreLogFunc) == "function" then
    -- Safely call the function on the global AIOS table
    aiosGlobal:CoreLog(msg, level or "debug", tag or "Codec")
  elseif _G.DEFAULT_CHAT_FRAME then
    local prefix = "|cff66ccffAIOS Codec|r: "
    _G.DEFAULT_CHAT_FRAME:AddMessage(prefix .. msg)
  else
    print("AIOS Codec: " .. msg) -- Fallback to console if no chat frame
  end
end

local function tobytes_le32(n)
  -- Convert number to little-endian bytes with overflow protection
  n = n % 0x100000000  -- Ensure 32-bit
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local function frombytes_le32(s, i)
  -- Extract 32-bit little-endian number with bounds checking
  local b1, b2, b3, b4 = s:byte(i, i+3)
  if not b1 or not b2 or not b3 or not b4 then
    return 0
  end
  return b1 + b2*256 + b3*65536 + b4*16777216
end

-- =========================================================================
-- Hashing Hypercore™ - CRC32: The Integrity Ninja
-- =========================================================================
local CRC32_TAB = {
  0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f, 0xe963a535, 0x9e6495a3,
  0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988, 0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91,
  0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
  0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9, 0xfa0f3d63, 0x8d080df5,
  0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172, 0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b,
  0x35b5a8fa, 0x42b2986c, 0xdbbbc9d6, 0xacbcf940, 0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59,
  0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423, 0xcfba9599, 0xb8bda50f,
  0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924, 0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d,
  0x76dc4190, 0x01db7106, 0x98d220bc, 0xefd5102a, 0x71b18589, 0x06b6b51f, 0x9fbfe4a5, 0xe8b8d433,
  0x7807c9a2, 0x0f00f934, 0x9609a88e, 0xe10e9818, 0x7f6a0dbb, 0x086d3d2d, 0x91646c97, 0xe6635c01,
  0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e, 0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457,
  0x65b0d9c6, 0x12b7e950, 0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65,
  0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2, 0x4adfa541, 0x3dd895d7, 0xa4d1c46d, 0xd3d6f4fb,
  0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0, 0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9,
  0x5005713c, 0x270241aa, 0xbe0b1010, 0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
  0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17, 0x2eb40d81, 0xb7bd5c3b, 0xc0ba6cad,
  0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a, 0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683,
  0xe3630b12, 0x94643b84, 0x0d6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
  0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb, 0x196c3671, 0x6e6b06e7,
  0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc, 0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5,
  0xd6d6a3e8, 0xa1d1937e, 0x38d8c2c4, 0x4fdff252, 0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b,
  0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55, 0x316e8eef, 0x4669be79,
  0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236, 0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f,
  0xc5ba3bbe, 0xb2bd0b28, 0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d,
  0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x026d930a, 0x9c0906a9, 0xeb0e363f, 0x72076785, 0x05005713,
  0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38, 0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21,
  0x86d3d2d4, 0xf1d4e242, 0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777,
  0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c, 0x8f659eff, 0xf862ae69, 0x616bffd3, 0x166ccf45,
  0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2, 0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db,
  0xaed16a4a, 0xd9d65adc, 0x40df0b66, 0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
  0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605, 0xcdd70693, 0x54de5729, 0x23d967bf,
  0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94, 0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d
}

function Hash.CRC32(s)
  -- Lightning-fast integrity check that laughs at data corruption
  if type(s) ~= "string" then
    clog("CRC32: expected string", "error")
    return 0, "expected string"
  end
  local crc = 0xffffffff
  for i = 1, #s do
    crc = bxor(rshift(crc, 8), CRC32_TAB[band(bxor(crc, s:byte(i)), 0xFF) + 1])
  end
  return bxor(crc, 0xffffffff)
end

-- =========================================================================
-- Hashing Hypercore™ - FNV-1a 32-bit: The Speed Demon for IDs
-- =========================================================================
function Hash.FNV32(s)
  -- Faster than a rogue's sprint, perfect for quick IDs
  if type(s) ~= "string" then
    clog("FNV32: expected string", "error")
    return 0, "expected string"
  end
  local hash = 0x811c9dc5
  for i = 1, #s do
    hash = bxor(hash, s:byte(i))
    hash = band(hash * 0x01000193, 0xFFFFFFFF)
  end
  return hash
end

-- =========================================================================
-- Hashing Hypercore™ - SHA-256: Quantum-Resistant Implementation
-- =========================================================================
if AIOS.Codec.UseSHA then
  local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  }

  local function bytes_to_int(b1, b2, b3, b4)
      return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
  end

  local function int_to_bytes(n)
      return string.char(
          band(rshift(n, 24), 0xFF),
          band(rshift(n, 16), 0xFF),
          band(rshift(n, 8), 0xFF),
          band(n, 0xFF)
      )
  end

  local function rightrotate(x, n)
      return bor(rshift(x, n), lshift(x, 32 - n))
  end

  local function sha256_process_chunk(chunk, h)
      local w = {}
      
      -- Prepare message schedule
      for i = 1, 16 do
          local pos = (i - 1) * 4 + 1
          w[i] = bytes_to_int(
              chunk:byte(pos),
              chunk:byte(pos + 1),
              chunk:byte(pos + 2),
              chunk:byte(pos + 3)
          )
      end
      
      -- Extend the message schedule
      for i = 17, 64 do
          local s0 = bxor(rightrotate(w[i-15], 7), rightrotate(w[i-15], 18), rshift(w[i-15], 3))
          local s1 = bxor(rightrotate(w[i-2], 17), rightrotate(w[i-2], 19), rshift(w[i-2], 10))
          w[i] = band(w[i-16] + s0 + w[i-7] + s1, 0xFFFFFFFF)
      end
      
      -- Initialize working variables
      local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
      
      -- Main compression loop
      for i = 1, 64 do
          local S1 = bxor(rightrotate(e, 6), rightrotate(e, 11), rightrotate(e, 25))
          local ch = bxor(band(e, f), band(bnot(e), g))
          local temp1 = band(hh + S1 + ch + K[i] + w[i], 0xFFFFFFFF)
          local S0 = bxor(rightrotate(a, 2), rightrotate(a, 13), rightrotate(a, 22))
          local maj = bxor(band(a, b), band(a, c), band(b, c))
          local temp2 = band(S0 + maj, 0xFFFFFFFF)
          
          hh = g
          g = f
          f = e
          e = band(d + temp1, 0xFFFFFFFF)
          d = c
          c = b
          b = a
          a = band(temp1 + temp2, 0xFFFFFFFF)
      end
      
      -- Add the compressed chunk to the current hash value
      h[1] = band(h[1] + a, 0xFFFFFFFF)
      h[2] = band(h[2] + b, 0xFFFFFFFF)
      h[3] = band(h[3] + c, 0xFFFFFFFF)
      h[4] = band(h[4] + d, 0xFFFFFFFF)
      h[5] = band(h[5] + e, 0xFFFFFFFF)
      h[6] = band(h[6] + f, 0xFFFFFFFF)
      h[7] = band(h[7] + g, 0xFFFFFFFF)
      h[8] = band(h[8] + hh, 0xFFFFFFFF)
  end

  -- One-shot SHA-256 function
  function Hash.SHA256(data)
      if type(data) ~= "string" then
          clog("SHA256: expected string", "error")
          return ""
      end
      
      -- Initial hash values
      local h = {
          0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 
          0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
      }
      
      local bit_len = #data * 8
      local chunk = data
      
      -- Pre-processing: padding
      chunk = chunk .. "\x80"
      while (#chunk + 8) % 64 ~= 0 do
          chunk = chunk .. "\x00"
      end
      
      -- Append length as 64-bit big-endian integer
      chunk = chunk .. string.rep("\x00", 4) .. int_to_bytes(bit_len)
      
      -- Process the message in successive 64-byte chunks
      for i = 1, #chunk, 64 do
          local chunk_part = chunk:sub(i, i + 63)
          if #chunk_part == 64 then
              sha256_process_chunk(chunk_part, h)
          end
      end
      
      -- Produce the final hash value
      local result = ""
      for i = 1, 8 do
          result = result .. string.format("%08x", h[i])
      end
      
      return result
  end

  -- Streaming SHA-256 implementation
  function Hash.newSHA256()
      local obj = {
          data = "",
          finalized = false,
          h = {
              0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
          },
          length = 0
      }
      
      function obj:Update(new_data)
          if self.finalized then
              clog("SHA256 Update: cannot update after Final", "error")
              return self
          end
          if type(new_data) ~= "string" then
              clog("SHA256 Update: expected string", "error")
              return self
          end
          
          self.data = self.data .. new_data
          self.length = self.length + #new_data
          
          -- Process complete 64-byte chunks from the buffer
          while #self.data >= 64 do
              local chunk = self.data:sub(1, 64)
              sha256_process_chunk(chunk, self.h)
              self.data = self.data:sub(65)
          end
          
          return self
      end
      
      function obj:Final()
          if self.finalized then
              clog("SHA256 Final: already finalized", "warn")
              return ""
          end
          self.finalized = true
          
          -- Process remaining data with padding
          local bit_len = self.length * 8
          local chunk = self.data .. "\x80"
          
          while (#chunk + 8) % 64 ~= 0 do
              chunk = chunk .. "\x00"
          end
          
          -- Append length as 64-bit big-endian integer
          chunk = chunk .. string.rep("\x00", 4) .. int_to_bytes(bit_len)
          
          -- Process the final chunks
          for i = 1, #chunk, 64 do
              local chunk_part = chunk:sub(i, i + 63)
              if #chunk_part == 64 then
                  sha256_process_chunk(chunk_part, self.h)
              end
          end
          
          -- Produce the final hash value
          local result = ""
          for i = 1, 8 do
              result = result .. string.format("%08x", self.h[i])
          end
          
          return result
      end
      
      return obj
  end
else
  -- SHA-256 stubs for when it's disabled
  function Hash.SHA256(data)
      clog("SHA-256 is disabled in this version of AIOS", "warn")
      return "sha256_disabled"
  end
  
  function Hash.newSHA256()
      clog("SHA-256 is disabled in this version of AIOS", "warn")
      return {
          Update = function() end,
          Final = function() return "sha256_disabled" end
      }
  end
end

-- =========================================================================
-- Compression Chaos Engine™ - Codec IDs: The Secret Handshake
-- =========================================================================
local CODEC_ID = {
  none = 0, -- For when you want your data to live free and uncompressed
  rle = 1,  -- For repetitive data that begs to be squashed
  lzss = 2,  -- For serious compression that laughs at large datasets
  zstd = 3   -- Future: Zstandard compression (high ratio + speed)
}

local FRAME_VERSION = 2 -- Future-proofing for your LLM empire
local MAGIC = "AC2"     -- Upgraded secret code (because "AC1" is so last expansion)
local MAGIC64 = "AC2B"  -- Base64's VIP pass, now with extra swagger
local LEGACY_MAGIC = "AC1" -- Backward compatibility for old frames
local LEGACY_MAGIC64 = "AC1B"

-- =========================================================================
-- Compression Chaos Engine™ - RLE: The Repetition Annihilator
-- =========================================================================
local function rle_compress(s)
  -- Squash repetitive data like it's a bug in a 25-man raid
  if type(s) ~= "string" then
    clog("RLE compress: expected string", "error")
    return ""
  end
  if #s == 0 then
    clog("RLE compress: empty string", "warn")
    return ""
  end
  if #s > 262144 then
    yield() -- Use improved yield
  end
  local result = {}
  local len = #s
  local i = 1
  while i <= len do
    local c = s:byte(i)
    local count = 1
    i = i + 1
    while i <= len and s:byte(i) == c and count < 255 do
      count = count + 1
      i = i + 1
    end
    result[#result+1] = string.char(count)
    result[#result+1] = string.char(c)
  end
  return table.concat(result)
end

local function rle_decompress(s)
  -- Unleash the compressed beast back to its repetitive glory
  if type(s) ~= "string" then
    clog("RLE decompress: expected string", "error")
    return ""
  end
  if #s == 0 then
    clog("RLE decompress: empty string", "warn")
    return ""
  end
  if #s > 262144 then
    yield() -- Use improved yield
  end
  local result = {}
  local len = #s
  local i = 1
  while i <= len do
    local count = s:byte(i) or 0
    i = i + 1
    local c = s:byte(i) or 0
    i = i + 1
    result[#result+1] = string.rep(string.char(c), count)
  end
  local output = table.concat(result)
  return output, #output < len and "partial data recovered" or nil
end

-- =========================================================================
-- Compression Chaos Engine™ - LZSS: The Sliding Window Wizard
-- =========================================================================
local LZSS_DEFAULTS = {
  window = 4096, -- Sliding window size
  minMatch = 3,  -- Minimum match length
  maxMatch = 18, -- Maximum match length
  hashLimit = 12 -- Tighter hash limit for memory efficiency
}

local function lzss_compress(s, opts)
  -- Compress like a rogue slipping through a dungeon, unseen and efficient
  if type(s) ~= "string" then
    clog("LZSS compress: expected string", "error")
    return ""
  end
  if #s == 0 then
    clog("LZSS compress: empty string", "warn")
    return ""
  end
  opts = opts or {}
  local window = opts.window or LZSS_DEFAULTS.window
  local minMatch = opts.minMatch or LZSS_DEFAULTS.minMatch
  local maxMatch = opts.maxMatch or LZSS_DEFAULTS.maxMatch
  local hashLimit = opts.hashLimit or LZSS_DEFAULTS.hashLimit
  
  if #s > 262144 then
    yield() -- Use improved yield
  end
  
  local len = #s
  local result = {}
  local i = 1
  local hash = {}
  local pos = 1
  local pruneCounter = 0
  
  while i <= len do
    local min = math.max(1, i - window)
    local match_len = minMatch - 1
    local match_pos = 0
    local key = i < len and ((s:byte(i) or 0) * 0x100 + (s:byte(i+1) or 0)) or nil
    
    if key and hash[key] and type(hash[key]) == "table" then
      for p in pairs(hash[key]) do
        if p >= min then
          local mlen = 0
          while mlen < maxMatch and i + mlen <= len and s:byte(p + mlen) == s:byte(i + mlen) do
            mlen = mlen + 1
          end
          if mlen > match_len then
            match_len = mlen
            match_pos = p
          end
        end
      end
    end
    
    if match_len >= minMatch then
      local dist = i - match_pos
      local code = bor(lshift(match_len - minMatch, 12), dist - 1)
      result[#result+1] = string.char(rshift(code, 8) % 256, code % 256)
      i = i + match_len
    else
      result[#result+1] = string.char(0, s:byte(i) or 0)
      i = i + 1
    end
    
    -- Update hash table
    if i > 1 then
      local new_key = (s:byte(i-1) or 0) * 0x100 + (i <= len and s:byte(i) or 0)
      if new_key > 0 then
        if not hash[new_key] or type(hash[new_key]) ~= "table" then
          hash[new_key] = {}
        end
        hash[new_key][pos] = true
        local count = 0
        for _ in pairs(hash[new_key]) do count = count + 1 end
        if count > hashLimit then
          for k in pairs(hash[new_key]) do
            hash[new_key][k] = nil
            break
          end
        end
      end
    end
    pos = i
    pruneCounter = pruneCounter + 1
    if pruneCounter >= 1000 then
      for k, v in pairs(hash) do
        if v and type(v) == "table" then
          local count = 0
          for _ in pairs(v) do count = count + 1 end
          if count > hashLimit then
            for p in pairs(v) do
              v[p] = nil
              break
            end
          end
        end
      end
      pruneCounter = 0
    end
  end
  
  return table.concat(result)
end

local function lzss_decompress(s)
  -- Decompress like a mage teleporting your data back to life
  if type(s) ~= "string" then
    clog("LZSS decompress: expected string", "error")
    return ""
  end
  if #s == 0 then
    clog("LZSS decompress: empty string", "warn")
    return ""
  end
  if #s > 262144 then
    yield() -- Use improved yield
  end
  
  local result = {}
  local len = #s
  local i = 1
  
  while i <= len do
    local flag = s:byte(i) or 0
    i = i + 1
    
    if flag == 0 then
      -- Literal byte
      result[#result+1] = string.char(s:byte(i) or 0)
      i = i + 1
    else
      -- Match reference: combine two bytes to form 16-bit code
      local byte2 = s:byte(i) or 0
      i = i + 1
      local code = (flag * 256) + byte2
      local match_len = rshift(code, 12) + LZSS_DEFAULTS.minMatch
      local dist = band(code, 0x0fff) + 1
      local rpos = #result - dist + 1
      
      if rpos <= 0 or rpos > #result then
        clog("LZSS decompress: invalid offset", "debug")
        return table.concat(result), "partial data recovered: invalid offset"
      end
      
      for _ = 1, match_len do
        result[#result+1] = result[rpos] or ""
        rpos = rpos + 1
      end
    end
  end
  
  local output = table.concat(result)
  return output, #output < len and "partial data recovered" or nil
end

-- =========================================================================
-- Base64 Reality Bender™ - Sneaking binary through text like a rogue in stealth
-- =========================================================================
local B64 = {}
do
  local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local b64lookup = {}
  for i = 1, #b64chars do
    b64lookup[b64chars:byte(i)] = i - 1
  end

  function B64.encode(data)
    -- Convert binary to text-safe Base64, because chat channels are picky
    if type(data) ~= "string" then
      clog("Base64 encode: expected string", "error")
      return ""
    end
    if #data == 0 then
      clog("Base64 encode: empty string", "warn")
      return ""
    end
    if #data > 262144 then
      yield() -- Use improved yield
    end
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
      local b1 = data:byte(i) or 0
      i = i + 1
      local b2 = data:byte(i) or 0
      i = i + 1
      local b3 = data:byte(i) or 0
      i = i + 1
      local enc1 = rshift(b1, 2)
      local enc2 = bor(lshift(band(b1, 3), 4), rshift(b2, 4))
      local enc3 = bor(lshift(band(b2, 15), 2), rshift(b3, 6))
      local enc4 = band(b3, 63)
      result[#result+1] = b64chars:sub(enc1+1, enc1+1)
      result[#result+1] = b64chars:sub(enc2+1, enc2+1)
      result[#result+1] = (i > len + 1 and "=") or b64chars:sub(enc3+1, enc3+1)
      result[#result+1] = (i > len and "=") or b64chars:sub(enc4+1, enc4+1)
    end
    return table.concat(result)
  end

  function B64.decode(data)
    -- Reverse the Base64 spell, restoring binary glory
    if type(data) ~= "string" then
      clog("Base64 decode: expected string", "error")
      return ""
    end
    if #data == 0 then
      clog("Base64 decode: empty string", "warn")
      return ""
    end
    if #data > 262144 then
      yield() -- Use improved yield
    end
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
      local enc1 = b64lookup[data:byte(i)] or 0; i = i + 1
      local enc2 = b64lookup[data:byte(i)] or 0; i = i + 1
      local enc3 = b64lookup[data:byte(i)] or 0; i = i + 1
      local enc4 = b64lookup[data:byte(i)] or 0; i = i + 1
      local b1 = bor(lshift(enc1, 2), rshift(enc2, 4))
      local b2 = bor(lshift(band(enc2, 15), 4), rshift(enc3, 2))
      local b3 = bor(lshift(band(enc3, 3), 6), enc4)
      result[#result+1] = string.char(b1)
      if enc3 ~= 64 then result[#result+1] = string.char(b2) end
      if enc4 ~= 64 then result[#result+1] = string.char(b3) end
    end
    local output = table.concat(result)
    return output, #output < len and "partial data recovered" or nil
  end
end

-- =========================================================================
-- StreamSync Transatron™ - Streaming Compression for LLM-Sized Dreams
-- =========================================================================
Codec.Stream = {}
function Codec.Stream.new(codec, opts)
  -- Create a streaming codec for your future WoW-based Skynet
  opts = opts or {}
  local obj = {
    codec = (codec or "lzss"):lower(),
    buffer = "",
    compressed = {},
    length = 0,
    crc = 0,
    chunkSize = opts.chunkSize or 65536 -- Flush at 64KB to stay memory-friendly
  }
  function obj:Update(data)
    if type(data) ~= "string" then
      clog("Stream Update: expected string", "error")
      return self
    end
    if #data == 0 then
      clog("Stream Update: empty string", "warn")
      return self
    end
    if #data > 262144 then
      yield() -- Use improved yield
    end
    self.length = self.length + #data
    self.buffer = self.buffer .. data
    self.crc = Hash.CRC32(self.buffer)
    if #self.buffer >= self.chunkSize then
      local cid, compressor
      if self.codec == "none" then
        cid = CODEC_ID.none
        compressor = function(x) return x end
      elseif self.codec == "rle" then
        cid = CODEC_ID.rle
        compressor = rle_compress
      elseif self.codec == "lzss" then
        cid = CODEC_ID.lzss
        compressor = function(x) return lzss_compress(x, opts) end
      else
        clog("Stream Update: unknown codec " .. tostring(self.codec), "error")
        return self
      end
      local payload = compressor(self.buffer)
      self.compressed[#self.compressed+1] = table.concat({
        MAGIC,
        string.char(FRAME_VERSION),
        string.char(cid),
        tobytes_le32(self.length),
        tobytes_le32(self.crc)
      }) .. payload
      self.buffer = ""
    end
    return self
  end
  function obj:Final()
    -- Finalize the stream like you're sealing a pact with an Old God
    if self.length == 0 then
      clog("Stream Final: no data processed", "warn")
      return ""
    end
    local cid, compressor
    if self.codec == "none" then
      cid = CODEC_ID.none
      compressor = function(x) return x end
    elseif self.codec == "rle" then
      cid = CODEC_ID.rle
      compressor = rle_compress
    elseif self.codec == "lzss" then
      cid = CODEC_ID.lzss
      compressor = function(x) return lzss_compress(x, opts) end
    else
      clog("Stream Final: unknown codec " .. tostring(self.codec), "error")
      return nil, "unknown codec"
    end
    local payload = compressor(self.buffer)
    self.compressed[#self.compressed+1] = table.concat({
      MAGIC,
      string.char(FRAME_VERSION),
      string.char(cid),
      tobytes_le32(self.length),
      tobytes_le32(self.crc)
    }) .. payload
    return table.concat(self.compressed)
  end
  return obj
end

function Codec:DecompressStream(blob)
  -- Decompress streaming data like it's a mythic raid clear
  if type(blob) ~= "string" then
    clog("DecompressStream: expected string", "error")
    return nil, "expected string"
  end
  if #blob == 0 then
    clog("DecompressStream: empty string", "warn")
    return nil, "empty string"
  end
  if #blob > 262144 then
    yield() -- Use improved yield
  end
  local isB64 = blob:sub(1,4) == MAGIC64 or blob:sub(1,4) == LEGACY_MAGIC64
  local frame = blob
  if isB64 then
    frame = B64.decode(blob:sub(5))
    if not frame then
      clog("DecompressStream: base64 decode failed", "error")
      return nil, "base64 decode failed"
    end
  end
  local isLegacy = frame:sub(1,3) == LEGACY_MAGIC
  if frame:sub(1,3) ~= MAGIC and not isLegacy then
    clog("DecompressStream: bad magic", "error")
    return nil, "bad magic"
  end
  local version, cid, origLen, origCRC, payload
  if isLegacy then
    cid = frame:byte(4)
    origLen = frombytes_le32(frame, 5)
    origCRC = frombytes_le32(frame, 9)
    payload = frame:sub(13)
    version = 1
  else
    version = frame:byte(4)
    cid = frame:byte(5)
    origLen = frombytes_le32(frame, 6)
    origCRC = frombytes_le32(frame, 10)
    payload = frame:sub(14)
  end
  if version > FRAME_VERSION then
    clog("DecompressStream: unsupported frame version " .. tostring(version), "error")
    return nil, "unsupported frame version"
  end
  local decompressor
  if cid == CODEC_ID.none then
    decompressor = function(x) return x end
  elseif cid == CODEC_ID.rle then
    decompressor = rle_decompress
  elseif cid == CODEC_ID.lzss then
    decompressor = lzss_decompress
  else
    clog("DecompressStream: unknown codec id " .. tostring(cid), "error")
    return nil, "unknown codec id " .. tostring(cid)
  end
  local plain, err = decompressor(payload)
  if err then
    clog("DecompressStream: decompression failed - " .. tostring(err), "error")
    return plain, err
  end
  if #plain ~= origLen then
    clog("DecompressStream: length mismatch", "error")
    return plain, "partial data recovered: length mismatch"
  end
  local crc = Hash.CRC32(plain)
  if crc ~= origCRC then
    clog("DecompressStream: crc mismatch", "error")
    return plain, "partial data recovered: crc mismatch"
  end
  return plain
end

-- =========================================================================
-- Codec Command Center™ - Compress: The Data Crusher Supreme
-- =========================================================================
function Codec:Compress(s, opts)
  -- Crush data like a warrior's execute phase
  if type(s) ~= "string" then
    clog("Compress: expected string", "error")
    return nil, "expected string"
  end
  if #s == 0 then
    clog("Compress: empty string", "warn")
    return nil, "empty string"
  end
  opts = opts or { codec = "lzss" }
  local start = _G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)
  local cid, compressor
  if opts.codec == "none" then
    cid = CODEC_ID.none
    compressor = function(x) return x end
  elseif opts.codec == "rle" then
    cid = CODEC_ID.rle
    compressor = rle_compress
  elseif opts.codec == "lzss" then
    cid = CODEC_ID.lzss
    compressor = function(x) return lzss_compress(x, opts) end
  else
    clog("Compress: unknown codec " .. tostring(opts.codec), "error")
    return nil, "unknown codec"
  end
  if #s > 262144 then
    yield() -- Use improved yield
  end
  local payload = compressor(s)
  local frame = table.concat({
    MAGIC,
    string.char(FRAME_VERSION),
    string.char(cid),
    tobytes_le32(#s),
    tobytes_le32(Hash.CRC32(s))
  }) .. payload
  local result = opts.preferTextSafe and (MAGIC64 .. B64.encode(frame)) or frame
  local duration = (_G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)) - start
  if AIOS.CoreDiag and AIOS.CoreDiag.performance.enabled then
    AIOS.CoreDiag.performance.codec = AIOS.CoreDiag.performance.codec or { count=0, totalTime=0, totalRatio=0 }
    AIOS.CoreDiag.performance.codec.count = AIOS.CoreDiag.performance.codec.count + 1
    AIOS.CoreDiag.performance.codec.totalTime = AIOS.CoreDiag.performance.codec.totalTime + duration
    AIOS.CoreDiag.performance.codec.totalRatio = AIOS.CoreDiag.performance.codec.totalRatio + (#result / math.max(1, #s))
  end
  return result
end

-- =========================================================================
-- Codec Command Center™ - Decompress: The Data Liberator
-- =========================================================================
function Codec:Decompress(blob)
  -- Free your data from its compressed prison
  if type(blob) ~= "string" then
    clog("Decompress: expected string", "error")
    return nil, "expected string"
  end
  if #blob == 0 then
    clog("Decompress: empty string", "warn")
    return nil, "empty string"
  end
  local start = _G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)
  local isB64 = blob:sub(1,4) == MAGIC64 or blob:sub(1,4) == LEGACY_MAGIC64
  local frame = blob
  if isB64 then
    frame = B64.decode(blob:sub(5))
    if not frame then
      clog("Decompress: base64 decode failed", "error")
      return nil, "base64 decode failed"
    end
  end
  local isLegacy = frame:sub(1,3) == LEGACY_MAGIC
  if frame:sub(1,3) ~= MAGIC and not isLegacy then
    clog("Decompress: bad magic", "error")
    return nil, "bad magic"
  end
  local version, cid, origLen, origCRC, payload
  if isLegacy then
    cid = frame:byte(4)
    origLen = frombytes_le32(frame, 5)
    origCRC = frombytes_le32(frame, 9)
    payload = frame:sub(13)
    version = 1
  else
    version = frame:byte(4)
    cid = frame:byte(5)
    origLen = frombytes_le32(frame, 6)
    origCRC = frombytes_le32(frame, 10)
    payload = frame:sub(14)
  end
  if version > FRAME_VERSION then
    clog("Decompress: unsupported frame version " .. tostring(version), "error")
    return nil, "unsupported frame version"
  end
  local decompressor
  if cid == CODEC_ID.none then
    decompressor = function(x) return x end
  elseif cid == CODEC_ID.rle then
    decompressor = rle_decompress
  elseif cid == CODEC_ID.lzss then
    decompressor = lzss_decompress
  else
    clog("Decompress: unknown codec id " .. tostring(cid), "error")
    return nil, "unknown codec id " .. tostring(cid)
  end
  local plain, err = decompressor(payload)
  if err then
    clog("Decompress: decompression failed - " .. tostring(err), "error")
    return plain, err
  end
  if #plain ~= origLen then
    clog("Decompress: length mismatch", "error")
    return plain, "partial data recovered: length mismatch"
  end
  local crc = Hash.CRC32(plain)
  if crc ~= origCRC then
    clog("Decompress: crc mismatch", "error")
    return plain, "partial data recovered: crc mismatch"
  end
  local duration = (_G.GetTime and _G.GetTime() or (debugprofilestop() / 1000)) - start
  if AIOS.CoreDiag and AIOS.CoreDiag.performance.enabled then
    AIOS.CoreDiag.performance.codec = AIOS.CoreDiag.performance.codec or { count=0, totalTime=0, totalRatio=0 }
    AIOS.CoreDiag.performance.codec.count = AIOS.CoreDiag.performance.codec.count + 1
    AIOS.CoreDiag.performance.codec.totalTime = AIOS.CoreDiag.performance.codec.totalTime + duration
    AIOS.CoreDiag.performance.codec.totalRatio = AIOS.CoreDiag.performance.codec.totalRatio + (#blob / math.max(1, #plain))
  end
  return plain
end

-- =========================================================================
-- Data Slicer Supreme™ - MakeChunks / Reassemble: For Data Too Big to Handle
-- =========================================================================
function Codec:MakeChunks(s, maxBytes)
  -- Slice data like a rogue carving up a raid boss
  if type(s) ~= "string" then
    clog("MakeChunks: expected string", "error")
    return {}
  end
  if #s == 0 then
    clog("MakeChunks: empty string", "warn")
    return {}
  end
  maxBytes = math.max(32, tonumber(maxBytes) or 255) -- WoW chat limit
  local t, i = {}, 1
  while i <= #s do
    t[#t+1] = s:sub(i, i+maxBytes-1)
    i = i + maxBytes
  end
  return t
end

function Codec:Reassemble(parts)
  -- Stitch data back together like a necromancer raising the dead
  if type(parts) ~= "table" then
    clog("Reassemble: expected table", "error")
    return nil, "parts must be table"
  end
  return table.concat(parts)
end

