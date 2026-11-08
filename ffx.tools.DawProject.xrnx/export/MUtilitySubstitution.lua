-------------------------------------------------------------------------------
-- MUtility Substitution, replaces gain and panning that Renoise has built in
-- with the MeldaProduction MUtility VST3 plugin.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

MUTILITY_CLASS_ID = '4D656C646170726F4D7574694D757469'

-- Where the delay of a track is exported to, if its pre mixer is substituted
TRACK_DELAY_TARGET_CONFIG_KEY = 'trackDelayTarget'
TRACK_DELAY_IN_PLUGIN = 'plugin'
TRACK_DELAY_IN_CLIPS = 'clips'

-- Renoise uses a +3 dB pan law, the default of MUtility is +6 dB
local RENOISE_PANNING_LAW_DB = 3

local PARAMETER_VOLUME = 0
local PARAMETER_GAIN = 1
local PARAMETER_PANORAMA = 2

local VALUE_TOLERANCE = 0.0001

local function isDifferent(value, defaultValue)
  return math.abs(value - defaultValue) > VALUE_TOLERANCE
end

-- The track headroom of the song lowers the input of each sequencer track, before its pre mixer.
-- Group tracks only sum their tracks, which are lowered already. Used without the substitution, too.
function getTrackHeadroom(track)
  if (track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER) then
    return 1
  end
  return Song.transport.track_headroom
end

-- A positive delay of Renoise is a plain delay. A negative one is reported as latency to the DAW.
local function createDelayAttributes(delayMilliseconds)
  if (delayMilliseconds == 0) then
    return ' #DelayEnabledCollapsed="1"'
  end

  return ' #DelayEnabled="1" #DelayEnabledCollapsed="0" #DelayMilliseconds="' ..
      MeldaPreset:formatNumber(math.abs(delayMilliseconds) / 1000) .. '"' ..
      (delayMilliseconds < 0 and ' #DelayReportLatency="1"' or '')
end

local function createSettingsXml(amplitude, panning, isLeftInverted, isRightInverted, delayMilliseconds)
  local format = function(number) return MeldaPreset:formatNumber(number) end
  local editorSize = delayMilliseconds == 0 and '812,463' or '910,533'

  return table.concat({
    '<?xml version="1.0" encoding="utf-8"?>\n<MUtilitysettings #="1"',
    ' #Volume="', format(MeldaScales:getVolumeKnob(amplitude)), '"',
    ' #Gain="', format(MeldaScales:getBoostDecibels(amplitude)), '"',
    ' #panorama="', format((panning - 0.5) * 2), '"',
    ' #panlaw2="', format(RENOISE_PANNING_LAW_DB), '"',
    isLeftInverted and ' #InvertLeft="1"' or '',
    isRightInverted and ' #InvertRight="1"' or '',
    ' #DCBlockerCollapsed="1"', createDelayAttributes(delayMilliseconds), ' #RMSEnabledCollapsed="1"',
    ' #EnvelopeEnabledCollapsed="1" #MathEnabledCollapsed="1" #ExpressionEnabledCollapsed="1"',
    ' #Expression="x" #CoderCollapsed="1" Version="1114112" MIDIProgramChangeEnable="0"',
    ' ProgramChangeCategorizer="0" EditorSize="', editorSize, '" ControllersEnabled="0" MetersCollapsedStereo="1"',
    ' MaxLFOBlockSize="32"><Meters2><WidthM><Source Prefiltering="0"/></WidthM></Meters2>\n',
    '</MUtilitysettings>\n',
  })
end

-- Automation values are normalized. They are treated as linear in the range of the parameter.
local function getPlainValue(parameter, automationValue)
  return parameter.value_min + automationValue * (parameter.value_max - parameter.value_min)
end

-- A value is split into attenuation and boost, so both lanes together result in the exact gain.
-- The amplitude is multiplied by the factor, e.g. the track headroom of the song.
local function mapGainAutomation(parameter, automationValue, factor)
  local amplitude = getPlainValue(parameter, automationValue) * (factor or 1)
  return {
    { paramIndex = PARAMETER_VOLUME, name = 'Volume', value = MeldaScales:getVolumeKnob(amplitude) },
    {
      paramIndex = PARAMETER_GAIN,
      name = 'Gain',
      value = MeldaScales:normalizeGain(MeldaScales:getBoostDecibels(amplitude))
    },
  }
