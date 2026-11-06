-------------------------------------------------------------------------------
-- Melda Scales, converts values into the normalized parameter values of
-- MeldaProduction plugins. The scales were read from the values these plugins
-- display, with the parameter values switch of the VST3 info tool.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local GAIN_RANGE_DB = 24
local PANORAMA_LAW_RANGE_DB = 12
local MIN_FREQUENCY = 20
local MAX_FREQUENCY = 20000

local MIN_PEAK_Q = 0.30
local MAX_PEAK_Q = 20
local PEAK_Q_CALIBRATION = MIN_PEAK_Q / (math.sqrt(2 ^ 4) / (2 ^ 4 - 1))
local MIN_SHELF_Q = 0.135
local MAX_SHELF_Q = 0.83

-- The Q of MEqualizer has no simple formula, so its displayed values are interpolated.
-- These are the values at the normalized positions 0, 0.025, 0.05 ... 1.
local Q_BY_NORMALIZED_POSITION = {
  20, 12.07, 10.57, 9.56, 8.78, 8.14, 7.58, 7.1, 6.66, 6.26, 5.89, 5.55, 5.24, 4.94,
  4.66, 4.39, 4.13, 3.89, 3.66, 3.44, 3.22, 3.02, 2.82, 2.63, 2.44, 2.26, 2.09, 1.92,
  1.75, 1.59, 1.43, 1.28, 1.13, 0.99, 0.84, 0.7, 0.57, 0.44, 0.3, 0.18, 0.05,
}

-- The threshold of MCompressor in dB at the normalized positions 0, 0.025, 0.05 ... 1.
local COMPRESSOR_THRESHOLD_BY_NORMALIZED_POSITION = {
  -80, -58.4, -49, -43, -38.5, -34.9, -32, -29.5, -27.3, -25.3, -23.6, -22, -20.5, -19.2,
  -17.9, -16.8, -15.7, -14.6, -13.7, -12.7, -11.9, -11, -10.2, -9.49, -8.76, -8.06, -7.39,
  -6.74, -6.12, -5.52, -4.94, -4.38, -3.83, -3.31, -2.79, -2.29, -1.81, -1.34, -0.88, -0.44, 0,
}

local MAX_COMPRESSOR_TIME_MS = 1000
local MAX_COMPRESSOR_RATIO = 20

local function clampToNormalized(value)
  return math.max(0, math.min(value, 1))
end

MeldaScales = {}

function MeldaScales:amplitudeToDecibels(amplitude)
  if (amplitude <= 0) then
    return -math.huge
  end
  return 20 * math.log10(amplitude)
end

-- The MUtility volume knob only attenuates, and its amplitude is the square of the knob
function MeldaScales:getVolumeKnob(amplitude)
  return math.sqrt(clampToNormalized(amplitude))
end

-- Everything above the range of the volume knob is done with the gain
function MeldaScales:getBoostDecibels(amplitude)
  return math.max(0, self:amplitudeToDecibels(amplitude))
end

function MeldaScales:normalizeGain(decibels)
  return clampToNormalized((decibels + GAIN_RANGE_DB) / (2 * GAIN_RANGE_DB))
end

function MeldaScales:normalizePanoramaLaw(decibels)
  return clampToNormalized((decibels + PANORAMA_LAW_RANGE_DB) / (2 * PANORAMA_LAW_RANGE_DB))
end

function MeldaScales:normalizeFrequency(frequency)
  local position = math.log(math.max(frequency, MIN_FREQUENCY) / MIN_FREQUENCY) /
      math.log(MAX_FREQUENCY / MIN_FREQUENCY)
  return clampToNormalized(position)
end

function MeldaScales:frequencyToLogarithm(frequency)
  return math.log10(math.max(MIN_FREQUENCY, math.min(frequency, MAX_FREQUENCY)))
end

function MeldaScales:normalizeQ(q)
  local numPositions = #Q_BY_NORMALIZED_POSITION

  for index = 1, numPositions - 1 do
    local higherQ = Q_BY_NORMALIZED_POSITION[index]
    local lowerQ = Q_BY_NORMALIZED_POSITION[index + 1]
    if (q >= lowerQ) then
      local fraction = math.max(0, (higherQ - q) / (higherQ - lowerQ))
      return (index - 1 + fraction) / (numPositions - 1)
    end
  end
  return 1
end

function MeldaScales:normalizeCompressorTime(milliseconds)
  return clampToNormalized(milliseconds / MAX_COMPRESSOR_TIME_MS) ^ 0.25
end

function MeldaScales:normalizeCompressorRatio(ratio)
  return math.sqrt(clampToNormalized((ratio - 1) / (MAX_COMPRESSOR_RATIO - 1)))
end

function MeldaScales:normalizeCompressorThreshold(decibels)
  local numPositions = #COMPRESSOR_THRESHOLD_BY_NORMALIZED_POSITION

  for index = 1, numPositions - 1 do
    local lowerDecibels = COMPRESSOR_THRESHOLD_BY_NORMALIZED_POSITION[index]
    local higherDecibels = COMPRESSOR_THRESHOLD_BY_NORMALIZED_POSITION[index + 1]
    if (decibels <= higherDecibels) then
      local fraction = math.max(0, (decibels - lowerDecibels) / (higherDecibels - lowerDecibels))
      return (index - 1 + fraction) / (numPositions - 1)
    end
  end
  return 1
end

-- MCompressor saves its threshold as the square root of the amplitude
function MeldaScales:compressorThresholdToStoredValue(decibels)
  return 10 ^ (math.min(decibels, 0) / 40)
end

-- The bandwidth of a peak band behaves like octaves. It is calibrated with the measured ends:
-- a bandwidth of 4 sounds like Q 0.30 in MEqualizer, a bandwidth near 0 like Q 20.
function MeldaScales:peakBandwidthToQ(octaves)
  local widthFactor = 2 ^ math.max(octaves, 0.0001)
  local q = PEAK_Q_CALIBRATION * math.sqrt(widthFactor) / (widthFactor - 1)
  return math.max(MIN_PEAK_Q, math.min(q, MAX_PEAK_Q))
end

-- The shelves of the Renoise EQ have the opposite direction of the peaks and only use the range
-- from 0 to 1. Visually matched in MEqualizer: 0 is about Q 0.15, 0.367 is Q 0.39 and 1 is Q 0.83.
-- These lie close to a straight line, the ends here are the line through the last two.
function MeldaScales:shelfBandwidthToQ(bandwidth)
  return MIN_SHELF_Q + clampToNormalized(bandwidth) * (MAX_SHELF_Q - MIN_SHELF_Q)
end
