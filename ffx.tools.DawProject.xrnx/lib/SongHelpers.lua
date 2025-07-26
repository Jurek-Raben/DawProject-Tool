-------------------------------------------------------------------------------
-- General Helpers, collection of useful additional
-- renoise.song object functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------


SongHelpers = {}

function SongHelpers:getTrackIndex(track)
  local numTracks = #Song.tracks
  for index = 1, numTracks do
    local _track = Song:track(index)
    if (rawequal(_track, track)) then
      return index
    end
  end

  return nil
end

function SongHelpers:getChainIndex(chain, instrument)
  local numChains = #instrument.sample_device_chains
  for index = 1, numChains do
    local _chain = instrument:sample_device_chain(index)
    if (rawequal(_chain, chain)) then
      return index
    end
  end

  return nil
end

function SongHelpers:getTrackOfDevice(device)
  local numTracks = #Song.tracks
  for trackIndex = 1, numTracks do
    local track = Song:track(trackIndex)
    for _, trackDevice in pairs(track.devices) do
      if (rawequal(device, trackDevice)) then
        return track
      end
    end
  end

  return nil
end

function SongHelpers:getHighestPatternIndex()
  local maxIndex = 0;
  for pos = 1, #Song.sequencer.pattern_sequence do
    maxIndex = math.max(maxIndex, Song.sequencer:pattern(pos))
  end
  return maxIndex
end

function SongHelpers:getInstrumentOfTrack(track)
  local index = SongHelpers:getInstrumentIndexOfTrack(track)
  if (index ~= nil) then
    return Song:instrument(index)
  end
  return nil
end

function SongHelpers:getInstrumentIndexOfTrack(track)
  local trackIndex = self:getTrackIndex(track)
  local pattern, _track, patternLine, noteColumn
  for patternIndex = 1, self:getHighestPatternIndex() do
    pattern = Song:pattern(patternIndex)
    if (not pattern.is_empty) then
      _track = pattern:track(trackIndex)
      if (not _track.is_empty) then
        for lineIndex = 1, pattern.number_of_lines do
          patternLine = _track:line(lineIndex)
          if (not patternLine.is_empty) then
            for colIndex = 1, track.visible_note_columns do
              noteColumn = patternLine:note_column(colIndex)
              if (noteColumn.instrument_value ~= 255) then
                return noteColumn.instrument_value + 1
              end
            end
          end
        end
      end
    end
  end

  return nil
end

function SongHelpers:getInstrumentIndex(instrument)
  local numInstrs = #Song.instruments
  for instrIndex = 1, numInstrs do
    local _instrument = Song:instrument(instrIndex)
    if (rawequal(instrument, _instrument)) then
      return instrIndex
    end
  end

  return nil
end
