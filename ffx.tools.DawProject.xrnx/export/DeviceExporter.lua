-------------------------------------------------------------------------------
-- Device Exporter, generates the plugins of a track and writes their presets.
-- Sample instruments are converted into Redux.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "DeviceExporter"

function DeviceExporter:__init(config, progress, layout, pluginInfoCache, automatedParameters)
  self.config = config
  self.progress = progress
  self.layout = layout
  self.pluginInfoCache = pluginInfoCache
  self.automatedParameters = automatedParameters
  self.instrIndexCache = Cache()
end

function DeviceExporter:generateDevicesForXML(track)
  local devicesObj = {}
  local trackIndex = SongHelpers:getTrackIndex(track)

  -- the instruments of a split track are on the tracks inside of the group
  if (not self.layout:isTrackSplit(trackIndex)) then
    local pool = self.layout.instrumentPools[trackIndex]
    local instrIndex = pool and pool.primary or self.instrIndexCache:get(trackIndex) or
        SongHelpers:getInstrumentIndexOfTrack(track)
    self.instrIndexCache:set(trackIndex, instrIndex)

    if (instrIndex) then
      self:addInstrumentDevicesForXML(devicesObj, Song:instrument(instrIndex), instrIndex, trackIndex, trackIndex)
    end
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

-- trackId is the id of the target track, which differs from the Renoise track on split tracks
function DeviceExporter:addInstrumentDevicesForXML(devicesObj, instr, instrIndex, trackIndex, trackId)
  -- vsti
  if (instr and instr.plugin_properties and instr.plugin_properties.plugin_device) then
    local deviceSavePath = 'instr-tr' .. trackIndex .. '-no' .. instrIndex ..
        '-' .. Helpers:prepareFilenameForXML(instr.name)
    local parameterIdPrefix = 'paramid-' .. trackIndex .. '-i' .. instrIndex
    --print('matching instr parameterIdPrefix', parameterIdPrefix)

    self:addDeviceObj(devicesObj, instr.plugin_properties.plugin_device, deviceSavePath, parameterIdPrefix,
      'instrument', trackId)
  end

  -- e.g. a plugin that could not be loaded, as Redux this would only be an empty instrument
  if (instr and instr.plugin_properties.plugin_device == nil and #instr.samples == 0) then
    print('warning: track ' .. trackIndex .. ' has no sound source, since the instrument has no samples ' ..
      'and no loaded plugin:', instr.name)
    return
  end

  -- native instr to redux
  if (self.config['convertToRedux'] == true and instr and instr.plugin_properties.plugin_device == nil) then
    local deviceSavePath = 'instr-tr' ..
        trackIndex .. '-no' .. instrIndex .. '-' .. Helpers:prepareFilenameForXML(instr.name) .. '-reduxed'
    -- convert Renoise instruments to Redux VST3
    ReduxPluginHelpers:generateReduxPresetDataForInstrument(instr, TempDir .. "/plugins/" .. deviceSavePath)

    devicesObj[#devicesObj + 1] = {
      Vst3Plugin = {
        _attr = {
          id = 'plugin' .. trackId .. '-' .. #devicesObj,
          deviceID = ReduxVST3Identifier,
          deviceRole = 'instrument',
          deviceName = 'Redux',
          name = Helpers:prepareFilenameForXML(instr.name),
          loaded = "true"
        },
        Enabled = {
          _attr = {
            id = 'enabled' .. trackId .. '-' .. #devicesObj,
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
end

function DeviceExporter:addDeviceObj(devicesObj, device, deviceSavePath, parameterIdPrefix, deviceRole, trackIndex)
  self.progress:setStatus('Exporting plugin ' .. device.name)

  local parameterChunkData = DeviceHelpers:getParameterChunk(device)
  local deviceId = DeviceHelpers:getActivePresetDataContent(device, 'PluginIdentifier')

  local automatedParametersObj = {
    RealParameter = self.automatedParameters[parameterIdPrefix]
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
    if (self.config['exportVST3'] == true and string.find(device.device_path, "VST3/") ~= nil) then
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
    if (self.config['exportVST2'] == true and string.find(device.device_path, "VST/") ~= nil) then
      -- FIXME active_preset_data is defective
      --print('vst2', device.short_name, device.active_preset_data)
      if (self.config['useVST2InfoTool'] == true) then
        local pluginInfo = self.pluginInfoCache:get(device.device_path)
        if (pluginInfo == nil) then
          pluginInfo = DeviceHelpers:readPluginInfo(device)
        end

        coroutine.yield()

        self.pluginInfoCache:set(device.device_path, pluginInfo)

        if (pluginInfo) then
          attr.deviceID = pluginInfo['id'] or attr.deviceID
          attr.deviceName = pluginInfo['name'] or attr.deviceName
          attr.deviceVendor = pluginInfo['vendor']
          -- The stored preset index can be out of range, e.g. if a plugin has less presets than before.
          -- The name is only metadata of the preset file, the actual state is the parameter chunk.
          local hasPresetName, presetName = pcall(function()
            return device:preset(device.active_preset)
          end)
          if (not hasPresetName) then
            presetName = ''
          end
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
    if (os.platform() == 'MACINTOSH' and self.config['exportAU'] == true and string.find(device.device_path, "AU/") ~= nil) then
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
