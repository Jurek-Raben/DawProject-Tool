-------------------------------------------------------------------------------
-- ZL Equalizer Substitution, replaces the Renoise EQ 5 and EQ 10 with the ZL Equalizer 2
-- VST3 plugin, which also is available for Linux. Its state is the XML of its
-- JUCE parameters. The scales are from its source code and match the values the
-- plugin displays.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

ZL_EQUALIZER_CLASS_ID = 'ABCDEF019182FAEB5A6C697545717532'

local VST3_HEADER_SIZE = 48
local NUM_PLUGIN_BANDS = 24

-- The ids of band 1, the ones of the following bands are consecutive
local FIRST_FREQUENCY_ID = 97695928
local FIRST_GAIN_ID = 98116753
local FIRST_Q_ID = 3551

local FILTER_STATUS_OFF = 0
local FILTER_STATUS_ON = 2
local FILTER_TYPE_PEAK = 0
local FILTER_TYPE_LOW_SHELF = 1
local FILTER_TYPE_HIGH_SHELF = 3

local GAIN_RANGE_DB = 30
local MIN_FREQUENCY = 10
local MID_FREQUENCY = 1000
local MAX_FREQUENCY = 160000
local MIN_Q = 0.025
local MID_Q = 0.707
local MAX_Q = 25

local DEFAULT_FREQUENCY = 1000

-- Parameters which all bands have in common
local COMMON_BAND_PARAMETERS = {
  attack = 100, dynamic_learn = 0, dynamic_on = 0, dynamic_relative = 0, dynamic_rms_length = 0,
  dynamic_rms_mix = 50, dynamic_smooth = 100, knee_width = 8, lr_mode = 0, order = 1, release = 500,
  side_filter_type = 0, side_freq = 1000, side_link = 0, side_order = 1, side_q = MID_Q, side_swap = 0,
  target_gain = 0, threshold = -40,
}

local GLOBAL_PARAMETERS = {
  total_auto_gain = 0, total_bypass = 0, total_external_side = 0, total_filter_structure = 0,
  total_gain_scale = 100, total_lookahead = 0, total_output_gain = 0, total_phase_flip = 0, total_static_gain = 0,
}

local INTERFACE_PARAMETERS = {
  collision_on = 0, collision_strength = 0.5, eq_max_db = 1, fft_freeze_on = 0, fft_min_db = 0, fft_post_on = 1,
  fft_pre_on = 1, fft_side_on = 0, fft_smooth_erb_value = 1, fft_smooth_oct_value = 1, fft_smooth_type = 1,
  fft_speed = 2, fft_stereo = 0, fft_tilt = 3,
}

-- JUCE stores the state of its bypass parameter behind the state of the plugin
local JUCE_PRIVATE_DATA = string.rep(string.char(0), 9) .. 'JUCEPrivateData' ..
    string.char(0, 1, 1) .. 'Bypass' .. string.char(0, 1, 1, 3, 0, 0x1d, 0, 0, 0, 0, 0, 0, 0) .. 'JUCEPrivateData'

local function clampToNormalized(value)
  return math.max(0, math.min(value, 1))
end

-- The plugin scales are logarithmic in two parts, with the given value in the middle
local function normalizeLogMidRange(value, minValue, midValue, maxValue)
  if (value < midValue) then
    return clampToNormalized(math.log(math.max(value, minValue) / minValue) / (2 * math.log(midValue / minValue)))
  end
  return clampToNormalized(0.5 + math.log(value / midValue) / (2 * math.log(maxValue / midValue)))
end

local function createParameterXml(id, value)
  return '<PARAM id="' .. id .. '" value="' .. MeldaPreset:formatNumber(value) .. '"/>'
end

local function appendParameters(xmlParts, parameters)
  for id, value in pairs(parameters) do
    table.insert(xmlParts, createParameterXml(id, value))
  end
end

local function createPresetFile(settingsXml)
  local state = 'VC2!' .. Helpers:intToBinaryLE(string.len(settingsXml), 4) .. settingsXml .. JUCE_PRIVATE_DATA
  local stateSize = string.len(state)
  local listOffset = VST3_HEADER_SIZE + stateSize

  return table.concat({
    'VST3',
    Helpers:intToBinaryLE(1, 4),
    ZL_EQUALIZER_CLASS_ID,
    Helpers:intToBinaryLE(listOffset, 8),
    state,
    'List',
    Helpers:intToBinaryLE(2, 4),
    'Comp', Helpers:intToBinaryLE(VST3_HEADER_SIZE, 8), Helpers:intToBinaryLE(stateSize, 8),
    'Cont', Helpers:intToBinaryLE(listOffset, 8), Helpers:intToBinaryLE(0, 8),
  })
