--[[

    Note Abstraction Layer
    for linear DAW export

    Generates an event table of the whole linear song,
    sorted by track number and absolute line number.
    Such a note event also contains merged data as:

    - duration, exact timestamp. Takes care of missing note-offs, disabled sequence slots etc.
    - normalized per-note-data like “velocity”, "pan", etc.
    - Elimates pattern abstraction, linear output

    Also generates related automation events in a multi dimensional array

    by Jurek Raben

--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--]]


class "NoteAbstraction"

function NoteAbstraction:__init()
end

function NoteAbstraction:generateSongEvents(yieldCallback)
  local noteEvents = {}
  local automationEvents = {}

  local activeNotes = {}
  local lastVelocities = {}
  local noteKey = nil
  local patternIndex = nil
  local patternLines = nil
  local pattern = nil
  local seqIsMuted = {}
  local lineOffset = 0

  for seqIndex = 1, #Song.sequencer.pattern_sequence do
    patternIndex = Song.sequencer:pattern(seqIndex)
    pattern = Song:pattern(patternIndex)
    patternLines = pattern.number_of_lines

    for position, noteColumn in Song.pattern_iterator:note_columns_in_pattern(patternIndex) do
      noteKey = position.column .. "_" .. position.track

      local checkForNoteEvent = function(_noteKey)
        -- Note-Off / Cut
        local noteOn = activeNotes[_noteKey]
        if noteOn then
          noteOn.lineDuration = (lineOffset + position.line - 1) - noteOn.absLineNum
          noteOn.duration = ((lineOffset + position.line - 1) * 256 + noteColumn.delay_value) -
              noteOn.timestamp
          noteOn.releaseVelocity = noteColumn.volume_value < 128 and (noteColumn.volume_value / 127) or nil
          table.insert(noteEvents, noteOn)
          -- remove note-on
          activeNotes[_noteKey] = nil
        end
      end

      if (position.line == 1 and position.column == 1) then
        local _seqIsMuted = Song.sequencer:track_sequence_slot_is_muted(position.track, seqIndex)
        if (seqIsMuted[position.track] ~= _seqIsMuted) then
          seqIsMuted[position.track] = _seqIsMuted
          checkForNoteEvent(noteKey)
        end

        NoteAbstraction:addTrackAutomation(automationEvents, position.track,
          pattern:track(position.track), lineOffset)
        if (yieldCallback ~= nil and seqIndex % 4 == 0) then yieldCallback() end
      end

      if noteColumn.is_empty then
        goto continue
      end

      if noteColumn.note_value >= 0 and noteColumn.note_value < renoise.PatternLine.NOTE_OFF then
        checkForNoteEvent(noteKey)

        -- add note-on
        activeNotes[noteKey] = {
          key = noteColumn.note_value,
          noteString = noteColumn.note_string,
          velocity = noteColumn.volume_value < 128 and (noteColumn.volume_value / 127) or
              lastVelocities[noteKey] or
              1,
          pan = noteColumn.panning_value < 128 and (noteColumn.panning_value / 127) or nil,
          delay = noteColumn.delay_value,
          seqNum = seqIndex,
          patternNum = position.pattern,
          patternDuration = patternLines * 256,
          columnNum = position.column,
          trackNum = position.track,
          lineNum = position.line - 1,
          absLineNum = lineOffset + position.line - 1,
          timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
          patternRelTimestamp = (position.line - 1) * 256 + noteColumn.delay_value,
          patternTimestamp = lineOffset * 256,
          enabled = not seqIsMuted[position.track],
        }
        if (noteColumn.volume_value < 128) then
          lastVelocities[noteKey] = noteColumn.volume_value
        end
      elseif noteColumn.note_value == renoise.PatternLine.NOTE_OFF then
        checkForNoteEvent(noteKey)
      end

      ::continue::
    end

    lineOffset = lineOffset + patternLines
  end

  -- end playing notes
  for _, noteOn in pairs(activeNotes) do
    if noteOn then
      noteOn.lineDuration = lineOffset - noteOn.absLineNum
      noteOn.duration = (lineOffset * 256) - noteOn.timestamp
      table.insert(noteEvents, noteOn)
    end
  end

  table.sort(noteEvents, function(a, b)
    if (a.trackNum == b.trackNum) then
      return a.timestamp < b.timestamp
    end
    return a.trackNum < b.trackNum
  end)


  for i, trackAutomationEvents in ipairs(automationEvents) do
    for _, parameterAutomationEvents in ipairs(trackAutomationEvents) do
      table.sort(parameterAutomationEvents, function(a, b)
        if (a.index == b.index) then
          return a.timestamp < b.timestamp
        end
        return a.index < b.index
      end)
    end
  end


  return { noteEvents = noteEvents, automationEvents = automationEvents }
