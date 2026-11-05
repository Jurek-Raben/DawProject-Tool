_AUTO_RELOAD_DEBUG = function()
end
--------------------------------------------------------------------------------
-- Daw Project
-- by Jurek Raben
-- v0.1.13
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--------------------------------------------------------------------------------

package.path = "lib/xml2lua/?.lua;" .. package.path
require('lib/lib-configurator')
require('lib/ProgressDialog')
require('lib/ProcessSlicer')
require('lib/NoteAbstraction')
require('lib/GeneralHelpers')
require('lib/SongHelpers')
require('lib/DeviceHelpers')
require('lib/ReduxPluginHelpers')
require('lib/Cache')


--------------------------------------------------------------------------------
-- Global helpers
--------------------------------------------------------------------------------

Song = renoise.song() -- needs a refresh later
Tool = renoise.tool()
local progressDialog = nil
local process = nil
local noteAbstraction = nil


--------------------------------------------------------------------------------

class "DawProject"

DawProject.configurator = nil
DawProject.automatedParametersCache = Cache()
DawProject.instrIndexCache = Cache()
DawProject.toolPluginCache = Cache()
local config = {}

TempDir = './tmp'
ReduxVST3Identifier = '5653545252445872656E6F6973652072'
ZipPackCommand = 'cd ' .. TempDir .. ' && tar -acvf %s --exclude=".DS_Store" --exclude="*.xrni" %s'
ZipUnpackCommand = 'tar -xf %s --directory ' .. TempDir
-- GNU tar can't create zip files, unlike the bsdtar of macOS and Windows
if (os.platform() == 'LINUX') then
  ZipPackCommand = 'cd ' .. TempDir .. ' && zip -FSr %s %s -x "*.DS_Store" "*.xrni"'
end

--------------------------------------------------------------------------------
-- Default Config
--------------------------------------------------------------------------------

DawProject.defaultConfig = {
  convertToRedux = true,
  exportVST2 = true,
  exportVST3 = true,
  addTrackDelayToClips = true,
  devMode = true,
  useVST2InfoTool = true,
  useVST3InfoTool = true
}

DawProject.configDescription = {
  convertToRedux = { type = "boolean", txt = "Convert sample instruments to Redux" },
  exportVST2 = { type = "boolean", txt = "Export VST2 plugins (not possible due to api limitations)" },
  exportVST3 = { type = "boolean", txt = "Export VST3 plugins" },
  addTrackDelayToClips = { type = "boolean", txt = "Add the track delay ms to the clip position" },
  devMode = { type = "boolean", txt = "Adds some debugging menu entries / functionality" },
  useVST2InfoTool = { type = "boolean", txt = "Hacky workaround using a binary tool for plugin id extraction" },
  useVST3InfoTool = { type = "boolean", txt = "Hacky workaround using a binary tool for parameter id extraction" },
}

if (os.platform() == 'MACINTOSH') then
  DawProject.defaultConfig.exportAU = true
  DawProject.configDescription.exportAU = {
    type = "boolean",
    txt = "Export AudioUnit plugins (not possible due to api limitations)",
  }
end


--------------------------------------------------------------------------------
-- Core functionality
--------------------------------------------------------------------------------

SCALE_FACTOR = 1 / 256

function DawProject:generateMarkersDataForXML()
  local markers = {}
  local lineOffset = 0
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb

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

function DawProject:generateNotePressureEventsDataForXML(pressureTimeline)
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb
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

