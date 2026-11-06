-------------------------------------------------------------------------------
-- EQ 5 Parameters, reads the bands of the Renoise EQ 5 for its substitutions.
-- The first and the last band are shelves, the others are peak filters.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

EQ5_NUM_BANDS = 5

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


class "Eq5Parameters"

function Eq5Parameters:__init(device)
  self.device = device
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

function Eq5Parameters:isUsable()
  return #self.parameterNums.gain == EQ5_NUM_BANDS and #self.parameterNums.frequency == EQ5_NUM_BANDS and
      #self.parameterNums.bandwidth == EQ5_NUM_BANDS
end

function Eq5Parameters:isShelf(band)
  return band == 1 or band == EQ5_NUM_BANDS
end

function Eq5Parameters:getValue(parameterType, band)
  return self.device:parameter(self.parameterNums[parameterType][band]).value
end

-- Returns the band and the type of a parameter, or nil
function Eq5Parameters:findTarget(parameterNum)
  return self.bandTargetByParameterNum[parameterNum]
end

-- Automation values are normalized. The range of a frequency is treated as logarithmic, like the
-- slider of the device, and the other ones as linear.
function Eq5Parameters:getAutomatedValue(parameter, target, automationValue)
  local minValue, maxValue = parameter.value_min, parameter.value_max
  if (target.type == 'frequency') then
    return math.max(minValue, 1) * (maxValue / math.max(minValue, 1)) ^ automationValue
  end
  return minValue + automationValue * (maxValue - minValue)
end
