--[[

    Note Abstraction Layer
    for linear DAW export

    Generates an event table of the whole linear song,
    sorted by track number and absolute line number.
    Such a note event also contains merged data as:

    - duration, exact timestamp. Takes care of missing note-offs, disabled sequence slots etc.
    - normalized per-note-data like “velocity”, "pan", etc.
    - Elimates pattern abstraction, linear output

    Also generates related automation events in a flat table

    by Jurek Raben

--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--]]


require('lib/Cache')


class "NoteAbstraction"

NoteAbstraction.automationCache = Cache()

function NoteAbstraction:__init()
  self.automationCache = Cache()
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
  local usedTypes = {}
  local lineOffset = 0

  for seqIndex = 1, #Song.sequencer.pattern_sequence do
    patternIndex = Song.sequencer:pattern(seqIndex)
    pattern = Song:pattern(patternIndex)
    patternLines = pattern.number_of_lines

    for position, noteColumn in Song.pattern_iterator:note_columns_in_pattern(patternIndex) do
      noteKey = position.column .. "_" .. position.track

      local checkForNoteEvent = function(_noteKey)
        -- insert at note-off
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

        usedTypes = NoteAbstraction:addTrackAutomation(automationEvents, position.track,
          pattern:track(position.track), lineOffset)

        if (yieldCallback ~= nil and seqIndex % 4 == 0) then yieldCallback() end
      end

      NoteAbstraction:addPatternAutomation(automationEvents, pattern, position, noteColumn, lineOffset, usedTypes)

      if noteColumn.is_empty then
        goto continue
      end

      if noteColumn.note_value >= 0 and noteColumn.note_value < renoise.PatternLine.NOTE_OFF then
        checkForNoteEvent(noteKey)

        -- prepare at note-on
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

  table.sort(automationEvents, function(a, b)
    if (a.trackNum == b.trackNum) then
      if (a.deviceIndex == b.deviceIndex) then
        if (a.paramIndex == b.paramIndex) then
          return a.timestamp < b.timestamp
        end
        return a.paramIndex < b.paramIndex
      end
      return a.deviceIndex < b.deviceIndex
    end
    return a.trackNum < b.trackNum
  end)

  return { noteEvents = noteEvents, automationEvents = automationEvents }
end

function NoteAbstraction:addPatternAutomation(automationEvents, pattern, position, noteColumn, lineOffset, usedTypes)
  local fxColumn = pattern:track(position.track):line(position.line).effect_columns[1]

  -- Midi control messages (CC)
  if ('M0' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value).plugin_properties.plugin_device,
        deviceIndex = "i" .. noteColumn.instrument_value,
        trackNum = position.track,
        paramIndex = tonumber("0x" .. fxColumn.number_string, 16),
        type = 'CC',
        parameterName = 'CC #' .. fxColumn.number_string,
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.amount_string, 16) / 0x7f,
        scaling = 1
      }
    )
  end

  -- Midi pitchbend messages
  if ('M1' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value).plugin_properties.plugin_device,
        deviceIndex = "i" .. noteColumn.instrument_value,
        trackNum = position.track,
        paramIndex = 200000, -- fake index
        type = 'PB',
        parameterName = 'Pitchbend',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7f7f,
        scaling = 1
      }
    )
  end

  -- Channel aftertouch messages
  if ('M3' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value).plugin_properties.plugin_device,
        deviceIndex = "i" .. noteColumn.instrument_value,
        trackNum = position.track,
        paramIndex = 200001, -- fake index
        type = 'CP',
        parameterName = 'Channel Pressure',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7f,
        scaling = 1
      }
    )
  end

  -- Program change messages
  if ('M2' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value).plugin_properties.plugin_device,
        deviceIndex = "i" .. noteColumn.instrument_value,
        trackNum = position.track,
        paramIndex = 200002, -- fake index
        type = 'Prg',
        parameterName = 'Program Change',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7f,
        scaling = 1
      }
    )
  end
end

function NoteAbstraction:addTrackAutomation(automationEvents, trackNum, patternTrack, lineOffset)
  local usedTypes = {}
  local track = Song:track(trackNum)

  for y = 2, #track.devices do
    local device = track:device(y)
    local targetDevice
    local deviceIndexString = tostring(y)

    local getIndex = function(paramNum)
      return paramNum - 1
    end
    local getType = function(paramNum)
      return "automation"
    end

    local getInstrNum = function()
      local instrCacheKey = 'instrnum_' .. trackNum
      local targetInstrumentNum = self.automationCache:get(instrCacheKey)
      if (targetInstrumentNum == nil) then
        targetInstrumentNum = SongHelpers:getInstrumentIndexOfTrack(track)
      end
      if (targetInstrumentNum) then
        self.automationCache:set(instrCacheKey, targetInstrumentNum)
        return targetInstrumentNum
      end

      return nil
    end

    if (device.device_path == "Audio/Effects/Native/*Instr. Automation") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()

      if (targetInstrumentNum == nil) then
        print('error: could not find instr autom dev at tr' .. trackNum)
      else
        targetDevice = Song:instrument(targetInstrumentNum).plugin_properties.plugin_device
        deviceIndexString = "i" .. targetInstrumentNum

        getIndex = function(paramNum)
          local cacheKey = trackNum .. y .. '_' .. paramNum
          if (self.automationCache:get(cacheKey)) then
            return self.automationCache:get(cacheKey)
          end

          local paramName = device:parameter(paramNum).name
          for c = 1, #targetDevice.parameters do
            if (targetDevice:parameter(c).name == paramName) then
              self.automationCache:set(cacheKey, c - 1)
              return c - 1
            end
          end
          print('error: instrument param index not found', targetDevice.name, paramName)
          return nil
        end
      end
    elseif (device.device_path == "Audio/Effects/Native/*Instr. MIDI Control") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()

      if (targetInstrumentNum == nil) then
        print('error: could not find midi control dev at tr' .. trackNum)
      else
        targetDevice = Song:instrument(targetInstrumentNum).plugin_properties.plugin_device
        deviceIndexString = "i" .. targetInstrumentNum

        getIndex = function(paramNum)
          return tonumber(DeviceHelpers:getActivePresetDataContent(device, 'ControllerNumber' .. paramNum - 1))
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

        local _type = getType(paramIndex)
        local _paramIndex = getIndex(paramIndex)

        if (_type ~= nil) then
          for _, point in ipairs(automation.points) do
            table.insert(automationEvents,
              {
                device = targetDevice,
                deviceIndex = deviceIndexString,
                trackNum = trackNum,
                paramIndex = _paramIndex,
                type = _type,
                parameterName = parameter.name,
                timestamp = (lineOffset + point.time - 1) * 256,
                value = point.value,
                scaling = point.scaling
              }
            )

            if (usedTypes[_type] == nil) then
              usedTypes[_type] = {}
            end
            if (not Helpers:tableContains(usedTypes[_type], _paramIndex)) then
              table.insert(usedTypes[_type], _paramIndex)
            end
          end
        end

        ::continue2::
      end
    end

    ::continue::
  end
  return usedTypes
end
