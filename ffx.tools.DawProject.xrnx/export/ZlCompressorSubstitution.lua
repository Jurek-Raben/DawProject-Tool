-------------------------------------------------------------------------------
-- ZL Compressor Substitution, replaces the Compressor and the Bus Compressor of
-- Renoise with the ZL Compressor VST3 plugin, which also is available for Linux.
-- The scales are from its source code and match the values the plugin displays.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

ZL_COMPRESSOR_CLASS_ID = 'ABCDEF019182FAEB5A6C6975436F6D70'

local PARAMETER_THRESHOLD = 602006635
local PARAMETER_RATIO = 108285963
local PARAMETER_KNEE_WIDTH = 1403035594
local PARAMETER_ATTACK = 740224584
local PARAMETER_RELEASE = 1090594823
local PARAMETER_MAKEUP = 1065963785

local MIN_THRESHOLD_DB = -100
local MID_THRESHOLD_DB = -32
local MAX_THRESHOLD_DB = 0
local MIN_RATIO = 1
local MID_RATIO = 3
local MAX_RATIO = 100
local MAX_KNEE_WIDTH_DB = 32
local MAKEUP_RANGE_DB = 30

-- Times are scales from an offset, so they can reach 0 ms
local ATTACK_OFFSET_MS = 20
local MID_ATTACK_MS = 120
local MAX_ATTACK_MS = 1020
local RELEASE_OFFSET_MS = 100
local MID_RELEASE_MS = 600
local MAX_RELEASE_MS = 5100

-- The order of the styles: Clean, Classic, Optical, Vocal
local STYLE_CLASSIC = 1

local NUM_SIDE_FILTERS = 8
local DEFAULT_Q = 0.707
local DEFAULT_FILTER_FREQUENCY = 1000

-- Compression direction Compress, with the plugin defaults for the other values
local GENERAL_PARAMETERS = {
  clipper_drive = 0, comp_delta = 0, comp_direction = 0, comp_on = 1, comp_style = STYLE_CLASSIC, curve = 50,
  external_side = 0, floor = -140, hold = 0, lookahead = 0, oversample = 0, pump = 0, range = 80, range_inf = 0,
  rms_length = 32, rms_mix = 50, rms_on = 0, rms_speed = 1, ['side gain'] = 0, side_eq_bypass = 0, side_out = 0,
  side_stereo_link = 0, side_stereo_mode = 0, side_stereo_swap = 0, side_stereo_wet1 = 100, side_stereo_wet2 = 100,
  smooth = 0, wet = 100,
}

local SIDE_FILTER_PARAMETERS = {
  Q = DEFAULT_Q, filter_status = 0, filter_type = 0, freq = DEFAULT_FILTER_FREQUENCY, gain = 0, order = 1,
}

local INTERFACE_PARAMETERS = {
  analyzer_mag_type = 0, analyzer_max_db = 1, analyzer_min_db = 3, analyzer_move_type = 0, analyzer_stereo = 0,
  analyzer_time_length = 1, computer_curve_display = 1, delta_curve_display = 1, eq_max_db = 1, meter_display = 1,
  post_curve_display = 1, pre_curve_display = 1, rms_analyzer_display = 1, side_chain_curve_display = 0,
  side_control_display = 0, side_eq_display = 0,
}

local function clampToNormalized(value)
  return math.max(0, math.min(value, 1))
end

local function normalizeThreshold(decibels)
  if (decibels < MID_THRESHOLD_DB) then
    return clampToNormalized((decibels - MIN_THRESHOLD_DB) / (MID_THRESHOLD_DB - MIN_THRESHOLD_DB) / 2)
  end
  return clampToNormalized(0.5 + (decibels - MID_THRESHOLD_DB) / (MAX_THRESHOLD_DB - MID_THRESHOLD_DB) / 2)
end