function DawProject:generateNoteEventsDataForXML(songEvents, automationPoints)
  local noteEvents = songEvents.noteEvents

  local lanesObj = {}
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb

  progressDialog:setPhase('Exporting notes', 0.85, 0.93)

  for noteIndex, noteEvent in ipairs(noteEvents) do
    if (lanesObj[noteEvent.trackNum] == nil) then
      lanesObj[noteEvent.trackNum] = {
        Clips = {
          _attr = {
            id = 'clips' .. noteEvent.trackNum .. '-' .. noteEvent.seqNum,
          },
          Clip = {},
        },
        _attr = {
          id = 'lanes' .. noteEvent.trackNum .. '-' .. noteEvent.seqNum,
          track = 'track' .. noteEvent.trackNum
        },
        Points = automationPoints[noteEvent.trackNum],
      }
      progressDialog:setPhaseProgress(noteIndex / #noteEvents)
      coroutine.yield()
    end

    local clips = lanesObj[noteEvent.trackNum].Clips.Clip
    if (clips[noteEvent.seqNum] == nil) then
      local trackDelay = 0
      if (config['addTrackDelayToClips']) then
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
              id = 'notes' .. noteEvent.trackNum .. '-' .. noteEvent.seqNum
            }
          },
          _attr = {
            id = 'sublanes' .. noteEvent.trackNum .. '-' .. noteEvent.seqNum
          }
        },
      }
    end

    local notes = lanesObj[noteEvent.trackNum].Clips.Clip[noteEvent.seqNum].Lanes.Notes.Note
    notes[#notes + 1] = {
      _attr = {
        time = Helpers:round(noteEvent.patternRelTimestamp * scaleFactor, 6),
        duration = Helpers:round(noteEvent.duration * scaleFactor, 6),
        channel = 0,
        key = noteEvent.key,
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
          id = 'polypressure' .. noteEvent.trackNum .. '-' .. noteEvent.seqNum .. '-' .. #notes,
          unit = 'linear',
        }
      } or nil

    }
  end

  return lanesObj
end

function DawProject:mapExpressionType(automationEvent)
  if (automationEvent.type == 'PB') then
    return 'pitchBend'
  end
  if (automationEvent.type == 'CC') then
    return 'channelController'
  end
  if (automationEvent.type == 'CP') then
    return 'channelPressure'
  end
  if (automationEvent.type == 'Prg') then
    return 'programChange'
  end

  return nil
end

