-------------------------------------------------------------------------------
-- Melda Preset, creates .vstpreset data for MeldaProduction plugins. Their state
-- is XML inside of a zlib stream. Lua has no compression, but zlib also allows
-- uncompressed blocks, which can be written without any library.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local ZLIB_HEADER = string.char(0x78, 0x01)
local MAX_STORED_BLOCK_SIZE = 65535
local ADLER_MODULO = 65521
local VST3_HEADER_SIZE = 48

-- Melda saves its chunks in multiples of this size
local CHUNK_ALIGNMENT = 512

MeldaPreset = {}

local function calculateAdler32(data)
  local sumA = 1
  local sumB = 0
  for index = 1, string.len(data) do
    sumA = (sumA + string.byte(data, index)) % ADLER_MODULO
    sumB = (sumB + sumA) % ADLER_MODULO
  end
  return sumB * 65536 + sumA
end

local function createZlibStream(data)
  local parts = { ZLIB_HEADER }
  local dataSize = string.len(data)
  local offset = 1

  repeat
    local blockSize = math.min(dataSize - offset + 1, MAX_STORED_BLOCK_SIZE)
    local isLastBlock = offset + blockSize > dataSize
    table.insert(parts, string.char(isLastBlock and 1 or 0))
    table.insert(parts, Helpers:intToBinaryLE(blockSize, 2))
    table.insert(parts, Helpers:intToBinaryLE(MAX_STORED_BLOCK_SIZE - blockSize, 2))
    table.insert(parts, string.sub(data, offset, offset + blockSize - 1))
    offset = offset + blockSize
  until offset > dataSize

  table.insert(parts, Helpers:intToBinaryBE(calculateAdler32(data), 4))
  return table.concat(parts)
end

local function padToChunkSize(data)
  local missingBytes = -string.len(data) % CHUNK_ALIGNMENT
  return data .. string.rep(string.char(0), missingBytes)
end

local function createChunkListEntry(chunkId, offset, size)
  return chunkId .. Helpers:intToBinaryLE(offset, 8) .. Helpers:intToBinaryLE(size, 8)
end

-- Melda saves the same state for the component and the controller
function MeldaPreset:create(classId, settingsXml)
  local chunk = padToChunkSize(createZlibStream(settingsXml))
  local chunkSize = string.len(chunk)
  local controllerChunkOffset = VST3_HEADER_SIZE + chunkSize
  local listOffset = controllerChunkOffset + chunkSize

  return table.concat({
    'VST3',
    Helpers:intToBinaryLE(1, 4),
    classId,
    Helpers:intToBinaryLE(listOffset, 8),
    chunk,
    chunk,
    'List',
    Helpers:intToBinaryLE(2, 4),
    createChunkListEntry('Comp', VST3_HEADER_SIZE, chunkSize),
    createChunkListEntry('Cont', controllerChunkOffset, chunkSize),
  })
end

-- Numbers in XML always have a point, independent of the language of the system
function MeldaPreset:formatNumber(number)
  return (string.format('%.12g', number):gsub(',', '.'))
end