end

local function mapPanningAutomation(parameter, automationValue)
  return { { paramIndex = PARAMETER_PANORAMA, name = 'Panorama', value = getPlainValue(parameter, automationValue) } }
end


class "MUtilityGainerSubstitution"

MUtilityGainerSubstitution.classId = MUTILITY_CLASS_ID
MUtilityGainerSubstitution.pluginName = 'MUtility'

function MUtilityGainerSubstitution:__init(device)
  self.device = device
  self.gainParameterNum = nil
  self.panningParameterNum = nil

  for parameterNum = 1, #device.parameters do
    local parameterName = device:parameter(parameterNum).name:lower()
    if (string.find(parameterName, 'pan', 1, true)) then
      self.panningParameterNum = self.panningParameterNum or parameterNum
    elseif (string.find(parameterName, 'gain', 1, true) or string.find(parameterName, 'vol', 1, true)) then
      self.gainParameterNum = self.gainParameterNum or parameterNum
    end
  end
end

function MUtilityGainerSubstitution:isUsable()
  return self.gainParameterNum ~= nil and self.panningParameterNum ~= nil
end

function MUtilityGainerSubstitution:createPresetData()
  local isInverted = function(nodeName)
    return DeviceHelpers:getActivePresetDataContent(self.device, nodeName) == 'true'
  end

  return MeldaPreset:create(MUTILITY_CLASS_ID, createSettingsXml(
    self.device:parameter(self.gainParameterNum).value,
    self.device:parameter(self.panningParameterNum).value,
    isInverted('LPhaseInvert'),
    isInverted('RPhaseInvert'),
    0
  ))
end

function MUtilityGainerSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  if (parameterNum == self.gainParameterNum) then
    return mapGainAutomation(parameter, automationValue)
  elseif (parameterNum == self.panningParameterNum) then
    return mapPanningAutomation(parameter, automationValue)
  end
  return {}
end


class "MUtilityPreMixerSubstitution"

MUtilityPreMixerSubstitution.classId = MUTILITY_CLASS_ID
MUtilityPreMixerSubstitution.pluginName = 'MUtility'

function MUtilityPreMixerSubstitution:__init(track, config)
  self.track = track
  self.headroom = getTrackHeadroom(track)
  self.containsDelay = config[TRACK_DELAY_TARGET_CONFIG_KEY] == TRACK_DELAY_IN_PLUGIN
  self.volumeParameterNum = nil
  self.panningParameterNum = nil

  -- The post mixer parameters are on the same device, so only the first matches are the pre mixer
  local mixerDevice = track:device(1)
  for parameterNum = 1, #mixerDevice.parameters do
    local parameterName = mixerDevice:parameter(parameterNum).name
    if (parameterName == track.prefx_volume.name) then
      self.volumeParameterNum = self.volumeParameterNum or parameterNum
    elseif (parameterName == track.prefx_panning.name) then
      self.panningParameterNum = self.panningParameterNum or parameterNum
    end
  end
end

-- A track without any pre mixer settings and without headroom doesn't need a plugin
function MUtilityPreMixerSubstitution:isUsed()
  local volume = self.track.prefx_volume
  local panning = self.track.prefx_panning
  return isDifferent(volume.value, 1) or isDifferent(panning.value, 0.5) or isDifferent(self.headroom, 1) or
      volume.is_automated or panning.is_automated or (self.containsDelay and self.track.output_delay ~= 0)
end

function MUtilityPreMixerSubstitution:createPresetData()
  return MeldaPreset:create(MUTILITY_CLASS_ID,
    createSettingsXml(self.track.prefx_volume.value * self.headroom, self.track.prefx_panning.value, false, false,
      self.containsDelay and self.track.output_delay or 0))
end

function MUtilityPreMixerSubstitution:mapAutomationValue(parameter, parameterNum, automationValue)
  if (parameterNum == self.volumeParameterNum) then
    return mapGainAutomation(parameter, automationValue, self.headroom)
  elseif (parameterNum == self.panningParameterNum) then
    return mapPanningAutomation(parameter, automationValue)
  end
  return {}
end
