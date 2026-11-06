-------------------------------------------------------------------------------
-- MEqualizer Substitution, replaces the Renoise EQ 5 with the MeldaProduction
-- MEqualizer VST3 plugin.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

MEQUALIZER_CLASS_ID = '4D656C646170726F4D4165334D416533'

-- Each band of MEqualizer has 7 parameters, starting with the id 3: enable, frequency, gain, q ...
local FIRST_BAND_PARAMETER = 3
local PARAMETERS_PER_BAND = 7
local FREQUENCY_OFFSET = 1
local GAIN_OFFSET = 2
local Q_OFFSET = 3

local BAND_TYPE_ATTRIBUTES = {
  [1] = ' type="LowShelf"',
  [EQ5_NUM_BANDS] = ' type="HighShelf"',
}

-- MEqualizer always has 6 bands, the last one is not used
local UNUSED_BAND_XML = '<point X="3.87245856709" Enabled="0" type="HighShelf"/>'

local SETTINGS_XML_START = '<?xml version="1.0" encoding="utf-8"?>\n' ..
    '<MEqualizersettings #="1" Version="1114112" HQUpsampling="0" EditorSize="1518,598" ControllersEnabled="0" ' ..
    'MaxLFOBlockSize="32" LRSplitterSize1="2230.09232807" LRSplitterSize2="588.907671931" CollapsedBandsPanel="0"><Meters2><WidthM><Source Prefiltering="0"/></WidthM></Meters2>\n<Graph>'
local SETTINGS_XML_END = '</Graph>\n<Areas MaximizeRows="1"/>\n</MEqualizersettings>\n'


class "MEqualizerSubstitution"

MEqualizerSubstitution.classId = MEQUALIZER_CLASS_ID
MEqualizerSubstitution.pluginName = 'MEqualizer'

function MEqualizerSubstitution:__init(device)
  self.eq5 = Eq5Parameters(device)
end

function MEqualizerSubstitution:isUsable()
  return self.eq5:isUsable()
end

function MEqualizerSubstitution:getBandQ(band, bandwidth)
  if (self.eq5:isShelf(band)) then
    return MeldaScales:shelfBandwidthToQ(bandwidth)
  end
  return MeldaScales:peakBandwidthToQ(bandwidth)
end

function MEqualizerSubstitution:createBandXml(band)
  local format = function(number) return MeldaPreset:formatNumber(number) end

  return table.concat({
    '<point X="', format(MeldaScales:frequencyToLogarithm(self.eq5:getValue('frequency', band))), '"',
    ' Y="', format(self.eq5:getValue('gain', band)), '"',
    ' q="', format(self:getBandQ(band, self.eq5:getValue('bandwidth', band))), '"',
    BAND_TYPE_ATTRIBUTES[band] or '',
    ' Harmonics.Semitones="12.0000000894"/>',
  })
end

function MEqualizerSubstitution:createPresetData()
  local bands = {}
  for band = 1, EQ5_NUM_BANDS do
    bands[band] = self:createBandXml(band)
  end
  return MeldaPreset:create(MEQUALIZER_CLASS_ID,
    SETTINGS_XML_START .. table.concat(bands) .. UNUSED_BAND_XML .. SETTINGS_XML_END)
end

function MEqualizerSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  local target = self.eq5:findTarget(parameterNum)
  if (target == nil) then
    return {}
  end

  local firstParameter = FIRST_BAND_PARAMETER + (target.band - 1) * PARAMETERS_PER_BAND
  local value = self.eq5:getAutomatedValue(parameter, target, automationValue)

  if (target.type == 'frequency') then
    return { {
      paramIndex = firstParameter + FREQUENCY_OFFSET,
      name = 'Frequency ' .. target.band,
      value = MeldaScales:normalizeFrequency(value),
    } }
  elseif (target.type == 'gain') then
    return { {
      paramIndex = firstParameter + GAIN_OFFSET,
      name = 'Gain ' .. target.band,
      value = MeldaScales:normalizeGain(value),
    } }
  end

  return { {
    paramIndex = firstParameter + Q_OFFSET,
    name = 'Q ' .. target.band,
    value = MeldaScales:normalizeQ(self:getBandQ(target.band, value)),
  } }
end
