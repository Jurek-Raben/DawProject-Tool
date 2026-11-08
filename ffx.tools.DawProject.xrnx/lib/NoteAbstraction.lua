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

function NoteAbstraction:__init(substitutions)
  self.substitutions = substitutions
  self.automationCache = Cache()
  self.instrumentPools = {}
  self.visibleNoteColumns = {}
  self.mutedNoteColumns = {}
end

-- Hidden note columns keep their data, but Renoise doesn't play them
function NoteAbstraction:isNoteColumnVisible(position)
  local visibleNoteColumns = self.visibleNoteColumns[position.track]
  if (visibleNoteColumns == nil) then
    visibleNoteColumns = Song:track(position.track).visible_note_columns
    self.visibleNoteColumns[position.track] = visibleNoteColumns
  end
  return position.column <= visibleNoteColumns
end

-- Only valid for visible note columns
function NoteAbstraction:isNoteColumnMuted(position)
  local mutedColumns = self.mutedNoteColumns[position.track]
  if (mutedColumns == nil) then
    mutedColumns = {}
    self.mutedNoteColumns[position.track] = mutedColumns
  end

  local isMuted = mutedColumns[position.column]
  if (isMuted == nil) then
    isMuted = Song:track(position.track):column_is_muted(position.column)
    mutedColumns[position.column] = isMuted
  end
  return isMuted
end