-- The scales are logarithmic in two parts, with the given value in the middle
local function normalizeLogMidRange(value, minValue, midValue, maxValue)
  if (value < midValue) then
    return clampToNormalized(math.log(math.max(value, minValue) / minValue) / (2 * math.log(midValue / minValue)))
  end
  return clampToNormalized(0.5 + math.log(value / midValue) / (2 * math.log(maxValue / midValue)))
end

local function normalizeAttack(milliseconds)
  return normalizeLogMidRange(milliseconds + ATTACK_OFFSET_MS, ATTACK_OFFSET_MS, MID_ATTACK_MS, MAX_ATTACK_MS)
end

local function normalizeRelease(milliseconds)
  return normalizeLogMidRange(milliseconds + RELEASE_OFFSET_MS, RELEASE_OFFSET_MS, MID_RELEASE_MS, MAX_RELEASE_MS)
end


class "ZlCompressorSubstitution"

ZlCompressorSubstitution.classId = ZL_COMPRESSOR_CLASS_ID
ZlCompressorSubstitution.pluginName = 'ZL Compressor'

function ZlCompressorSubstitution:__init(device, scales)
  self.compressor = CompressorParameters(device, scales)
end

function ZlCompressorSubstitution:isUsable()
  return self.compressor:isUsable()
end

function ZlCompressorSubstitution:createPresetData()
  local compressor = self.compressor
  local xmlParts = { '<ParaState><Para>' }

  for filterIndex = 0, NUM_SIDE_FILTERS - 1 do
    for id, value in pairs(SIDE_FILTER_PARAMETERS) do
      table.insert(xmlParts, JucePreset:createParameterXml(id .. filterIndex, value))
    end
  end
  JucePreset:appendParameters(xmlParts, GENERAL_PARAMETERS)
  JucePreset:appendParameters(xmlParts, {
    attack = compressor:getCurrentValue('attack'),
    release = compressor:getCurrentValue('release'),
    threshold = math.max(MIN_THRESHOLD_DB, math.min(compressor:getCurrentThreshold(), MAX_THRESHOLD_DB)),
    ratio = math.max(MIN_RATIO, math.min(compressor:getCurrentValue('ratio'), MAX_RATIO)),
    makeup = math.max(-MAKEUP_RANGE_DB, math.min(compressor:getCurrentValue('makeup'), MAKEUP_RANGE_DB)),
    knee_width = compressor:hasKnee() and compressor:getCurrentValue('knee') or 0,
  })

  table.insert(xmlParts, '</Para><State>')
  JucePreset:appendParameters(xmlParts, INTERFACE_PARAMETERS)
  table.insert(xmlParts, '</State></ParaState>')

  return JucePreset:create(ZL_COMPRESSOR_CLASS_ID, table.concat(xmlParts))
end

function ZlCompressorSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local parameterType, value = self.compressor:readAutomationValue(parameter, parameterNum, automationValue)

  if (parameterType == 'threshold') then
    return { { paramIndex = PARAMETER_THRESHOLD, name = 'Threshold', value = normalizeThreshold(value) } }
  elseif (parameterType == 'ratio') then
    return { {
      paramIndex = PARAMETER_RATIO,
      name = 'Ratio',
      value = normalizeLogMidRange(value, MIN_RATIO, MID_RATIO, MAX_RATIO),
    } }
  elseif (parameterType == 'attack') then
    return { { paramIndex = PARAMETER_ATTACK, name = 'Attack', value = normalizeAttack(value) } }
  elseif (parameterType == 'release') then
    return { { paramIndex = PARAMETER_RELEASE, name = 'Release', value = normalizeRelease(value) } }
  elseif (parameterType == 'makeup') then
    return { {
      paramIndex = PARAMETER_MAKEUP,
      name = 'Makeup Gain',
      value = clampToNormalized((value + MAKEUP_RANGE_DB) / (2 * MAKEUP_RANGE_DB)),
    } }
  elseif (parameterType == 'knee') then
    return { {
      paramIndex = PARAMETER_KNEE_WIDTH,
      name = 'Knee Width',
      value = math.sqrt(clampToNormalized(value / MAX_KNEE_WIDTH_DB)),
    } }
  end
  return {}
end
