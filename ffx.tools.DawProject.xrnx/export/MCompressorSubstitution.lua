-------------------------------------------------------------------------------
-- MCompressor Substitution, replaces the Compressor and the Bus Compressor of
-- Renoise with the MeldaProduction MCompressor VST3 plugin. Both devices have
-- their own scales, which were compared with the values Renoise displays.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

MCOMPRESSOR_CLASS_ID = '4D656C646170726F4D4165314D416531'

local PARAMETER_OUTPUT_GAIN = 1
local PARAMETER_ATTACK = 2
local PARAMETER_RELEASE = 3
local PARAMETER_THRESHOLD = 5
local PARAMETER_RATIO = 6
local PARAMETER_KNEE_SIZE = 8

local MIN_OUTPUT_GAIN_DB = -24

-- The threshold of the Compressor is saved in a logarithmic unit. Only one point could be compared
-- so far, so its displayed value is preferred if possible.
local LOG_THRESHOLD_DB_PER_UNIT = 12.09

local BUS_MAX_KNEE_DB = 30

local function getLogThresholdDecibels(parameter, plainValue)
  if (parameter.value_max <= 0) then
    return plainValue
  end
  return (plainValue - parameter.value_max) * LOG_THRESHOLD_DB_PER_UNIT
end

local function identity(_, plainValue)
  return plainValue
end

-- Converts the values of a Renoise device into dB, ratio and milliseconds
local COMPRESSOR_SCALES = {
  threshold = getLogThresholdDecibels,
  ratio = identity,
  attack = identity,
  release = identity,
  makeup = function(_, amplitude) return MeldaScales:amplitudeToDecibels(amplitude) end,
}

local BUS_COMPRESSOR_SCALES = {
  threshold = identity,
  ratio = function(_, position) return 1 / (1 - 0.95 * position) end,
  attack = function(_, position) return 0.1 + 999.9 * position ^ 2 end,
  release = function(_, position) return 1 + 1999 * position ^ 2 end,
  makeup = function(_, position) return position * 5 / 3 end,
  knee = function(_, decibels) return decibels / BUS_MAX_KNEE_DB end,
}

local function getParameterType(parameterName)
  local lowercaseName = parameterName:lower()
  for _, parameterType in ipairs({ 'threshold', 'ratio', 'attack', 'release', 'knee' }) do
    if (string.find(lowercaseName, parameterType, 1, true)) then
      return parameterType
    end
  end
  if (string.find(lowercaseName, 'make', 1, true) or string.find(lowercaseName, 'gain', 1, true)) then
    return 'makeup'
  end
  return nil
end


class "MCompressorSubstitution"

MCompressorSubstitution.classId = MCOMPRESSOR_CLASS_ID
MCompressorSubstitution.pluginName = 'MCompressor'

function MCompressorSubstitution:__init(device, scales)
  self.device = device
  self.scales = scales
  self.parameterNums = {}
  self.parameterTypes = {}

  for parameterNum = 1, #device.parameters do
    local parameterType = getParameterType(device:parameter(parameterNum).name)
    if (parameterType ~= nil and self.parameterNums[parameterType] == nil) then
      self.parameterNums[parameterType] = parameterNum
      self.parameterTypes[parameterNum] = parameterType
    end
  end
end

function MCompressorSubstitution:isUsable()
  for parameterType in pairs(self.scales) do
    if (self.parameterNums[parameterType] == nil) then
      return false
    end
  end
  return true
end

function MCompressorSubstitution:getCurrentValue(parameterType)
  local parameter = self.device:parameter(self.parameterNums[parameterType])
  return self.scales[parameterType](parameter, parameter.value)
end

-- Renoise displays the threshold in dB, independent of how the device saves it
function MCompressorSubstitution:getCurrentThreshold()
  local parameter = self.device:parameter(self.parameterNums.threshold)
  local displayedDecibels = tonumber(parameter.value_string:match('^%s*(-?[%d.]+)'))
  return displayedDecibels or self:getCurrentValue('threshold')
end

function MCompressorSubstitution:createPresetData()
  local format = function(number) return MeldaPreset:formatNumber(number) end
  local storedThreshold = MeldaScales:compressorThresholdToStoredValue(self:getCurrentThreshold())
  local ratio = math.max(self:getCurrentValue('ratio'), 1)
  local thresholdText = format(storedThreshold)
  local kneeAttributes = ' #kneemode="Hard"'

  if (self.scales.knee ~= nil) then
    kneeAttributes = ' #kneemode="Soft" #kneesize="' .. format(self:getCurrentValue('knee')) .. '"'
  end

  return MeldaPreset:create(MCOMPRESSOR_CLASS_ID, table.concat({
    '<?xml version="1.0" encoding="utf-8"?>\n<MCompressorsettings #="1"',
    ' #outputgain="', format(math.max(self:getCurrentValue('makeup'), MIN_OUTPUT_GAIN_DB)), '"',
    ' #attack="', format(self:getCurrentValue('attack') / 1000), '"',
    ' #release="', format(self:getCurrentValue('release') / 1000), '"',
    ' #threshold="', thresholdText, '"',
    ' #ratio="', format(ratio), '"',
    kneeAttributes,
    ' Version="1114112" EditorSize="925,456" LRSplitterSize1="1056" LRSplitterSize2="577" halfgain="0" amplituderatio="0"><graph><Point FlagsB="-113"/>',
    '<Point x="', thresholdText, '" y="', thresholdText, '" FlagsB="-116"/>',
    '<Point x="1" y="', format(storedThreshold ^ (1 - 1 / ratio)), '" FlagsB="-115"/></graph>\n',
    '</MCompressorsettings>\n',
  }))
end

-- Automation values are normalized. They are treated as linear in the range of the parameter.
function MCompressorSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local parameterType = self.parameterTypes[parameterNum]
  local scale = self.scales[parameterType]
  if (scale == nil) then
    return {}
  end

  local plainValue = parameter.value_min + automationValue * (parameter.value_max - parameter.value_min)
  local value = scale(parameter, plainValue)

  if (parameterType == 'threshold') then
    return { { paramIndex = PARAMETER_THRESHOLD, name = 'Threshold', value = MeldaScales:normalizeCompressorThreshold(value) } }
  elseif (parameterType == 'ratio') then
    return { { paramIndex = PARAMETER_RATIO, name = 'Ratio', value = MeldaScales:normalizeCompressorRatio(value) } }
  elseif (parameterType == 'attack') then
    return { { paramIndex = PARAMETER_ATTACK, name = 'Attack', value = MeldaScales:normalizeCompressorTime(value) } }
  elseif (parameterType == 'release') then
    return { { paramIndex = PARAMETER_RELEASE, name = 'Release', value = MeldaScales:normalizeCompressorTime(value) } }
  elseif (parameterType == 'makeup') then
    return { { paramIndex = PARAMETER_OUTPUT_GAIN, name = 'Output gain', value = MeldaScales:normalizeGain(value) } }
  end
  return { { paramIndex = PARAMETER_KNEE_SIZE, name = 'Knee size', value = value } }
end

function MCompressorSubstitution:createForCompressor(device)
  return MCompressorSubstitution(device, COMPRESSOR_SCALES)
end

function MCompressorSubstitution:createForBusCompressor(device)
  return MCompressorSubstitution(device, BUS_COMPRESSOR_SCALES)
end
