-------------------------------------------------------------------------------
-- Track Exporter, generates the structure of the project: the tracks, groups,
-- send tracks and the master track with their mixer settings.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "TrackExporter"

function TrackExporter:__init(config, progress, layout, deviceExporter)
  self.config = config
  self.progress = progress
  self.layout = layout
  self.deviceExporter = deviceExporter
end

-- Every channel names the channel it is routed to. The channel of a group is a submix channel,
-- but the DAWs expect it at different places:
--  - Cubase only routes into a group, if its channel is directly in the structure, outside of the
--    folder track of the group.
--  - Bitwig and Studio only keep the plugins of a group, if its channel is inside of the folder
--    track. It has to be the first child, before the tracks of the group.
function TrackExporter:addGroupChannel(groupObj)
  if (self.config['exportForCubase'] == true) then
    table.insert(self.structureChannels, groupObj.Channel)
    groupObj.Channel = nil
  else
    groupObj._order = { 'Channel' }
  end
end

-- Renoise applies the volume of the instrument, and of its plugin, before the effects of the track.
-- A DAW has no such volume, so it becomes part of the volume of the channel playing the instrument.
function TrackExporter:getInstrumentVolume(instrumentNum)
  if (instrumentNum == nil) then
    return 1
  end
  local instrument = Song:instrument(instrumentNum)
  local volume = instrument.volume
  if (instrument.plugin_properties.plugin_device ~= nil) then
    volume = volume * instrument.plugin_properties.volume
  end
  return volume
end

-- The instrument of a track that is not split, like the device exporter finds it
function TrackExporter:findInstrumentOfTrack(track, trackIndex)
  local pool = self.layout.instrumentPools[trackIndex]
  return pool and pool.primary or SongHelpers:getInstrumentIndexOfTrack(track)
end