end

-- currently generates a multi-dimensional array, might not be required at all,
-- and instead a linear event list, which then is properly sorted, would work better
function NoteAbstraction:addTrackAutomation(automationEvents, trackNum, patternTrack, lineOffset)
  local track = Song:track(trackNum)

  local automationCache = Cache()

  for y = 2, #track.devices do
    local device = track:device(y)
    local targetDevice
    local deviceIndex = tostring(y)

    local getIndex = function(paramNum)
      return paramNum - 1
    end
    local getType = function(paramNum)
      return "automation"
    end

    local getInstrNum = function()
      local instrCacheKey = 'instrnum_' .. trackNum
      local targetInstrumentNum = automationCache:get(instrCacheKey)
      if (targetInstrumentNum == nil) then
        targetInstrumentNum = SongHelpers:getInstrumentIndexOfTrack(track)
      end
      if (targetInstrumentNum) then
        automationCache:set(instrCacheKey, targetInstrumentNum)
        return targetInstrumentNum
      end

      return nil
    end

    if (device.device_path == "Audio/Effects/Native/*Instr. Automation") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()
      if (targetInstrumentNum) then
        print('found instr autom dev at tr' .. trackNum .. ' target instr nr' .. targetInstrumentNum)
        targetDevice = Song:instrument(targetInstrumentNum)
        deviceIndex = "i" .. targetInstrumentNum

        getIndex = function(paramNum)
          local cacheKey = tostring(y) .. '_' .. paramNum
          if (automationCache:get(cacheKey)) then
            return automationCache:get(cacheKey)
          end

          local paramName = device:parameter(paramNum).name
          local _targetDevice = targetDevice.plugin_properties.plugin_device
          if (_targetDevice == nil) then
            return nil
          end
          for c = 1, #_targetDevice.parameters do
            if (_targetDevice:parameter(c).name == paramName) then
              print('found param name ', paramName, ' at ', c)
              automationCache:set(cacheKey, c - 1)
              return c - 1
            end
          end
          return nil
        end
      end
    elseif (device.device_path == "Audio/Effects/Native/*Instr. MIDI Control") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()
      if (targetInstrumentNum) then
        print('found midi control dev at tr' .. trackNum .. ' target instr nr' .. targetInstrumentNum)
        targetDevice = Song:instrument(targetInstrumentNum)
        deviceIndex = "i" .. targetInstrumentNum

        getIndex = function(paramNum)
          return DeviceHelpers:getActivePresetDataContent(device, 'ControllerNumber' .. paramNum - 1)
        end

        getType = function(paramNum)
          --print('type', DeviceHelpers:getActivePresetDataContent(device, 'ControllerType' .. paramNum - 1))
          return DeviceHelpers:getActivePresetDataContent(device, 'ControllerType' .. paramNum - 1)
        end
      end
    elseif (string.find(device.device_path, "Native/") ~= nil) then
      goto continue
    else
      targetDevice = device
    end

    for paramIndex = 1, #device.parameters do
      local parameter = device:parameter(paramIndex)
      if (parameter.is_automated) then
        local automation = patternTrack:find_automation(parameter)

        if (automation == nil) then
          goto continue2
        end

        for _, point in ipairs(automation.points) do
          if (automationEvents[trackNum] == nil) then
            automationEvents[trackNum] = {}
          end

          local key = y * 256 + paramIndex
          if (automationEvents[trackNum][key] == nil) then
            automationEvents[trackNum][key] = {}
          end

          table.insert(automationEvents[trackNum][key],
            {
              device = targetDevice,
              deviceIndex = deviceIndex,
              paramIndex = getIndex(paramIndex),
              type = getType(paramIndex),
              parameter = parameter,
              timestamp = (lineOffset + point.time - 1) * 256,
              value = point.value,
              scaling = point.scaling
            }
          )
        end

        ::continue2::
      end
    end

    ::continue::
  end
end
