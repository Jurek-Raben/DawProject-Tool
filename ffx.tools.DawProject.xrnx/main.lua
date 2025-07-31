_AUTO_RELOAD_DEBUG = function()
end
--------------------------------------------------------------------------------
-- Daw Project
-- by Jurek Raben
-- v0.1.2
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--------------------------------------------------------------------------------

package.path = "lib/xml2lua/?.lua;" .. package.path
require('lib/lib-configurator')
require('lib/FancyStatusMessage')
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
local fancyStatus = nil
local process = nil
local noteAbstraction = nil


--------------------------------------------------------------------------------

class "DawProject"

DawProject.configurator = nil
DawProject.automatedParametersCache = Cache()
local config = {}

TempDir = './tmp'
ReduxVST3Identifier = '5653545252445872656E6F6973652072'
ZipPackCommand = 'cd ' .. TempDir .. ' && tar -acvf %s --exclude=".DS_Store" --exclude="*.xrni" %s'
ZipUnpackCommand = 'tar -xf %s --directory ' .. TempDir

--------------------------------------------------------------------------------
-- Default Config
--------------------------------------------------------------------------------

DawProject.defaultConfig = {
  convertToRedux = true,
  exportVST2 = false,
  exportVST3 = true,
  addTrackDelayToClips = true,
  devMode = true,
  useVST2InfoTool = true
}

DawProject.configDescription = {
  convertToRedux = { type = "boolean", txt = "Convert sample instruments to Redux" },
  exportVST2 = { type = "boolean", txt = "Export VST2 plugins (not possible due to api limitations)" },
  exportVST3 = { type = "boolean", txt = "Export VST3 plugins" },
  addTrackDelayToClips = { type = "boolean", txt = "Add the track delay ms to the clip position" },
  devMode = { type = "boolean", txt = "Adds some debugging menu entries / functionality" },
  useVST2InfoTool = { type = "boolean", txt = "Hacky workaround using a binary tool for plugin id extraction" },
}

if (os.platform() == 'MACINTOSH') then
  DawProject.defaultConfig.exportAU = false
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

function DawProject:generateNoteEventsDataForXML(songEvents, automationPoints)
  local noteEvents = songEvents.noteEvents

  local lanesObj = {}
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb

  for _, noteEvent in ipairs(noteEvents) do
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
      coroutine.yield()
      fancyStatus:show_status('Exporting note data to .dawproject' .. Helpers:generateStatusAnimation())
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
        rel = noteEvent.releaseVelocity
      }
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

  return nil
end

function DawProject:generateAutomationEventsDataForXML(songEvents)
  local automationEvents = songEvents.automationEvents

  local automationsObj = {}
  local parametersObj = {}
  local scaleFactor = SCALE_FACTOR / Song.transport.lpb

  for trackNum, trackAutomationEvents in pairs(automationEvents) do
    coroutine.yield()
    fancyStatus:show_status('Exporting automation data to .dawproject' .. Helpers:generateStatusAnimation())


    for index, deviceAutomationEvents in pairs(trackAutomationEvents) do
      for _, automationEvent in pairs(deviceAutomationEvents) do
        local parameterIdPrefix = 'paramid-' .. trackNum .. '-' .. automationEvent.deviceIndex

        if (automationsObj[trackNum] == nil) then
          automationsObj[trackNum] = {}
        end
        if (automationsObj[trackNum][index] == nil) then
          automationsObj[trackNum][index] = {
            _attr = {
              name = automationEvent.parameter.name,
              unit = "normalized"
            },
            Target = {
              _attr = {
                parameter = parameterIdPrefix .. '-' .. index,
                expression = DawProject:mapExpressionType(automationEvent),
                controller = automationEvent.type == 'CC' and automationEvent.paramIndex or nil,
                channel = "0"
              }
            },
            RealPoint = {}
          }
        end

        if (parametersObj[parameterIdPrefix] == nil) then
          parametersObj[parameterIdPrefix] = {}
        end

        if (parametersObj[parameterIdPrefix][index] == nil) then
          print('param', automationEvent.parameter.name, automationEvent.type, automationEvent.value, parameterIdPrefix,
            index)
          parametersObj[parameterIdPrefix][index] = {
            _attr = {
              id = parameterIdPrefix .. '-' .. index,
              name = automationEvent.parameter.name,
              parameterID = automationEvent.paramIndex,
              unit = "normalized",
              min = "0",
              max = "1"
            }
          }
        end

        local points = automationsObj[trackNum][index].RealPoint
        points[#points + 1] = {
          _attr = {
            time = Helpers:round(automationEvent.timestamp * scaleFactor, 6),
            value = Helpers:round(automationEvent.value, 6),
            interpolation = 'linear'

          }
        }
      end
    end
  end

  return { automationsObj = automationsObj, parametersObj = parametersObj }