-- Returns the instrument of a note as index of Song.instruments.
-- Without a valid instrument, the note uses the last instrument of its column.
function NoteAbstraction:getNoteInstrument(noteColumn, noteKey, lastInstruments)
  local instrumentValue = noteColumn.instrument_value
  if (instrumentValue ~= renoise.PatternLine.EMPTY_INSTRUMENT and instrumentValue < #Song.instruments) then
    lastInstruments[noteKey] = instrumentValue + 1
  end
  return lastInstruments[noteKey]
end

-- Collects the instruments played on each track, so a track can be split by instrument.
-- This has to happen first, since the automation targets depend on the result.
function NoteAbstraction:collectInstrumentPools(yieldCallback)
  local pools = {}
  local lastInstruments = {}
  local numSlots = #Song.sequencer.pattern_sequence

  for seqIndex = 1, numSlots do
    local mutedTracks = {}

    for position, noteColumn in Song.pattern_iterator:note_columns_in_pattern(Song.sequencer:pattern(seqIndex)) do
      if (noteColumn.note_value < renoise.PatternLine.NOTE_OFF and self:isNoteColumnVisible(position)
            and not self:isNoteColumnMuted(position)) then
        local trackNum = position.track
        local noteKey = position.column .. "_" .. trackNum
        local instrumentNum = self:getNoteInstrument(noteColumn, noteKey, lastInstruments)

        if (instrumentNum ~= nil) then
          if (pools[trackNum] == nil) then
            pools[trackNum] = { instruments = {}, counts = {}, audibleCounts = {}, slots = {}, primary = nil }
          end
          local pool = pools[trackNum]

          if (pool.counts[instrumentNum] == nil) then
            table.insert(pool.instruments, instrumentNum)
            pool.counts[instrumentNum] = 0
            pool.audibleCounts[instrumentNum] = 0
          end
          pool.counts[instrumentNum] = pool.counts[instrumentNum] + 1

          if (mutedTracks[trackNum] == nil) then
            mutedTracks[trackNum] = Song.sequencer:track_sequence_slot_is_muted(trackNum, seqIndex)
          end
          if (not mutedTracks[trackNum]) then
            pool.audibleCounts[instrumentNum] = pool.audibleCounts[instrumentNum] + 1
          end

          if (pool.slots[seqIndex] == nil) then
            pool.slots[seqIndex] = {}
          end
          pool.slots[seqIndex][instrumentNum] = (pool.slots[seqIndex][instrumentNum] or 0) + 1
        end
      end
    end

    if (yieldCallback ~= nil and seqIndex % 4 == 0) then
      yieldCallback(seqIndex / numSlots)
    end
  end

  -- The primary instrument is the most played one, muted notes only count if there are no others
  for _, pool in pairs(pools) do
    local primaryAudibleCount = -1
    local primaryCount = -1
    for _, instrumentNum in ipairs(pool.instruments) do
      local audibleCount = pool.audibleCounts[instrumentNum]
      local count = pool.counts[instrumentNum]
      if (audibleCount > primaryAudibleCount or (audibleCount == primaryAudibleCount and count > primaryCount)) then
        pool.primary = instrumentNum
        primaryAudibleCount = audibleCount
        primaryCount = count
      end
    end
  end

  self.instrumentPools = pools
  return pools
end

-- The most played instrument of a sequence slot
function NoteAbstraction:getSlotInstrument(pool, seqIndex)
  local slotInstrument = nil
  local slotCount = 0
  for instrumentNum, count in pairs(pool.slots[seqIndex] or {}) do
    if (count > slotCount or (count == slotCount and instrumentNum < slotInstrument)) then
      slotInstrument = instrumentNum
      slotCount = count
    end
  end
  return slotInstrument or pool.primary
end

function NoteAbstraction:instrumentHasParametersOfDevice(instrumentNum, device, patternTrack)
  local pluginDevice = Song:instrument(instrumentNum).plugin_properties.plugin_device
  if (pluginDevice == nil) then
    return false
  end

  local cacheKey = 'paramnames_' .. instrumentNum
  local parameterNames = self.automationCache:get(cacheKey)
  if (parameterNames == nil) then
    parameterNames = {}
    for paramIndex = 1, #pluginDevice.parameters do
      parameterNames[pluginDevice:parameter(paramIndex).name] = true
    end
    self.automationCache:set(cacheKey, parameterNames)
  end

  for paramIndex = 1, #device.parameters do
    local parameter = device:parameter(paramIndex)
    if (parameter.is_automated and patternTrack:find_automation(parameter) ~= nil and not parameterNames[parameter.name]) then
      return false
    end
  end
  return true
end

-- The target of the instrument devices can't be read via API, so it has to be determined.
-- If that is ambiguous, the instrument playing in the current sequence slot is used.
function NoteAbstraction:findAutomationTargetInstrument(device, deviceIndex, track, trackNum, seqIndex, patternTrack)
  local pool = self.instrumentPools[trackNum]

  if (pool == nil) then
    local cacheKey = 'instrnum_' .. trackNum
    local instrumentNum = self.automationCache:get(cacheKey)
    if (instrumentNum == nil) then
      -- also remember tracks without an instrument, searching the whole song is expensive
      instrumentNum = SongHelpers:getInstrumentIndexOfTrack(track) or false
      self.automationCache:set(cacheKey, instrumentNum)
    end
    return instrumentNum or nil
  end

  local slotInstrument = self:getSlotInstrument(pool, seqIndex)
  if (#pool.instruments == 1 or device.device_path == "Audio/Effects/Native/*Instr. MIDI Control") then
    return slotInstrument
  end

  local firstMatch = nil
  local numMatches = 0
  local isMatching = {}
  for _, instrumentNum in ipairs(pool.instruments) do
    if (self:instrumentHasParametersOfDevice(instrumentNum, device, patternTrack)) then
      firstMatch = firstMatch or instrumentNum
      numMatches = numMatches + 1
      isMatching[instrumentNum] = true
    end
  end

  if (numMatches > 1) then
    self:warnOnceIfAutomated(device, trackNum, deviceIndex, 'warning: target of ' .. device.name .. ' at track ' ..
      trackNum .. ' is ambiguous, using the instrument playing in each pattern')
  end

  if (isMatching[slotInstrument]) then
    return slotInstrument
  end
  if (isMatching[pool.primary]) then
    return pool.primary
  end
  return firstMatch or slotInstrument
end

function NoteAbstraction:generateSongEvents(yieldCallback)
  local noteEvents = {}
  local automationEvents = {}

  local activeNotes = {}
  local lastVelocities = {}
  local lastInstruments = {}
  local lastPointValues = {}

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
      if (not self:isNoteColumnVisible(position)) then
        goto continue
      end

      noteKey = position.column .. "_" .. position.track

      local checkForNoteOffEvent = function(_noteKey)
        -- insert at note-off
        local noteOnExisting = activeNotes[_noteKey]
        if noteOnExisting then
          noteOnExisting.lineDuration = (lineOffset + position.line - 1) - noteOnExisting.absLineNum
          noteOnExisting.duration = ((lineOffset + position.line - 1) * 256 + noteColumn.delay_value) -
              noteOnExisting.timestamp
          noteOnExisting.releaseVelocity = noteColumn.volume_value < 128 and (noteColumn.volume_value / 127) or nil
          table.insert(noteEvents, noteOnExisting)
          -- remove note-on
          activeNotes[_noteKey] = nil
        end
      end

      local checkForPressureAutomationEvent = function(_noteKey)
        local noteOnExisting = activeNotes[_noteKey]
        if (noteOnExisting and noteColumn.note_value == renoise.PatternLine.EMPTY_NOTE and noteColumn.volume_value ~= renoise.PatternLine.EMPTY_VOLUME) then
          table.insert(noteOnExisting.pressureTimeline, {
            value = noteColumn.volume_value / 127,
            timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value - noteOnExisting.timestamp,
          })
        end
      end

      if (position.line == 1 and position.column == 1) then
        local _seqIsMuted = Song.sequencer:track_sequence_slot_is_muted(position.track, seqIndex)
        if (seqIsMuted[position.track] ~= _seqIsMuted) then
          seqIsMuted[position.track] = _seqIsMuted
          checkForNoteOffEvent(noteKey)
        end

        usedTypes = self:addGraphicalTrackAutomation(automationEvents, position.track,
          pattern:track(position.track), lineOffset, lastPointValues, seqIndex)

        if (yieldCallback ~= nil and seqIndex % 4 == 0) then
          yieldCallback(seqIndex / #Song.sequencer.pattern_sequence)
        end
      end

      self:addPatternTrackAutomation(automationEvents, pattern, position, noteColumn, lineOffset, usedTypes)

      -- Only the notes are left out, the automation of the track is attached to the first column
      if (self:isNoteColumnMuted(position)) then
        goto continue
      end

      checkForPressureAutomationEvent(noteKey)

      if noteColumn.is_empty then
        goto continue
      end

      if noteColumn.note_value >= 0 and noteColumn.note_value < renoise.PatternLine.NOTE_OFF then
        checkForNoteOffEvent(noteKey)

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
          instrumentNum = self:getNoteInstrument(noteColumn, noteKey, lastInstruments),
          lineNum = position.line - 1,
          absLineNum = lineOffset + position.line - 1,
          timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
          patternRelTimestamp = (position.line - 1) * 256 + noteColumn.delay_value,
          patternTimestamp = lineOffset * 256,
          enabled = not seqIsMuted[position.track],
          pressureTimeline = {}
        }
        if (noteColumn.volume_value < 128) then
          lastVelocities[noteKey] = noteColumn.volume_value
        end
      elseif noteColumn.note_value == renoise.PatternLine.NOTE_OFF then
        checkForNoteOffEvent(noteKey)
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

function NoteAbstraction:addPatternTrackAutomation(automationEvents, pattern, position, noteColumn, lineOffset, usedTypes)
  -- a column can refer to an instrument that doesn't exist (anymore)
  if (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT and noteColumn.instrument_value >= #Song.instruments) then
    print('warning: skipping invalid instrument ' .. noteColumn.instrument_string ..
      ' at pattern ' .. position.pattern .. ', track ' .. position.track ..
      ', line ' .. position.line .. ', column ' .. position.column)
    return
  end

  local fxColumn = pattern:track(position.track):line(position.line).effect_columns[1]

  -- Midi control messages (CC)
  if ('M0' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value + 1).plugin_properties.plugin_device,
        deviceIndex = "i" .. (noteColumn.instrument_value + 1),
        instrumentNum = noteColumn.instrument_value + 1,
        trackNum = position.track,
        paramIndex = tonumber("0x" .. fxColumn.number_string, 16),
        type = 'CC',
        parameterName = 'CC #' .. fxColumn.number_string,
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.amount_string, 16) / 0x7f,
        interpolation = 'hold', -- a pattern command stays active until the next one
        scaling = 1
      }
    )
  end

  -- Midi pitchbend messages
  if ('M1' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value + 1).plugin_properties.plugin_device,
        deviceIndex = "i" .. (noteColumn.instrument_value + 1),
        instrumentNum = noteColumn.instrument_value + 1,
        trackNum = position.track,
        paramIndex = 200000, -- fake index
        type = 'PB',
        parameterName = 'Pitchbend',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7fff,
        interpolation = 'hold', -- a pattern command stays active until the next one
        scaling = 1,
      }
    )
  end

  -- Channel aftertouch messages
  if ('M3' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value + 1).plugin_properties.plugin_device,
        deviceIndex = "i" .. (noteColumn.instrument_value + 1),
        instrumentNum = noteColumn.instrument_value + 1,
        trackNum = position.track,
        paramIndex = 200001, -- fake index
        type = 'CP',
        parameterName = 'Channel Pressure',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7f,
        interpolation = 'hold', -- a pattern command stays active until the next one
        scaling = 1
      }
    )
  end

  -- Program change messages
  if ('M2' == noteColumn.panning_string) and (noteColumn.instrument_value ~= renoise.PatternLine.EMPTY_INSTRUMENT) then
    table.insert(automationEvents,
      {
        device = Song:instrument(noteColumn.instrument_value + 1).plugin_properties.plugin_device,
        deviceIndex = "i" .. (noteColumn.instrument_value + 1),
        instrumentNum = noteColumn.instrument_value + 1,
        trackNum = position.track,
        paramIndex = 200002, -- fake index
        type = 'Prg',
        parameterName = 'Program Change',
        timestamp = (lineOffset + position.line - 1) * 256 + noteColumn.delay_value,
        value = tonumber("0x" .. fxColumn.number_string .. fxColumn.amount_string, 16) / 0x7f,
        interpolation = 'hold', -- a pattern command stays active until the next one
        scaling = 1
      }
    )
  end
