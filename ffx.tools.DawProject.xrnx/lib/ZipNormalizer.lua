-------------------------------------------------------------------------------
-- Zip Normalizer, rewrites zip archives into a plain, widely compatible layout
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--
-- Streaming zip writers (e.g. bsdtar / libarchive) leave CRC and sizes in the
-- local file headers empty and write them into a data descriptor behind the
-- data. Readers that rely on the local headers (e.g. Cubase when loading the
-- plugin presets of a .dawproject) then read empty files.
--
-- The normalizer rewrites the archive without recompressing anything:
--  - every local header gets CRC and sizes from the central directory
--  - data descriptors, extra fields and file comments are dropped
--  - directory entries are dropped
--  - optionally, given files are moved to the end of the archive
-- Zip64 archives and archives larger than 4 GB are not supported.
--
-- Pure Lua, no dependencies, works with Lua 5.1 / LuaJIT and newer.
--
-- Usage:
--   local ZipNormalizer = require('ZipNormalizer')
--   local success, reason = ZipNormalizer.normalizeFile('in.zip')            -- in place
--   local success, reason = ZipNormalizer.normalizeFile('in.zip', 'out.zip')
--   local data, reason = ZipNormalizer.normalizeData(zipData, { trailingFiles = { 'project.xml' } })
-------------------------------------------------------------------------------

local ZipNormalizer = {}

local LOCAL_HEADER = 'PK\3\4'
local CENTRAL_HEADER = 'PK\1\2'
local END_OF_CENTRAL_DIR = 'PK\5\6'
local FLAG_DATA_DESCRIPTOR = 8
local MAX_U16 = 0xFFFF
local MAX_U32 = 0xFFFFFFFF

local function readU16(data, pos)
  local b1, b2 = data:byte(pos, pos + 1)
  return b1 + b2 * 256
end