-- destinationChannelId is the channel the track is routed to, nil for the master
function TrackExporter:addTrackToStructure(track, targetObj, destinationChannelId)
  self.progress:advancePhase(#Song.tracks)
  self.progress:setStatus('Exporting track ' .. track.name)

  local comment = ''
  if (track.output_delay ~= 0) then
    comment = comment .. "Delay: " .. track.output_delay
  end

  local trackIndex = SongHelpers:getTrackIndex(track)

  local _trackObj = {
    _attr = {
      id = 'track' .. trackIndex,
      name = Helpers:prepareNameForXML(track.name),
      color = '#' .. Helpers:rgbToHex(track.color[1], track.color[2], track.color[3]),
      comment = comment
    },
    Channel = {
      _attr = {
        id = 'channel' .. trackIndex,
        name = Helpers:prepareNameForXML(track.name),
        audioChannels = '2',
        solo = track.solo_state and 'true' or 'false'
      },
      Mute = {
        _attr = {
          id = 'mute' .. trackIndex,
          value = track.mute_state == renoise.Track.MUTE_STATE_ACTIVE and 'false' or 'true',
        }
      },
      Pan = {
        _attr = {
          id = 'pan' .. trackIndex,
          value = track.postfx_panning.value,
          unit = "normalized",
          min = '0',
          max = '1',
        }
      },
      Volume = {
        _attr = {
          id = 'vol' .. trackIndex,
          min = '0',
          max = '2',
          unit = "linear",
          value = track.postfx_volume.value,
        }
      },
    }
  }

  local sends = self:generateSendsForXML(track)
  if (#sends > 0) then
    _trackObj.Channel.Sends = {}
    _trackObj.Channel.Sends.Send = sends
  end

  local devices = self.deviceExporter:generateDevicesForXML(track)
  if (#devices > 0) then
    _trackObj.Channel.Devices = devices
  end

  local isGroup = false
  if (self.layout:isTrackSplit(trackIndex)) then
    isGroup = true
    _trackObj._attr['contentType'] = 'tracks'
    _trackObj.Channel._attr['role'] = 'submix'
    for _, instrumentNum in ipairs(self.layout.instrumentPools[trackIndex].instruments) do
      self:addInstrumentTrackToStructure(track, trackIndex, instrumentNum, _trackObj, _trackObj.Channel._attr.id)
    end
  elseif (track.type == renoise.Track.TRACK_TYPE_SEQUENCER) then
    _trackObj._attr['contentType'] = 'notes'
    _trackObj.Channel._attr['role'] = 'regular'
    _trackObj.Channel.Volume._attr.value = track.postfx_volume.value *
        self:getInstrumentVolume(self:findInstrumentOfTrack(track, trackIndex))
  elseif (track.type == renoise.Track.TRACK_TYPE_GROUP) then
    isGroup = true
    _trackObj._attr['contentType'] = 'tracks'
    _trackObj.Channel._attr['role'] = 'submix'
  elseif (track.type == renoise.Track.TRACK_TYPE_SEND) then
    _trackObj._attr['contentType'] = 'audio'
    _trackObj.Channel._attr['role'] = 'effect'
  elseif (track.type == renoise.Track.TRACK_TYPE_MASTER) then
    _trackObj._attr['contentType'] = 'audio notes'
    _trackObj.Channel._attr['role'] = 'master'
  end

  -- the headroom of the song belongs into the pre mixer plugin, without it into the volume of the channel
  if (track.type == renoise.Track.TRACK_TYPE_SEQUENCER and
        self.deviceExporter.substitutions:findPreMixerSubstitution(trackIndex) == nil) then
    _trackObj.Channel.Volume._attr.value = _trackObj.Channel.Volume._attr.value * getTrackHeadroom(track)
  end

  _trackObj.Channel._attr['destination'] = destinationChannelId

  if (isGroup) then
    self:addGroupChannel(_trackObj)
  end

  if (targetObj.Track == nil) then
    targetObj.Track = {}
  end

  targetObj.Track[#targetObj.Track + 1] = { _trackObj }
  return _trackObj
end

-- One instrument of a split track. The mixer settings and effects stay on the group.
function TrackExporter:addInstrumentTrackToStructure(track, trackIndex, instrumentNum, groupObj, groupChannelId)
  local instrument = Song:instrument(instrumentNum)
  local trackId = trackIndex .. '-i' .. instrumentNum
  local trackName = Helpers:prepareNameForXML(track.name) .. ' ' .. Helpers:prepareNameForXML(instrument.name)

  local instrumentTrackObj = {
    _attr = {
      id = 'track' .. trackId,
      name = trackName,
      color = '#' .. Helpers:rgbToHex(track.color[1], track.color[2], track.color[3]),
      contentType = 'notes',
    },
    Channel = {
      _attr = {
        id = 'channel' .. trackId,
        name = trackName,
        audioChannels = '2',
        role = 'regular',
        solo = 'false',
        destination = groupChannelId,
      },
      Mute = {
        _attr = {
          id = 'mute' .. trackId,
          value = 'false',
        }
      },
      Pan = {
        _attr = {
          id = 'pan' .. trackId,
          value = '0.5',
          unit = "normalized",
          min = '0',
          max = '1',
        }
      },
      Volume = {
        _attr = {
          id = 'vol' .. trackId,
          min = '0',
          max = '2',
          unit = "linear",
          value = self:getInstrumentVolume(instrumentNum),
        }
      },
    }
  }

  local devices = {}
  self.deviceExporter:addInstrumentDevicesForXML(devices, instrument, instrumentNum, trackIndex, trackId)
  self.deviceExporter:applyDeviceElementOrder(devices)
  if (#devices > 0) then
    instrumentTrackObj.Channel.Devices = devices
  end

  if (groupObj.Track == nil) then
    groupObj.Track = {}
  end
  groupObj.Track[#groupObj.Track + 1] = { instrumentTrackObj }
end

function TrackExporter:getParentTracksRecursively(parentTrackName, trackObjs, destinationChannelId)
  for _objectIndex = 1, Song.sequencer_track_count do
    local _track = Song:track(_objectIndex)
    if (_track.output_routing == parentTrackName) then
      local childObj = self:addTrackToStructure(_track, trackObjs, destinationChannelId);
      if (_track.type == renoise.Track.TRACK_TYPE_GROUP) then
        self:getParentTracksRecursively(_track.name, childObj, 'channel' .. _objectIndex)
      end
    end
  end

  return trackObjs
end

function TrackExporter:generateParentTracksStructureDataForXML(trackName)
  self.progress:setPhase('Exporting tracks', 0.55, 0.85)

  self.structureChannels = {}
  local masterIndex = Song.sequencer_track_count + 1
  local masterChannelId = 'channel' .. masterIndex

  -- add tracks and groups
  local trackObjs = self:getParentTracksRecursively(trackName, {}, masterChannelId)
  -- add sends
  for _objectIndex = Song.sequencer_track_count + 2, #Song.tracks do
    local _track = Song:track(_objectIndex)
    self:addTrackToStructure(_track, trackObjs, masterChannelId)
  end
  -- add master
  self:addTrackToStructure(Song:track(masterIndex), trackObjs, nil)

  -- the channels of the groups follow the tracks, like in the projects of Cubase
  if (#self.structureChannels > 0) then
    trackObjs.Channel = self.structureChannels
    trackObjs._order = { 'Track', 'Channel' }
  end
  return trackObjs
end

function TrackExporter:generateSendsForXML(track)
  local sendObjects = {}
  local numDevices = #track.devices
  for deviceIndex = 1, numDevices do
    local device = track:device(deviceIndex)
    if (device.device_path == "Audio/Effects/Native/#Send") then
      sendObjects[#sendObjects + 1] = {
        _attr = {
          -- the destination is the channel of the send track, not the track
          destination = 'channel' ..
              (device:parameter(3).value + Song.sequencer_track_count + 2),
          type = 'post',
          id = 'send' .. SongHelpers:getTrackIndex(track) .. '-' .. deviceIndex
        },
        Enable = { _attr = { value = device.is_active and 'true' or 'false' } },
        Volume = { _attr = { max = device:parameter(1).value_max, min = device:parameter(1).value_min, unit = "linear", value = device:parameter(1).value } },
        Pan = { _attr = { max = device:parameter(2).value_max, min = device:parameter(2).value_min, unit = "normalized", value = device:parameter(2).value } }
      }

      -- TODO include multiband sends?
      --elseif (device.device_path == "Audio/Effects/Native/#Multiband Send") then
      --  end
    end
  end

  return sendObjects
end