end

-- A problem with the target of a device only matters, if it is automated. Warns once per device.
function NoteAbstraction:warnOnceIfAutomated(device, trackNum, deviceIndex, message)
  local cacheKey = 'warned_' .. trackNum .. '_' .. deviceIndex
  if (self.automationCache:get(cacheKey)) then
    return
  end
  self.automationCache:set(cacheKey, true)

  for paramIndex = 1, #device.parameters do
    if (device:parameter(paramIndex).is_automated) then
      print(message)
      return
    end
  end
end

function NoteAbstraction:warnAboutSkippedAutomation(device, trackNum, deviceIndex, reason)
  self:warnOnceIfAutomated(device, trackNum, deviceIndex,
    'warning: skipping automation of ' .. device.name .. ' at track ' .. trackNum .. ': ' .. reason)
end

-- The name of the slots of an automation device without a target, their automation has no effect
local UNASSIGNED_PARAMETER_NAME = 'No Parameter'

function NoteAbstraction:addGraphicalTrackAutomation(automationEvents, trackNum, patternTrack, lineOffset,
                                                     lastPointValues, seqIndex)
  local usedTypes = {}
  local track = Song:track(trackNum)

  for deviceIndex = 1, #track.devices do
    local device = track:device(deviceIndex)
    local targetDevice
    local eventInstrumentNum
    local deviceIndexString = tostring(deviceIndex)
    local substitution = self.substitutions:findSubstitutionAtDeviceIndex(trackNum, deviceIndex)

    -- the first device is the mixer, its automation only is available through a substitution
    if (deviceIndex == 1 and substitution == nil) then
      goto continue
    end

    local getIndex = function(paramNum)
      return paramNum - 1
    end
    local getType = function(paramNum)
      return "automation"
    end

    local getInstrNum = function()
      return self:findAutomationTargetInstrument(device, deviceIndex, track, trackNum, seqIndex, patternTrack)
    end

    if (substitution ~= nil) then
      targetDevice = device
    elseif (device.device_path == "Audio/Effects/Native/*Instr. Automation") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()

      if (targetInstrumentNum == nil) then
        self:warnAboutSkippedAutomation(device, trackNum, deviceIndex, 'no instrument is playing on this track')
        goto continue
      else
        targetDevice = Song:instrument(targetInstrumentNum).plugin_properties.plugin_device
        deviceIndexString = "i" .. targetInstrumentNum
        eventInstrumentNum = targetInstrumentNum

        if (targetDevice == nil) then
          self:warnAboutSkippedAutomation(device, trackNum, deviceIndex, 'the instrument on this track is no plugin')
          goto continue
        end

        getIndex = function(paramNum)
          local cacheKey = trackNum .. '_' .. deviceIndex .. '_' .. deviceIndexString .. '_' .. paramNum
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
          if (paramName ~= UNASSIGNED_PARAMETER_NAME) then
            print('error: instrument param index not found', targetDevice.name, paramName)
          end
          return nil
        end
      end
    elseif (device.device_path == "Audio/Effects/Native/*Instr. MIDI Control") then
      --local targetInstrumentNum = DeviceHelpers:getActivePresetDataContent(device, 'LinkedInstrument') + 1
      local targetInstrumentNum = getInstrNum()

      if (targetInstrumentNum == nil) then
        self:warnAboutSkippedAutomation(device, trackNum, deviceIndex, 'no instrument is playing on this track')
        goto continue
      else
        targetDevice = Song:instrument(targetInstrumentNum).plugin_properties.plugin_device
        deviceIndexString = "i" .. targetInstrumentNum
        eventInstrumentNum = targetInstrumentNum

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

        if (_paramIndex == nil) then
          goto continue2
        end

        local lastPointIndex = trackNum .. '_' ..
            deviceIndex .. '_' ..
            deviceIndexString .. '_' ..
            _paramIndex -- fixme doesn't work for entries on the very left, ugly too

        if (_type ~= nil) then
          for _, point in ipairs(automation.points) do
            local newPointValue = math.floor(point.value * 100000 + 0.5) / 100000
            if (lastPointValues[lastPointIndex] ~= newPointValue) then
              -- a substituted parameter can target other or even multiple parameters of the plugin
              local targets = { { paramIndex = _paramIndex, name = parameter.name, value = newPointValue } }
              if (substitution ~= nil) then
                targets = substitution:mapAutomationValue(parameter, paramIndex, newPointValue)
              end

              for _, target in ipairs(targets) do
                table.insert(automationEvents,
                  {
                    device = targetDevice,
                    deviceIndex = deviceIndexString,
                    instrumentNum = eventInstrumentNum,
                    trackNum = trackNum,
                    paramIndex = target.paramIndex,
                    type = _type,
                    parameterName = target.name,
                    timestamp = (lineOffset + point.time - 1) * 256,
                    value = target.value,
                    interpolation = automation.playmode == renoise.PatternTrackAutomation.PLAYMODE_POINTS and 'hold' or
                        'linear',
                    scaling = point.scaling
                  }
                )
              end

              lastPointValues[lastPointIndex] = newPointValue
            end

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
