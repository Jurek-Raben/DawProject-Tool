-------------------------------------------------------------------------------
-- Compressor Parameters, reads the Compressor and the Bus Compressor of Renoise
-- for their substitutions. Both devices have their own scales, which were
-- compared with the values Renoise displays.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

-- The threshold of the Compressor is saved in a logarithmic unit. Only one point could be compared
-- so far, so its displayed value is preferred if possible.
local LOG_THRESHOLD_DB_PER_UNIT = 12.09

local function getLogThresholdDecibels(parameter, plainValue)
  if (parameter.value_max <= 0) then
    return plainValue
  end
  return (plainValue - parameter.value_max) * LOG_THRESHOLD_DB_PER_UNIT
end

local function identity(_, plainValue)
  return plainValue
end

-- Convert the values of a Renoise device into dB, ratio and milliseconds
COMPRESSOR_SCALES = {
  threshold = getLogThresholdDecibels,
  ratio = identity,
  attack = identity,
  release = identity,
  makeup = function(_, amplitude) return MeldaScales:amplitudeToDecibels(amplitude) end,
}

BUS_COMPRESSOR_SCALES = {
  threshold = identity,
  ratio = function(_, position) return 1 / (1 - 0.95 * position) end,
  attack = function(_, position) return 0.1 + 999.9 * position ^ 2 end,
  release = function(_, position) return 1 + 1999 * position ^ 2 end,
  makeup = function(_, position) return position * 5 / 3 end,
  knee = identity,
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


class "CompressorParameters"

function CompressorParameters:__init(device, scales)
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

function CompressorParameters:isUsable()
  for parameterType in pairs(self.scales) do
    if (self.parameterNums[parameterType] == nil) then
      return false
    end
  end
  return true
end

function CompressorParameters:hasKnee()
  return self.scales.knee ~= nil
end

function CompressorParameters:getCurrentValue(parameterType)
  local parameter = self.device:parameter(self.parameterNums[parameterType])
  return self.scales[parameterType](parameter, parameter.value)
end

-- Renoise displays the threshold in dB, independent of how the device saves it
function CompressorParameters:getCurrentThreshold()
  local parameter = self.device:parameter(self.parameterNums.threshold)
  local displayedDecibels = tonumber(parameter.value_string:match('^%s*(-?[%d.]+)'))
  return displayedDecibels or self:getCurrentValue('threshold')
end

-- Returns the type of an automated parameter and its value, or nil for other parameters.
-- Automation values are normalized. They are treated as linear in the range of the parameter.
function CompressorParameters:readAutomationValue(parameter, parameterNum, automationValue)
  local parameterType = self.parameterTypes[parameterNum]
  local scale = self.scales[parameterType]
  if (scale == nil) then
    return nil
  end

  local plainValue = parameter.value_min + automationValue * (parameter.value_max - parameter.value_min)
  return parameterType, scale(parameter, plainValue)
end
