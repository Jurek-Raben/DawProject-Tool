-------------------------------------------------------------------------------
-- MCompressor Substitution, replaces the Compressor and the Bus Compressor of
-- Renoise with the MeldaProduction MCompressor VST3 plugin.
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

-- The knee of the Bus Compressor is given in dB, the one of MCompressor as a part of its range
local BUS_MAX_KNEE_DB = 30


class "MCompressorSubstitution"

MCompressorSubstitution.classId = MCOMPRESSOR_CLASS_ID
MCompressorSubstitution.pluginName = 'MCompressor'

function MCompressorSubstitution:__init(device, scales)
  self.compressor = CompressorParameters(device, scales)
end

function MCompressorSubstitution:isUsable()
  return self.compressor:isUsable()
end

function MCompressorSubstitution:createPresetData()
  local format = function(number) return MeldaPreset:formatNumber(number) end
  local storedThreshold = MeldaScales:compressorThresholdToStoredValue(self.compressor:getCurrentThreshold())
  local ratio = math.max(self.compressor:getCurrentValue('ratio'), 1)
  local thresholdText = format(storedThreshold)
  local kneeAttributes = ' #kneemode="Hard"'

  if (self.compressor:hasKnee()) then
    kneeAttributes = ' #kneemode="Soft" #kneesize="' ..
        format(self.compressor:getCurrentValue('knee') / BUS_MAX_KNEE_DB) .. '"'
  end

  return MeldaPreset:create(MCOMPRESSOR_CLASS_ID, table.concat({
    '<?xml version="1.0" encoding="utf-8"?>\n<MCompressorsettings #="1"',
    ' #outputgain="', format(math.max(self.compressor:getCurrentValue('makeup'), MIN_OUTPUT_GAIN_DB)), '"',
    ' #attack="', format(self.compressor:getCurrentValue('attack') / 1000), '"',
    ' #release="', format(self.compressor:getCurrentValue('release') / 1000), '"',
    ' #threshold="', thresholdText, '"',
    ' #ratio="', format(ratio), '"',
    kneeAttributes,
    ' Version="1114112" EditorSize="925,456" LRSplitterSize1="1056" LRSplitterSize2="577" halfgain="0" amplituderatio="0"><graph><Point FlagsB="-113"/>',
    '<Point x="', thresholdText, '" y="', thresholdText, '" FlagsB="-116"/>',
    '<Point x="1" y="', format(storedThreshold ^ (1 - 1 / ratio)), '" FlagsB="-115"/></graph>\n',
    '</MCompressorsettings>\n',
  }))
end

function MCompressorSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local parameterType, value = self.compressor:readAutomationValue(parameter, parameterNum, automationValue)

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
  elseif (parameterType == 'knee') then
    return { { paramIndex = PARAMETER_KNEE_SIZE, name = 'Knee size', value = value / BUS_MAX_KNEE_DB } }
  end
  return {}
end