function DawProject:generateAutomationEventsDataForXML(songEvents)
  local automationEvents = songEvents.automationEvents

  local automationsObj = {}
  local automationLanes = {}
  local parametersObj = {}
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb

  progressDialog:setPhase('Exporting automation', 0.35, 0.55)

  for eventIndex, automationEvent in pairs(automationEvents) do
    local trackNum = automationEvent.trackNum
    local paramIndex = automationEvent.paramIndex
    local parameterIdPrefix = 'paramid-' .. trackNum .. '-' .. automationEvent.deviceIndex

    if (automationsObj[trackNum] == nil) then
      automationsObj[trackNum] = {}
      progressDialog:setPhaseProgress(eventIndex / #automationEvents)
      coroutine.yield()
    end

    -- A lane belongs to one parameter of one device. The lanes are stored with numeric keys,
    -- because xml2lua only repeats a tag for those and turns string keys into tag names.
    local laneKey = parameterIdPrefix .. '-' .. paramIndex .. '-' .. automationEvent.type
    local automationLane = automationLanes[laneKey]
    local expression = DawProject:mapExpressionType(automationEvent)
    if (automationLane == nil) then
      automationLane = {
        _attr = {
          name = automationEvent.parameterName,
          unit = "normalized"
        },
        Target = {
          _attr = {
            parameter = expression == nil and (parameterIdPrefix .. '-' .. paramIndex) or nil,
            expression = expression,
            controller = automationEvent.type == 'CC' and automationEvent.paramIndex or nil,
            channel = "0"
          }
        },
        RealPoint = {}
      }
      automationLanes[laneKey] = automationLane
      table.insert(automationsObj[trackNum], automationLane)
    end

    local points = automationLane.RealPoint
    points[#points + 1] = {
      _attr = {
        time = Helpers:round(automationEvent.timestamp * scaleFactor, 6),
        value = Helpers:round(automationEvent.value, 6),
        interpolation = automationEvent.interpolation,
      }
    }

    -- MIDI data is no plugin parameter. Its number would be read as the index of a parameter.
    if (expression ~= nil) then
      goto nextAutomationEvent
    end

    if (parametersObj[parameterIdPrefix] == nil) then
      parametersObj[parameterIdPrefix] = {}
      progressDialog:setPhaseProgress(eventIndex / #automationEvents)
      coroutine.yield()
    end

    if (parametersObj[parameterIdPrefix][paramIndex] == nil) then
      local parameterID = automationEvent.paramIndex
      -- sample instruments have no plugin device
      local devicePath = automationEvent.device and automationEvent.device.device_path or ''
      local deviceName = automationEvent.device and automationEvent.device.name or 'sample instrument'
      if (config['useVST3InfoTool'] == true and string.find(devicePath, "VST3/") ~= nil) then
        progressDialog:setStatus('Reading parameters of ' .. deviceName)
        local pluginInfo = self.toolPluginCache:get(automationEvent.device.device_path)
        if (pluginInfo == nil) then
          pluginInfo = DeviceHelpers:readPluginInfo(automationEvent.device)
        end

        self.toolPluginCache:set(automationEvent.device.device_path, pluginInfo)

        if (pluginInfo) then
          local foundParamObj = DeviceHelpers:findPluginInfoParameterObjectByIndex(pluginInfo, automationEvent
            .paramIndex)
          if (foundParamObj) then
            print('found param name', foundParamObj['title'])
            print('found param id', foundParamObj['id'])
            print('matching param name', automationEvent.parameterName)
            parameterID = foundParamObj['id']
          end
        end
      end

      if (os.platform() == 'MACINTOSH' and config['exportAU'] == true and string.find(devicePath, "AU/") ~= nil) then
        local pluginInfo = self.toolPluginCache:get(automationEvent.device.device_path)
        if (pluginInfo == nil) then
          local deviceID = DeviceHelpers:getActivePresetDataContent(automationEvent.device, 'PluginIdentifier')
          pluginInfo = DeviceHelpers:extractAUDeviceParameterIDs(deviceID)
        end

        self.toolPluginCache:set(automationEvent.device.device_path, pluginInfo)

        if (pluginInfo) then
          local foundParamObj = DeviceHelpers:findPluginInfoParameterObjectByIndex(pluginInfo, automationEvent
            .paramIndex)
          if (foundParamObj) then
            print('found param id', foundParamObj['id'])
            print('matching param name', automationEvent.parameterName)
            parameterID = foundParamObj['id']
          end
        end
      end

      print('linked param for instr ' .. deviceName, automationEvent.parameterName,
        automationEvent.type, automationEvent.value,
        parameterIdPrefix,
        paramIndex)
      parametersObj[parameterIdPrefix][paramIndex] = {
        _attr = {
          id = parameterIdPrefix .. '-' .. paramIndex,
          name = automationEvent.parameterName,
          parameterID = parameterID,
          unit = automationEvent.unit or 'normalized',
          min = automationEvent.min or "0",
          max = automationEvent.max or "1",
        }
      }
    end

    ::nextAutomationEvent::
  end

  return { automationsObj = automationsObj, parametersObj = parametersObj }
end

function DawProject:addTrackToStructure(track, targetObj)
  progressDialog:advancePhase(#Song.tracks)
  progressDialog:setStatus('Exporting track ' .. track.name)

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

  local sends = DawProject:generateSendsForXML(track)
  if (#sends > 0) then
    _trackObj.Channel.Sends = {}
    _trackObj.Channel.Sends.Send = sends
  end

  local devices = DawProject:generateDevicesForXML(track)
  if (#devices > 0) then
    _trackObj.Channel.Devices = devices
  end

  if (track.type == renoise.Track.TRACK_TYPE_SEQUENCER) then
    _trackObj._attr['contentType'] = 'notes'
    _trackObj.Channel._attr['role'] = 'regular'
  elseif (track.type == renoise.Track.TRACK_TYPE_GROUP) then
    _trackObj._attr['contentType'] = 'tracks'
    _trackObj.Channel._attr['role'] = 'master'
  elseif (track.type == renoise.Track.TRACK_TYPE_SEND) then
    _trackObj._attr['contentType'] = 'audio'
    _trackObj.Channel._attr['role'] = 'effect'
  elseif (track.type == renoise.Track.TRACK_TYPE_MASTER) then
    _trackObj._attr['contentType'] = 'audio notes'
    _trackObj.Channel._attr['role'] = 'master'
  end

  if (targetObj.Track == nil) then
    targetObj.Track = {}
  end

  targetObj.Track[#targetObj.Track + 1] = { _trackObj }
  return _trackObj
end

function DawProject:getParentTracksRecursively(parentTrackName, trackObjs)
  for _objectIndex = 1, Song.sequencer_track_count do
    local _track = Song:track(_objectIndex)
    if (_track.output_routing == parentTrackName) then
      local childObj = self:addTrackToStructure(_track, trackObjs);
      if (_track.type == renoise.Track.TRACK_TYPE_GROUP) then
        self:getParentTracksRecursively(_track.name, childObj)
      end
    end
  end

  return trackObjs
end

function DawProject:generateParentTracksStructureDataForXML(trackName)
  progressDialog:setPhase('Exporting tracks', 0.55, 0.85)

  -- add tracks and groups
  local trackObjs = self:getParentTracksRecursively(trackName, {})
  -- add sends
  for _objectIndex = Song.sequencer_track_count + 2, #Song.tracks do
    local _track = Song:track(_objectIndex)
    self:addTrackToStructure(_track, trackObjs)
  end
  -- add master
  self:addTrackToStructure(Song:track(Song.sequencer_track_count + 1), trackObjs)
  return trackObjs
end

function DawProject:generateDevicesForXML(track)
  local instr
  local devicesObj = {}
  local trackIndex = SongHelpers:getTrackIndex(track)
  local instrIndex = self.instrIndexCache:get(trackIndex) or SongHelpers:getInstrumentIndexOfTrack(track)
  self.instrIndexCache:set(trackIndex, instrIndex)

  if (instrIndex) then
    instr = Song:instrument(instrIndex)
  end

  -- vsti
  if (instr and instr.plugin_properties and instr.plugin_properties.plugin_device) then
    local deviceSavePath = 'instr-tr' .. trackIndex .. '-no' .. instrIndex ..
        '-' .. Helpers:prepareFilenameForXML(instr.name)
    local parameterIdPrefix = 'paramid-' .. trackIndex .. '-i' .. instrIndex
    --print('matching instr parameterIdPrefix', parameterIdPrefix)

    self:addDeviceObj(devicesObj, instr.plugin_properties.plugin_device, deviceSavePath, parameterIdPrefix,
      'instrument', trackIndex)
  end

  -- native instr to redux
  if (config['convertToRedux'] == true and instr and instr.plugin_properties.plugin_device == nil) then
    local deviceSavePath = 'instr-tr' ..
        trackIndex .. '-no' .. instrIndex .. '-' .. Helpers:prepareFilenameForXML(instr.name) .. '-reduxed'
    -- convert Renoise instruments to Redux VST3
    ReduxPluginHelpers:generateReduxPresetDataForInstrument(instr, TempDir .. "/plugins/" .. deviceSavePath)

    devicesObj[#devicesObj + 1] = {
      Vst3Plugin = {
        _attr = {
          id = 'plugin' .. trackIndex .. '-' .. #devicesObj,
          deviceID = ReduxVST3Identifier,
          deviceRole = 'instrument',
          deviceName = 'Redux',
          name = Helpers:prepareFilenameForXML(instr.name),
          loaded = "true"
        },
        Enabled = {
          _attr = {
            id = 'enabled' .. trackIndex .. '-' .. #devicesObj,
            value = 'true'
          }
        },
        State = {
          _attr = {
            path = "plugins/" .. deviceSavePath .. ".vstpreset",
            external = "false"
          }
        },
      }
    }
  end

  coroutine.yield()

  local numDevices = #track.devices
  for deviceIndex = 2, numDevices do
    local device = track:device(deviceIndex)
    local deviceSavePath = 'fx-tr' ..
        trackIndex .. '-no' .. deviceIndex .. '-' .. Helpers:prepareFilenameForXML(device.name)
    local parameterIdPrefix = 'paramid-' .. trackIndex .. '-' .. deviceIndex
    self:addDeviceObj(devicesObj, device, deviceSavePath, parameterIdPrefix, 'audioFX', trackIndex)
  end

  return devicesObj
end

function DawProject:addDeviceObj(devicesObj, device, deviceSavePath, parameterIdPrefix, deviceRole, trackIndex)
  progressDialog:setStatus('Exporting plugin ' .. device.name)

  local parameterChunkData = DeviceHelpers:getParameterChunk(device)
  local deviceId = DeviceHelpers:getActivePresetDataContent(device, 'PluginIdentifier')

  local automatedParametersObj = {
    RealParameter = self.automatedParametersCache:get("parameters")[parameterIdPrefix]
  }

  if (parameterChunkData ~= nil and deviceId ~= nil) then
    local binParameterChunkData = Helpers:base64ToString(parameterChunkData)
    coroutine.yield()

    local attr = {
      deviceID = deviceId,
      deviceRole = deviceRole,
      deviceName = Helpers:prepareNameForXML(device.short_name),
      name = Helpers:prepareNameForXML(device.name),
      loaded = "true"
    }
    local enabledAttr
    if (deviceRole == 'audioFX') then
      enabledAttr = {
        id = 'enabled' .. trackIndex .. '-' .. #devicesObj,
        value = device.is_active and 'true' or 'false',
      }
    else
      enabledAttr = {
        id = 'enabled' .. trackIndex .. '-' .. #devicesObj,
        value = 'true'
      }
    end

    -- VST3
    if (config['exportVST3'] == true and string.find(device.device_path, "VST3/") ~= nil) then
      Helpers:writeFile(TempDir .. "/plugins/" .. deviceSavePath .. ".vstpreset", binParameterChunkData)
      devicesObj[#devicesObj + 1] = {
        Vst3Plugin = {
          _attr = attr,
          Enabled = {
            _attr = enabledAttr
          },
          State = {
            _attr = {
              path = "plugins/" .. deviceSavePath .. ".vstpreset",
              external = "false"
            }
          },
          Parameters = automatedParametersObj
        }
      }
      devicesObj[#devicesObj].Vst3Plugin._attr.id = 'plugin' .. trackIndex .. '-' .. #devicesObj
    end

    -- VST2
    if (config['exportVST2'] == true and string.find(device.device_path, "VST/") ~= nil) then
      -- FIXME active_preset_data is defective
      --print('vst2', device.short_name, device.active_preset_data)
      if (config['useVST2InfoTool'] == true) then
        local pluginInfo = self.toolPluginCache:get(device.device_path)
        if (pluginInfo == nil) then
          pluginInfo = DeviceHelpers:readPluginInfo(device)
        end

        coroutine.yield()

        self.toolPluginCache:set(device.device_path, pluginInfo)

        if (pluginInfo) then
          attr.deviceID = pluginInfo['id'] or attr.deviceID
          attr.deviceName = pluginInfo['name'] or attr.deviceName
          attr.deviceVendor = pluginInfo['vendor']
          local presetName = device:preset(device.active_preset)
          binParameterChunkData = DeviceHelpers:convertBinaryToVst2Preset(pluginInfo, presetName, binParameterChunkData)
        else
          -- for now skip vst2 plugins with wrong id
          print('warning: VST2 plugin is missing in the export, since its id is unknown:', device.name)
          attr.deviceID = nil
        end
      end
      Helpers:writeFile(TempDir .. "/plugins/" .. deviceSavePath .. ".fxp", binParameterChunkData)
      if (attr.deviceID ~= nil) then
        devicesObj[#devicesObj + 1] = {
          Vst2Plugin = {
            _attr = attr,
            Enabled = {
              _attr = enabledAttr
            },
            State = {
              _attr = {
                path = "plugins/" .. deviceSavePath .. ".fxp",
                external = "false"
              }
            },
            Parameters = automatedParametersObj
          }
        }
        devicesObj[#devicesObj].Vst2Plugin._attr.id = 'plugin' .. trackIndex .. '-' .. #devicesObj
      end
    end

    -- AudioUnit
    if (os.platform() == 'MACINTOSH' and config['exportAU'] == true and string.find(device.device_path, "AU/") ~= nil) then
      local presetPath = TempDir .. "/plugins/" .. deviceSavePath .. ".aupreset"
      Helpers:writeFile(presetPath, binParameterChunkData)
      DeviceHelpers:convertPListPresetToXML(presetPath)
      attr.deviceID = DeviceHelpers:convertAUDeviceIDToWeirdS1Format(attr.deviceID)
      devicesObj[#devicesObj + 1] = {
        AuPlugin = {
          _attr = attr,
          Enabled = {
            _attr = enabledAttr,
          },
          State = {
            _attr = {
              path = "plugins/" .. deviceSavePath .. ".aupreset",
              external = "false"
            }
          },
          Parameters = automatedParametersObj
        }
      }
      devicesObj[#devicesObj].AuPlugin._attr.id = 'plugin' .. trackIndex .. '-' .. #devicesObj
    end
    coroutine.yield()
  end
end

function DawProject:generateSendsForXML(track)
  local sendObjects = {}
  local numDevices = #track.devices
  for deviceIndex = 1, numDevices do
    local device = track:device(deviceIndex)
    if (device.device_path == "Audio/Effects/Native/#Send") then
      sendObjects[#sendObjects + 1] = {
        _attr = {
          destination = 'track' ..
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

--------------------------------------------------------------------------------
-- Main calls
--------------------------------------------------------------------------------

function DawProject:clearTempDirectory()
  local presetFiles = {}
  pcall(function()
    presetFiles = os.filenames(TempDir .. '/plugins', { '*.aupreset', '*.vstpreset', '*.fxp', '*.xrni' })
  end)
  for i in pairs(presetFiles) do
    os.remove(TempDir .. '/plugins/' .. presetFiles[i])
  end
  os.remove(TempDir .. '/plugins')
  os.remove(TempDir .. '/project.xml')
  os.remove(TempDir .. '/metadata.xml')
  os.mkdir(TempDir)
  os.mkdir(TempDir .. '/plugins')
end

function DawProject:export()
  if (process and process:running()) then
    process:stop()
  end
  self:clearTempDirectory()

  local filePath = renoise.app():prompt_for_filename_to_write('dawproject', 'Export to dawproject...')
  if filePath == '' then
    return
  end

  progressDialog:start('Export', function()
    if (process and process:running()) then
      process:stop()
    end
  end)

  process = ProcessSlicer(
    function()
      local xml2lua = require("lib/xml2lua/xml2lua")

      local yieldCallback = function(fraction)
        if (fraction ~= nil) then
          progressDialog:setPhaseProgress(fraction)
        end
        coroutine.yield()
      end

      progressDialog:setPhase('Reading notes and automation', 0, 0.35)
      yieldCallback()
      noteAbstraction = NoteAbstraction()
      local songEvents = noteAbstraction:generateSongEvents(yieldCallback)

      local automationEvents = DawProject:generateAutomationEventsDataForXML(songEvents)
      self.automatedParametersCache:set('parameters', automationEvents.parametersObj)

      yieldCallback()

      local projectStructure = {
        Project = {
          _attr = {
            version = '1.0'
          },
          Application = {
            _attr = { name = 'Renoise', version = renoise.RENOISE_VERSION }
          },
          Transport = {
            Tempo = {
              _attr = {
                min = '20', max = '999', unit = 'bpm', name = 'Tempo', value = Song.transport.bpm
              },
            },
            TimeSignature = {
              _attr = {
                numerator = 4, denominator = 4
              },
            },
          },

          Structure = self:generateParentTracksStructureDataForXML('Master'),
          Arrangement = {
            Lanes = {
              _attr = {
                timeUnit = "beats",
              },
              Lanes = self:generateNoteEventsDataForXML(songEvents, automationEvents.automationsObj),
            },
            Markers = self:generateMarkersDataForXML()
          }
        }
      }

      -- show the next steps before these block for a moment
      progressDialog:setPhase('Writing project file', 0.93, 0.97)
      yieldCallback()

      local fileContent = xml2lua.toXml(projectStructure)
      fileContent = '<?xml version="1.0" encoding="UTF-8"?>\n' .. fileContent

      -- ugly workaround
      fileContent = string.gsub(fileContent, "</Devices>([ \t\r\n]+)<Devices>", "")

      Helpers:writeFile(TempDir .. "/project.xml", fileContent)

      local metaData = {
        MetaData = {
          Artist = Song.artist,
          Title = Song.name,
          Comment = Song.file_name
        }
      }

      fileContent = xml2lua.toXml(metaData)
      fileContent = '<?xml version="1.0" encoding="UTF-8"?>\n' .. fileContent
      Helpers:writeFile(TempDir .. "/metadata.xml", fileContent)

      progressDialog:setPhase('Packing .dawproject file', 0.97, 1)
      yieldCallback()

      os.execute(string.format(ZipPackCommand, '../dawproject.zip', '*'))
      os.move('./dawproject.zip', filePath)

      if (not config.devMode) then
        self:clearTempDirectory()
      end
    end,
    function() progressDialog:finish('Export done!') end
  )
  process:set_error_callback(function(errorMessage)
    progressDialog:fail('Export failed!', errorMessage)
  end)

  process:start()
end

function DawProject:import()
  if (process and process:running()) then
    process:stop()
  end
  self:clearTempDirectory()
  local xml2lua = require("lib/xml2lua/xml2lua")
  local handler = require("xmlhandler.tree")

  local filePath = renoise.app():prompt_for_filename_to_read({ '*.dawproject' }, 'Import dawproject...')
  if filePath == '' then
    return
  end
  -- unzip first
  local fileContent = Helpers:readFile(filePath)

  local parser = xml2lua.parser(handler)
  parser:parse(fileContent)
  local data = handler.root
  rprint(data)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function DawProject:__init()
  local instrSwitchListener = function()
    if (config['convertToRedux'] == nil or Song.selected_instrument.plugin_properties.plugin_device ~= nil or #Song.selected_instrument.samples == 0) then
      MenuEntry:remove("Instrument Box:Convert to Redux")
    else
      MenuEntry:add("Instrument Box:Convert to Redux", function()
        if (process and process:running()) then
          process:stop()
        end
        self:clearTempDirectory()
        ReduxPluginHelpers:convertCurrentInstrumentToRedux()
      end)
    end
  end

  local refreshMenus = function()
    MenuEntry:remove("Main Menu:Song:Convert all sample instruments to Redux")
    MenuEntry:remove("Main Menu:File:Repack .dawproject...")
    if (config['convertToRedux'] ~= nil) then
      MenuEntry:add("Main Menu:Song:Convert all sample instruments to Redux", function()
        if (process and process:running()) then
          process:stop()
        end
        self:clearTempDirectory()
        progressDialog:start('Convert to Redux', function()
          if (process and process:running()) then
            process:stop()
          end
        end)
        process = ProcessSlicer(
          function()
            Song:describe_batch_undo('Convert all sample instruments to Redux', 10000)
            for index = 1, #Song.instruments do
              coroutine.yield()
              progressDialog:setStatus('Converting instrument #' .. index .. ' of ' .. #Song.instruments .. ' to Redux')
              progressDialog:setProgress((index - 1) / #Song.instruments)
              Song.selected_instrument_index = index
              ReduxPluginHelpers:convertCurrentInstrumentToRedux()
            end
          end,
          function() progressDialog:finish('Conversion done!') end
        )
        process:set_error_callback(function(errorMessage)
          progressDialog:fail('Conversion failed!', errorMessage)
        end)
        process:start()
      end)
    end

    if (config.devMode == true) then
      MenuEntry:add("Main Menu:File:Repack .dawproject...", function()
        local filePath = renoise.app():prompt_for_filename_to_write('dawproject', 'Repack .dawproject...')
        if filePath == '' then
          return
        end
        os.execute(string.format(ZipPackCommand, '../dawproject.zip', '*'))
        os.move('./dawproject.zip', filePath)
      end)
    end
  end

  local toolIdle
  toolIdle = function()
    Notifiers:remove(Tool.app_idle_observable, toolIdle)

    if (not ReduxPluginHelpers:isReduxVST3Available()) then
      self.defaultConfig.convertToRedux = nil
    end

    self.configurator = LibConfigurator(LibConfigurator.SAVE_MODE.FILE, self.defaultConfig, "config.json")
    config = self.configurator:getConfig()

    self.configurator:addMenu("ffx.tools.DawProject", self.configDescription,
      function(newConfig)
        config = newConfig
        refreshMenus()
      end
    )

    Tool:add_keybinding {
      name = "Global:Tools:Export to .dawproject...",
      invoke = function() self:export() end
    }

    -- TODO import
    --Tool:add_keybinding {
    --  name = "Global:Tools:Import .dawproject...",
    --  invoke = function() self:import() end
    --}

    MenuEntry:add("Main Menu:File:Export Song to .dawproject...", function() self:export() end)

    -- TODO import
    -- MenuEntry:add("Main Menu:File:Import .dawproject Song...", function() self:import() end)

    refreshMenus()
  end


  local newDocumentListener = function()
    Song = renoise.song()
    renoise.song()
    Notifiers:add(Song.selected_instrument_index_observable, instrSwitchListener)
  end

  local releaseDocumentListener = function()
    Song = renoise.song()
    if (process and process:running()) then
      process:stop()
      process = nil
    end
    progressDialog:close()
    Notifiers:remove(Song.selected_instrument_index_observable, instrSwitchListener)
  end

  progressDialog = ProgressDialog()

  Notifiers:add(Tool.app_idle_observable, toolIdle)
  Notifiers:add(Tool.app_new_document_observable, newDocumentListener)
  Notifiers:add(Tool.app_release_document_observable, releaseDocumentListener)
end

DawProject()