end


class "ZlEqualizerSubstitution"

ZlEqualizerSubstitution.classId = ZL_EQUALIZER_CLASS_ID
ZlEqualizerSubstitution.pluginName = 'ZL Equalizer 2'

function ZlEqualizerSubstitution:__init(device, config, layout)
  self.eq = EqParameters(device, config, layout)
end

function ZlEqualizerSubstitution:isUsable()
  return self.eq:isUsable()
end

function ZlEqualizerSubstitution:getBandQ(band, bandwidth)
  local q = self.eq:isShelf(band) and MeldaScales:shelfBandwidthToQ(bandwidth) or
      MeldaScales:peakBandwidthToQ(bandwidth)
  return math.max(MIN_Q, math.min(self.eq:applyQFactor(q), MAX_Q))
end

function ZlEqualizerSubstitution:getFilterType(band)
  if (band == 1) then
    return FILTER_TYPE_LOW_SHELF
  elseif (band == self.eq.numBands) then
    return FILTER_TYPE_HIGH_SHELF
  end
  return FILTER_TYPE_PEAK
end

-- The plugin has more bands than the Renoise EQs, the others stay off. Their numbers start with 0.
function ZlEqualizerSubstitution:appendBandParameters(xmlParts, band)
  local suffix = tostring(band - 1)
  local isUsed = band <= self.eq.numBands

  for id, value in pairs(COMMON_BAND_PARAMETERS) do
    table.insert(xmlParts, createParameterXml(id .. suffix, value))
  end

  table.insert(xmlParts, createParameterXml('dynamic_bypass' .. suffix, isUsed and 1 or 0))
  table.insert(xmlParts, createParameterXml('filter_status' .. suffix, isUsed and FILTER_STATUS_ON or FILTER_STATUS_OFF))
  table.insert(xmlParts, createParameterXml('filter_type' .. suffix, isUsed and self:getFilterType(band) or FILTER_TYPE_PEAK))
  table.insert(xmlParts, createParameterXml('freq' .. suffix, isUsed and self.eq:getValue('frequency', band) or DEFAULT_FREQUENCY))
  table.insert(xmlParts, createParameterXml('gain' .. suffix, isUsed and self.eq:getValue('gain', band) or 0))
  table.insert(xmlParts, createParameterXml('q' .. suffix,
    isUsed and self:getBandQ(band, self.eq:getValue('bandwidth', band)) or MID_Q))
end

function ZlEqualizerSubstitution:createPresetData()
  local xmlParts = { '<?xml version="1.0" encoding="UTF-8"?>\n<ZLCompressorParaState><ZLEqualizerParameters>' }

  for band = 1, NUM_PLUGIN_BANDS do
    self:appendBandParameters(xmlParts, band)
  end
  appendParameters(xmlParts, GLOBAL_PARAMETERS)

  table.insert(xmlParts, '</ZLEqualizerParameters><ZLEqualizerNAParameters>')
  appendParameters(xmlParts, INTERFACE_PARAMETERS)
  table.insert(xmlParts, '</ZLEqualizerNAParameters></ZLCompressorParaState>')

  return createPresetFile(table.concat(xmlParts))
end

function ZlEqualizerSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local target = self.eq:findTarget(parameterNum)
  if (target == nil) then
    return {}
  end

  local bandOffset = target.band - 1
  local value = self.eq:getAutomatedValue(parameter, target, automationValue)

  if (target.type == 'frequency') then
    return { {
      paramIndex = FIRST_FREQUENCY_ID + bandOffset,
      name = 'Freq' .. bandOffset,
      value = normalizeLogMidRange(value, MIN_FREQUENCY, MID_FREQUENCY, MAX_FREQUENCY),
    } }
  elseif (target.type == 'gain') then
    return { {
      paramIndex = FIRST_GAIN_ID + bandOffset,
      name = 'Gain' .. bandOffset,
      value = clampToNormalized((value + GAIN_RANGE_DB) / (2 * GAIN_RANGE_DB)),
    } }
  end

  return { {
    paramIndex = FIRST_Q_ID + bandOffset,
    name = 'Q' .. bandOffset,
    value = normalizeLogMidRange(self:getBandQ(target.band, value), MIN_Q, MID_Q, MAX_Q),
  } }
end