local function readU32(data, pos)
  local b1, b2, b3, b4 = data:byte(pos, pos + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function writeU16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function writeU32(value)
  return string.char(value % 256, math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

-- Returns the 1-based position of the end of central directory record
local function findEndOfCentralDir(data)
  -- the record is 22 bytes plus a comment of at most 65535 bytes
  local lowest = math.max(1, #data - 21 - 65535)
  for pos = #data - 21, lowest, -1 do
    if (data:sub(pos, pos + 3) == END_OF_CENTRAL_DIR) then
      return pos
    end
  end
  return nil
end

-- Reads all file entries of the central directory, directory entries are skipped
local function readCentralDir(data, endPos)
  local numEntries = readU16(data, endPos + 10)
  local centralDirOffset = readU32(data, endPos + 16)
  if (numEntries == MAX_U16 or centralDirOffset == MAX_U32) then
    return nil, 'zip64 archives are not supported'
  end

  local entries = {}
  local pos = centralDirOffset + 1
  for _ = 1, numEntries do
    if (data:sub(pos, pos + 3) ~= CENTRAL_HEADER) then
      return nil, 'invalid central directory'
    end
    local nameLength = readU16(data, pos + 28)
    local extraLength = readU16(data, pos + 30)
    local commentLength = readU16(data, pos + 32)
    local entry = {
      versionMadeBy = readU16(data, pos + 4),
      versionNeeded = readU16(data, pos + 6),
      flags = readU16(data, pos + 8),
      method = readU16(data, pos + 10),
      time = readU16(data, pos + 12),
      date = readU16(data, pos + 14),
      crc = readU32(data, pos + 16),
      compressedSize = readU32(data, pos + 20),
      uncompressedSize = readU32(data, pos + 24),
      internalAttributes = readU16(data, pos + 36),
      externalAttributes = readU32(data, pos + 38),
      localHeaderOffset = readU32(data, pos + 42),
      name = data:sub(pos + 46, pos + 45 + nameLength),
    }
    if (entry.compressedSize == MAX_U32 or entry.uncompressedSize == MAX_U32
          or entry.localHeaderOffset == MAX_U32) then
      return nil, 'zip64 archives are not supported'
    end
    if (entry.name:sub(-1) ~= '/') then
      table.insert(entries, entry)
    end
    pos = pos + 46 + nameLength + extraLength + commentLength
  end
  return entries
end

-- Returns the compressed data of an entry, located behind its local header
local function readEntryData(data, entry)
  local pos = entry.localHeaderOffset + 1
  if (data:sub(pos, pos + 3) ~= LOCAL_HEADER) then
    return nil
  end
  local dataPos = pos + 30 + readU16(data, pos + 26) + readU16(data, pos + 28)
  if (dataPos + entry.compressedSize - 1 > #data) then
    return nil
  end
  return data:sub(dataPos, dataPos + entry.compressedSize - 1)
end

-- Moves the trailing files to the end, in the given order. The sort is stable,
-- all other entries keep their order.
local function sortEntries(entries, trailingFiles)
  local ranks = {}
  for rank, name in ipairs(trailingFiles or {}) do
    ranks[name] = rank
  end
  for index, entry in ipairs(entries) do
    entry.sortKey = (ranks[entry.name] or 0) * (#entries + 1) + index
  end
  table.sort(entries, function(a, b) return a.sortKey < b.sortKey end)
end

-- Returns the normalized archive as string, or nil and a reason.
-- options.trailingFiles: optional list of entry names that are moved to the end of the archive
function ZipNormalizer.normalizeData(data, options)
  options = options or {}

  local endPos = findEndOfCentralDir(data)
  if (endPos == nil) then
    return nil, 'end of central directory not found'
  end
  local entries, reason = readCentralDir(data, endPos)
  if (entries == nil) then
    return nil, reason
  end
  if (#entries >= MAX_U16) then
    return nil, 'zip64 archives are not supported'
  end
  sortEntries(entries, options.trailingFiles)

  local localParts = {}
  local centralParts = {}
  local offset = 0
  for _, entry in ipairs(entries) do
    local entryData = readEntryData(data, entry)
    if (entryData == nil) then
      return nil, 'invalid local header of ' .. entry.name
    end
    local flags = entry.flags
    if (math.floor(flags / FLAG_DATA_DESCRIPTOR) % 2 == 1) then
      flags = flags - FLAG_DATA_DESCRIPTOR
    end
    local sharedFields = writeU16(entry.versionNeeded) .. writeU16(flags) .. writeU16(entry.method)
        .. writeU16(entry.time) .. writeU16(entry.date) .. writeU32(entry.crc)
        .. writeU32(entry.compressedSize) .. writeU32(entry.uncompressedSize)
        .. writeU16(#entry.name) .. writeU16(0)

    local localHeader = LOCAL_HEADER .. sharedFields .. entry.name
    table.insert(localParts, localHeader)
    table.insert(localParts, entryData)

    table.insert(centralParts, CENTRAL_HEADER .. writeU16(entry.versionMadeBy) .. sharedFields
      .. writeU16(0) .. writeU16(0) .. writeU16(entry.internalAttributes)
      .. writeU32(entry.externalAttributes) .. writeU32(offset) .. entry.name)

    offset = offset + #localHeader + #entryData
  end

  local centralDir = table.concat(centralParts)
  if (offset + #centralDir > MAX_U32) then
    return nil, 'archives larger than 4 GB are not supported'
  end
  local endOfCentralDir = END_OF_CENTRAL_DIR .. writeU16(0) .. writeU16(0)
      .. writeU16(#entries) .. writeU16(#entries) .. writeU32(#centralDir) .. writeU32(offset) .. writeU16(0)

  return table.concat(localParts) .. centralDir .. endOfCentralDir
end

-- Normalizes the zip file at inputPath and writes it to outputPath, or in place without outputPath.
-- Returns true, or false and a reason. On failure the output file is not written.
function ZipNormalizer.normalizeFile(inputPath, outputPath, options)
  local file = io.open(inputPath, 'rb')
  if (file == nil) then
    return false, 'archive not found: ' .. inputPath
  end
  local data = file:read('*a')
  file:close()

  local normalized, reason = ZipNormalizer.normalizeData(data, options)
  if (normalized == nil) then
    return false, reason
  end

  outputPath = outputPath or inputPath
  file = io.open(outputPath, 'wb')
  if (file == nil) then
    return false, 'archive not writable: ' .. outputPath
  end
  file:write(normalized)
  file:close()
  return true
end

return ZipNormalizer