end

function DawProject:addTrackToStructure(track, targetObj)
  local comment = ''
  if (track.output_delay ~= 0) then
    comment = comment .. "Delay: " .. track.output_delay
  end


  local _trackObj = {
    _attr = {
      id = 'track' .. SongHelpers:getTrackIndex(track),
      name = Helpers:prepareNameForXML(track.name),
      color = '#' .. Helpers:rgbToHex(track.color[1], track.color[2], track.color[3]),
      comment = comment
    },
    Channel = {
      _attr = {
        id = 'channel' .. SongHelpers:getTrackIndex(track),
        name = Helpers:prepareNameForXML(track.name),
        audioChannels = '2',
        solo = track.solo_state and 'true' or 'false'
      },
      Mute = {
        _attr = {
          id = 'mute' .. SongHelpers:getTrackIndex(track),
          value = track.mute_state == renoise.Track.MUTE_STATE_ACTIVE and 'false' or 'true',
        }
      },
      Pan = {
        _attr = {
          id = 'pan' .. SongHelpers:getTrackIndex(track),
          value = track.postfx_panning.value,
          unit = "normalized",
          min = '0',
          max = '1',
        }
      },
      Volume = {
        _attr = {
          id = 'vol' .. SongHelpers:getTrackIndex(track),
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
  fancyStatus:show_status('Exporting track structure to .dawproject' .. Helpers:generateStatusAnimation())

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
  local instrIndex = SongHelpers:getInstrumentIndexOfTrack(track)
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
  local parameterChunkData = DeviceHelpers:getParameterChunk(device)
  local deviceId = DeviceHelpers:getActivePresetDataContent(device, 'PluginIdentifier')

  local automatedParametersObj = {
    RealParameter = self.automatedParametersCache:get("parameters")[parameterIdPrefix]
  }

  if (parameterChunkData ~= nil and deviceId ~= nil) then
    local binParameterChunkData = Helpers:base64ToString(parameterChunkData)
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
        attr.deviceID = DeviceHelpers:readPluginInfo(device)['id'] or attr.deviceID
      end
      Helpers:writeFile(TempDir .. "/plugins/" .. deviceSavePath .. ".fxp", binParameterChunkData)
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

    -- AudioUnit
    if (os.platform() == 'MACINTOSH' and config['exportAU'] == true and string.find(device.device_path, "AU/") ~= nil) then
      -- FIXME active_preset_data is defective
      Helpers:writeFile(TempDir .. "/plugins/" .. deviceSavePath .. ".aupreset", binParameterChunkData)
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

  process = ProcessSlicer(
    function()
      local xml2lua = require("lib/xml2lua/xml2lua")

      noteAbstraction = NoteAbstraction()
      local songEvents = noteAbstraction:generateSongEvents()

      local automationEvents = DawProject:generateAutomationEventsDataForXML(songEvents)
      self.automatedParametersCache:set('parameters', automationEvents.parametersObj)

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

      os.execute(string.format(ZipPackCommand, '../dawproject.zip', '*'))
      os.move('./dawproject.zip', filePath)

      if (not config.devMode) then
        self:clearTempDirectory()
      end
    end,
    function() fancyStatus:show_status("Export done!") end
  )

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
        process = ProcessSlicer(
          function()
            Song:describe_batch_undo('Convert all sample instruments to Redux', 10000)
            for index = 1, #Song.instruments do
              coroutine.yield()
              fancyStatus:show_status("Converting instrument #" ..
                index .. " to Redux" .. Helpers:generateStatusAnimation())
              Song.selected_instrument_index = index
              ReduxPluginHelpers:convertCurrentInstrumentToRedux()
            end
          end,
          function() fancyStatus:show_status("Conversion done!") end
        )
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
    Notifiers:remove(Song.selected_instrument_index_observable, instrSwitchListener)
  end

  fancyStatus = FancyStatusMessage()

  Notifiers:add(Tool.app_idle_observable, toolIdle)
  Notifiers:add(Tool.app_new_document_observable, newDocumentListener)
  Notifiers:add(Tool.app_release_document_observable, releaseDocumentListener)
end

DawProject()
