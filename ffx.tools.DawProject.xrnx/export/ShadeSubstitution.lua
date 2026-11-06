-------------------------------------------------------------------------------
-- Shade Substitution, replaces the Renoise EQ 5 and EQ 10 with the UVI Shade VST3 plugin.
-- The state of Shade is JSON inside of a VST2 style chunk. Its parameters are
-- assigned by the preset, so the ids of the bands below only are valid for the
-- slots written by this file.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

SHADE_CLASS_ID = '5653544372466C736861646500000000'

local VST3_HEADER_SIZE = 48

-- The size of the plugin window
local EDITOR_WIDTH = 1686
local EDITOR_HEIGHT = 898
local CHUNK_BANK_PADDING = string.rep(string.char(0), 132)

-- JUCE stores the state of its bypass parameter behind the state of the plugin
local JUCE_PRIVATE_DATA = string.rep(string.char(0), 8) .. 'JUCEPrivateData' ..
    string.char(0, 1, 1) .. 'Bypass' .. string.char(0, 1, 1, 3, 0, 0x1d, 0, 0, 0, 0, 0, 0, 0) .. 'JUCEPrivateData'

local GENERAL_SLOTS = {
  '/Gain In', '/Gain Out', '/Mix', '/Trigger/Mode', '/Trigger/Sensitivity', '/Trigger/Rate',
  '/Trigger/Source', '/Limiter/Enabled', '/Limiter/Threshold', '/PitchDetector/Mode',
  '/PitchDetector/Source', '/PitchDetector/Sensitivity',
}

local FILTER_SLOT_FIELDS = {
  'Enabled', 'MidSide', 'L', 'R', 'C', 'Lss', 'Rss', 'Lsr', 'Rsr', 'LFE', 'Frequency', 'Gain', 'Slope', 'Q-Width',
}
local SHELF_SLOT_FIELD_COUNT = 13

-- The slots of the filters with the parameter ids of the fields a band can automate
local LOW_SHELF_SLOTS = { filterType = 'Low Shelf/Eq-ing', firstSlot = 139, frequencyId = 48758, gainId = 48780, slopeId = 48781 }
local HIGH_SHELF_SLOTS = { filterType = 'High Shelf/Eq-ing', firstSlot = 152, frequencyId = 48813, gainId = 48814, slopeId = 48815 }
local PEAK_SLOTS = {
  { filterType = 'Peak/Eq-ing', firstSlot = 55, frequencyId = 1727, gainId = 1728, qId = 1730 },
  { filterType = 'Peak/Eq-ing', firstSlot = 83, frequencyId = 1818, gainId = 1819, qId = 1821 },
  { filterType = 'Peak/Eq-ing', firstSlot = 97, frequencyId = 48632, gainId = 48633, qId = 48656 },
  { filterType = 'Peak/Eq-ing', firstSlot = 12, frequencyId = 1600, gainId = 1601, qId = 1603 },
  { filterType = 'Peak/Eq-ing', firstSlot = 26, frequencyId = 1635, gainId = 1636, qId = 1638 },
  { filterType = 'Peak/Eq-ing', firstSlot = 40, frequencyId = 1691, gainId = 1692, qId = 1694 },
  { filterType = 'Peak/Eq-ing', firstSlot = 111, frequencyId = 48688, gainId = 48689, qId = 48691 },
  { filterType = 'Peak/Eq-ing', firstSlot = 125, frequencyId = 48723, gainId = 48724, qId = 48726 },
}

local function createBandSlots(numBands)
  local bands = { LOW_SHELF_SLOTS }
  for peakIndex = 1, numBands - 2 do
    table.insert(bands, PEAK_SLOTS[peakIndex])
  end
  table.insert(bands, HIGH_SHELF_SLOTS)
  return bands
end

-- Peak filters don't use their slope
local PEAK_SLOPE = 6

local MIN_FREQUENCY = 10
local MAX_FREQUENCY = 30000
local GAIN_RANGE_DB = 30

-- The shelves of the Renoise EQs use a range from 0 to 1, where 1 is a slope of 12 dB per octave.
-- Linear down to the lowest slope of Shade is an assumption.
local MIN_SHELF_SLOPE = 2
local MAX_SHELF_SLOPE = 12
local MAX_SLOPE = 40
local MIN_Q = 0.02
local MAX_Q = 22.4

