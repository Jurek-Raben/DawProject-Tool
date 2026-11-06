-------------------------------------------------------------------------------
-- Arrangement Exporter, generates the markers, clips and notes of the project.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "ArrangementExporter"

function ArrangementExporter:__init(config, progress, layout)
  self.config = config
  self.progress = progress
  self.layout = layout
end

function ArrangementExporter:generateMarkersDataForXML()
  local markers = {}
  local lineOffset = 0
  local scaleFactor = SongHelpers:getBeatsPerTick()

  for seqIndex = 1, #Song.sequencer.pattern_sequence do
    local sectionName = Song.sequencer:sequence_section_name(seqIndex)
    local patternIndex = Song.sequencer:pattern(seqIndex)
    local patternLines = Song:pattern(patternIndex).number_of_lines

    if (Song.sequencer:sequence_is_start_of_section(seqIndex)) then
      table.insert(markers,
        {
          _attr = {
            time = Helpers:round(lineOffset * 256 * scaleFactor, 6),
            name = Helpers:prepareNameForXML(sectionName)
          },
        })
    end

    lineOffset = lineOffset + patternLines
  end

  if (markers ~= nil) then
    return {
      _attr = {
        timeUnit = "beats"
      },
      Marker = markers
    }
  end
  return nil
end

function ArrangementExporter:generateNotePressureEventsDataForXML(pressureTimeline)
  local scaleFactor = SongHelpers:getBeatsPerTick()
  local points = {}
  for _, pressureEntry in ipairs(pressureTimeline) do
    table.insert(points, {
      _attr = {
        value = Helpers:round(pressureEntry.value, 6),
        interpolation = 'linear',
        time = Helpers:round(pressureEntry.timestamp * scaleFactor, 6)
      }
    })
  end
  return points
end

function ArrangementExporter:generateNoteEventsDataForXML(songEvents, automationPoints)
  local noteEvents = songEvents.noteEvents

  local lanesObj = {}
  local scaleFactor = SongHelpers:getBeatsPerTick()

  self.progress:setPhase('Exporting notes', 0.85, 0.93)

  for noteIndex, noteEvent in ipairs(noteEvents) do
    local laneKey = self.layout:getInstrumentLaneKey(noteEvent.trackNum, noteEvent.instrumentNum)

    if (lanesObj[laneKey] == nil) then
      lanesObj[laneKey] = {
        Clips = {
          _attr = {
            id = 'clips' .. laneKey .. '-' .. noteEvent.seqNum,
          },
          Clip = {},
        },
        _attr = {
          id = 'lanes' .. laneKey .. '-' .. noteEvent.seqNum,
          track = self.layout:getLaneTrackId(laneKey)
        },
        Points = automationPoints[laneKey],
      }
      self.progress:setPhaseProgress(noteIndex / #noteEvents)
      coroutine.yield()
    end

    local clips = lanesObj[laneKey].Clips.Clip
    if (clips[noteEvent.seqNum] == nil) then
      local trackDelay = 0
      if (self.config['addTrackDelayToClips']) then
        trackDelay = Song:track(noteEvent.trackNum).output_delay / (60000 / (Song.transport.bpm))
      end
      local clipTimestamp = noteEvent.patternTimestamp * scaleFactor + trackDelay
      if (clipTimestamp < 0) then
        clipTimestamp = 0
      end
      clips[noteEvent.seqNum] = {
        _attr = {
          time = clipTimestamp,
          duration = noteEvent.patternDuration * scaleFactor,
          playStart = "0", -- -trackDelay,
          -- loopStart = "0.0",
          -- loopEnd = "8.0",
          enable = noteEvent.enabled and "true" or "false",
          name = 'track' .. noteEvent.trackNum .. ' pattern' .. noteEvent.patternNum
        },
        Lanes = {
          Notes = {
            Note = {},
            _attr = {
              id = 'notes' .. laneKey .. '-' .. noteEvent.seqNum
            }
          },
          _attr = {
            id = 'sublanes' .. laneKey .. '-' .. noteEvent.seqNum
          }
        },
      }
    end

    local notes = lanesObj[laneKey].Clips.Clip[noteEvent.seqNum].Lanes.Notes.Note
    notes[#notes + 1] = {
      _attr = {
        time = Helpers:round(noteEvent.patternRelTimestamp * scaleFactor, 6),
        duration = Helpers:round(noteEvent.duration * scaleFactor, 6),
        channel = 0,
        key = self.layout:getTransposedNoteKey(noteEvent),
        vel = noteEvent.velocity,
        rel = noteEvent.releaseVelocity,
      },
      Points = #noteEvent.pressureTimeline > 0 and {
        Target = {
          _attr = {
            expression = "pressure"
          }
        },
        RealPoint = self:generateNotePressureEventsDataForXML(noteEvent.pressureTimeline),
        _attr = {
          id = 'polypressure' .. laneKey .. '-' .. noteEvent.seqNum .. '-' .. #notes,
          unit = 'linear',
        }
      } or nil

    }
  end

  -- automation without notes, e.g. of the effects on the group of a split track
  for laneKey, points in pairs(automationPoints) do
    if (lanesObj[laneKey] == nil) then
      lanesObj[laneKey] = {
        _attr = {
          id = 'lanes' .. laneKey,
          track = self.layout:getLaneTrackId(laneKey)
        },
        Points = points,
      }
    end
  end

  return lanesObj
end
