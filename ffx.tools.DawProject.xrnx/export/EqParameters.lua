-------------------------------------------------------------------------------
-- EQ Parameters, reads the bands of the Renoise EQ 5 and EQ 10 for their
-- substitutions. The first and the last band are shelves, the others are peak
-- filters.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

EQ5_LAYOUT = { numBands = 5, qFactorConfigKey = 'substituteEq5QFactor' }
EQ10_LAYOUT = { numBands = 10, qFactorConfigKey = 'substituteEq10QFactor' }

local function getParameterType(parameterName)
  local lowercaseName = parameterName:lower()
  if (string.find(lowercaseName, 'gain', 1, true)) then
    return 'gain'
  elseif (string.find(lowercaseName, 'freq', 1, true)) then
    return 'frequency'
  elseif (string.find(lowercaseName, 'band', 1, true) or string.find(lowercaseName, 'width', 1, true)
        or string.find(lowercaseName, 'bw', 1, true) or lowercaseName:match('^q')) then
    return 'bandwidth'
  end
  return nil
end


class "EqParameters"

function EqParameters:__init(device, config, layout)
  self.device = device
  self.numBands = layout.numBands
  self.qFactor = 2 ^ (config[layout.qFactorConfigKey] or 0)
  self.parameterNums = { gain = {}, frequency = {}, bandwidth = {} }
  self.bandTargetByParameterNum = {}

  -- The bands of a parameter type are in the order of their appearance
  for parameterNum = 1, #device.parameters do
    local parameterType = getParameterType(device:parameter(parameterNum).name)
    if (parameterType ~= nil) then
      local parameterNumsOfType = self.parameterNums[parameterType]
      table.insert(parameterNumsOfType, parameterNum)
      self.bandTargetByParameterNum[parameterNum] = { type = parameterType, band = #parameterNumsOfType }
    end
  end
end

function EqParameters:isUsable()
  return #self.parameterNums.gain == self.numBands and #self.parameterNums.frequency == self.numBands and
      #self.parameterNums.bandwidth == self.numBands
end

function EqParameters:isShelf(band)
  return band == 1 or band == self.numBands
end

function EqParameters:getValue(parameterType, band)
  return self.device:parameter(self.parameterNums[parameterType][band]).value
end

-- The factor of the dialog is multiplied, since the same difference would be huge for a low Q
function EqParameters:applyQFactor(value)
  return value * self.qFactor
end

-- Returns the band and the type of a parameter, or nil
function EqParameters:findTarget(parameterNum)
  return self.bandTargetByParameterNum[parameterNum]
end

-- Automation values are normalized. The range of a frequency is treated as logarithmic, like the
-- slider of the device, and the other ones as linear.
function EqParameters:getAutomatedValue(parameter, target, automationValue)
  local minValue, maxValue = parameter.value_min, parameter.value_max
  if (target.type == 'frequency') then
    return math.max(minValue, 1) * (maxValue / math.max(minValue, 1)) ^ automationValue
  end
  return minValue + automationValue * (maxValue - minValue)
end