-- The slope in dB per octave at the normalized positions 0, 0.025, 0.05 ... 0.875
local SLOPE_BY_NORMALIZED_POSITION = {
  2, 2.23, 2.47, 2.71, 2.96, 3.22, 3.48, 3.75, 4.04, 4.33, 4.64, 4.96, 5.3, 5.65, 6.02, 6.42,
  6.84, 7.29, 7.78, 8.3, 8.87, 9.48, 10.2, 10.9, 11.7, 12.7, 13.7, 14.9, 16.3, 17.9, 19.8,
  22.1, 25, 28.7, 33.5, 40.3,
}
local NORMALIZED_POSITIONS_PER_SLOPE_STEP = 0.025

local function clampToNormalized(value)
  return math.max(0, math.min(value, 1))
end

local function normalizeFrequency(frequency)
  return clampToNormalized(math.log(math.max(frequency, MIN_FREQUENCY) / MIN_FREQUENCY) /
    math.log(MAX_FREQUENCY / MIN_FREQUENCY))
end

local function normalizeGain(decibels)
  return clampToNormalized((decibels + GAIN_RANGE_DB) / (2 * GAIN_RANGE_DB))
end

local function normalizeQ(q)
  return clampToNormalized(0.5 + math.log(q / math.sqrt(0.5)) / math.log(2) / 10)
end

