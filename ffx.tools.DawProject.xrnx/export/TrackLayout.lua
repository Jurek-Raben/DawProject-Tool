-------------------------------------------------------------------------------
-- Track Layout, knows how the Renoise tracks are distributed on the tracks and
-- lanes of the project, depending on the instruments used on a track.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "TrackLayout"

local LANE_KEY_FACTOR = 1000

function TrackLayout:__init(config, instrumentPools)
  self.config = config
  self.instrumentPools = instrumentPools
end

-- A track with multiple instruments is exported as group with one track per instrument
function TrackLayout:isTrackSplit(trackNum)
  local pool = self.instrumentPools[trackNum]
  return self.config['splitTracksByInstrument'] ~= false and pool ~= nil and #pool.instruments > 1
end

-- Lanes are stored with numeric keys, because xml2lua only repeats a tag for those
function TrackLayout:getInstrumentLaneKey(trackNum, instrumentNum)
  if (not self:isTrackSplit(trackNum)) then
    return trackNum
  end

  local pool = self.instrumentPools[trackNum]
  if (instrumentNum == nil or pool.counts[instrumentNum] == nil) then
    instrumentNum = pool.primary
  end
  return trackNum * LANE_KEY_FACTOR + instrumentNum
end

-- Renoise transposes the notes it sends to a plugin, by the global transpose of the instrument
-- and the transpose of its plugin settings. A sample instrument keeps its transpose setting in
-- the Redux preset, so its notes must not be transposed a second time.
function TrackLayout:getTransposedNoteKey(noteEvent)
  local pool = self.instrumentPools[noteEvent.trackNum]
  local instrumentNum = noteEvent.instrumentNum or (pool and pool.primary)
  if (instrumentNum == nil) then
    return noteEvent.key
  end

  local instrument = Song:instrument(instrumentNum)
  if (instrument.plugin_properties.plugin_device == nil) then
    return noteEvent.key
  end
  local transpose = instrument.transpose + instrument.plugin_properties.transpose
  return math.max(0, math.min(noteEvent.key + transpose, 127))
end

function TrackLayout:getLaneTrackId(laneKey)
  if (laneKey < LANE_KEY_FACTOR) then
    return 'track' .. laneKey
  end
  return 'track' .. math.floor(laneKey / LANE_KEY_FACTOR) .. '-i' .. (laneKey % LANE_KEY_FACTOR)
end