local function normalizeSlope(slope)
  for index = 1, #SLOPE_BY_NORMALIZED_POSITION - 1 do
    local lowerSlope = SLOPE_BY_NORMALIZED_POSITION[index]
    local higherSlope = SLOPE_BY_NORMALIZED_POSITION[index + 1]
    if (slope <= higherSlope) then
      local fraction = math.max(0, (slope - lowerSlope) / (higherSlope - lowerSlope))
      return (index - 1 + fraction) * NORMALIZED_POSITIONS_PER_SLOPE_STEP
    end
  end
  return (#SLOPE_BY_NORMALIZED_POSITION - 1) * NORMALIZED_POSITIONS_PER_SLOPE_STEP
end

local function shelfBandwidthToSlope(bandwidth)
  return MIN_SHELF_SLOPE + clampToNormalized(bandwidth) * (MAX_SHELF_SLOPE - MIN_SHELF_SLOPE)
end

local function createAutomationEntry(slot, slotTarget)
  return '{"Index":' .. slot .. ',"Target":"' .. slotTarget .. '"}'
end

local function createAutomationsJson(bands)
  local entries = {}
  for index, slotTarget in ipairs(GENERAL_SLOTS) do
    table.insert(entries, createAutomationEntry(index - 1, slotTarget))
  end

  for band, bandSlots in ipairs(bands) do
    local fieldCount = bandSlots.qId and #FILTER_SLOT_FIELDS or SHELF_SLOT_FIELD_COUNT
    for fieldIndex = 1, fieldCount do
      table.insert(entries, createAutomationEntry(bandSlots.firstSlot + fieldIndex - 1,
        '/Filters/' .. (band - 1) .. '/' .. FILTER_SLOT_FIELDS[fieldIndex]))
    end
  end

  return table.concat(entries, ',')
end

local function createPresetFile(settingsJson)
  local content = settingsJson .. JUCE_PRIVATE_DATA
  local contentSize = string.len(content)
  local bank = 'FBCh' .. Helpers:intToBinaryBE(2, 4) .. 'CrFl' .. Helpers:intToBinaryBE(0x00010205, 4) ..
      CHUNK_BANK_PADDING .. Helpers:intToBinaryBE(contentSize, 4) .. content
  local state = 'VstW' .. Helpers:intToBinaryBE(8, 4) .. Helpers:intToBinaryBE(1, 4) .. Helpers:intToBinaryBE(0, 4) ..
      'CcnK' .. Helpers:intToBinaryBE(string.len(bank), 4) .. bank
  local stateSize = string.len(state)
  local listOffset = VST3_HEADER_SIZE + stateSize

  return table.concat({
    'VST3',
    Helpers:intToBinaryLE(1, 4),
    SHADE_CLASS_ID,
    Helpers:intToBinaryLE(listOffset, 8),
    state,
    'List',
    Helpers:intToBinaryLE(2, 4),
    'Comp', Helpers:intToBinaryLE(VST3_HEADER_SIZE, 8), Helpers:intToBinaryLE(stateSize, 8),
    'Cont', Helpers:intToBinaryLE(listOffset, 8), Helpers:intToBinaryLE(0, 8),
  })
end


class "ShadeSubstitution"

ShadeSubstitution.classId = SHADE_CLASS_ID
ShadeSubstitution.pluginName = 'Shade'

function ShadeSubstitution:__init(device, config, layout)
  self.eq = EqParameters(device, config, layout)
  self.bands = createBandSlots(layout.numBands)
end

function ShadeSubstitution:isUsable()
  return self.eq:isUsable()
end

-- The offset of the dialog also changes the steepness of the shelves
function ShadeSubstitution:getShelfSlope(bandwidth)
  return math.max(MIN_SHELF_SLOPE, math.min(self.eq:applyQFactor(shelfBandwidthToSlope(bandwidth)), MAX_SLOPE))
end

function ShadeSubstitution:getPeakQ(bandwidth)
  return math.max(MIN_Q, math.min(self.eq:applyQFactor(MeldaScales:peakBandwidthToQ(bandwidth)), MAX_Q))
end

function ShadeSubstitution:createFilterJson(band)
  local format = function(number) return MeldaPreset:formatNumber(number) end
  local bandwidth = self.eq:getValue('bandwidth', band)
  local shapeFields

  if (self.eq:isShelf(band)) then
    shapeFields = '"Slope":' .. format(self:getShelfSlope(bandwidth))
  else
    shapeFields = '"Q-Width":' .. format(self:getPeakQ(bandwidth)) .. ',"Slope":' .. format(PEAK_SLOPE)
  end

  return table.concat({
    '["', self.bands[band].filterType, '",{"C":true,"Colour Id":', band - 1, ',"Enabled":true',
    ',"Frequency":', format(self.eq:getValue('frequency', band)),
    ',"Gain":', format(self.eq:getValue('gain', band)),
    ',"L":true,"LFE":true,"Lsr":true,"Lss":true,"MidSide":false,"R":true,"Rsr":true,"Rss":true,',
    shapeFields, '}]',
  })
end

function ShadeSubstitution:createPresetData()
  local filters = {}
  for band = 1, self.eq.numBands do
    filters[band] = self:createFilterJson(band)
  end

  return createPresetFile(table.concat({
    '{"Automations":[', createAutomationsJson(self.bands), '],"Connections":[],',
    '"Editor Height":', EDITOR_HEIGHT, ',"Editor Width":', EDITOR_WIDTH, ',"Filters":[', table.concat(filters, ','),
    '],"Gain In":0.0,"Gain Out":0.0,"Limiter":{"Enabled":false,"Threshold":0.0},"Mix":1.0,"Modulators":[],',
    '"Modulators Visible":true,"Piano Keyboard Visible":true,',
    '"PitchDetector":{"Mode":0,"Sensitivity":0.300000011920929,"Source":0},"Preset Path":"",',
    '"Trigger":{"Mode":0,"Rate":2,"Sensitivity":0.5,"Source":0},"User Preset":false,"File Version":6}',
  }))
end

function ShadeSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local target = self.eq:findTarget(parameterNum)
  if (target == nil) then
    return {}
  end

  local bandSlots = self.bands[target.band]
  local value = self.eq:getAutomatedValue(parameter, target, automationValue)

  if (target.type == 'frequency') then
    return { { paramIndex = bandSlots.frequencyId, name = 'Frequency ' .. target.band, value = normalizeFrequency(value) } }
  elseif (target.type == 'gain') then
    return { { paramIndex = bandSlots.gainId, name = 'Gain ' .. target.band, value = normalizeGain(value) } }
  elseif (self.eq:isShelf(target.band)) then
    return { {
      paramIndex = bandSlots.slopeId,
      name = 'Slope ' .. target.band,
      value = normalizeSlope(self:getShelfSlope(value)),
    } }
  end
  return { {
    paramIndex = bandSlots.qId,
    name = 'Q ' .. target.band,
    value = normalizeQ(self:getPeakQ(value)),
  } }
end
