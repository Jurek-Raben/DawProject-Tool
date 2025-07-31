-------------------------------------------------------------------------------
-- Redux Plugin Helpers, related functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------


ReduxPluginHelpers = {}

function ReduxPluginHelpers:isReduxVST3Available()
  for _, generatorName in ipairs(Song:instrument(1).plugin_properties.available_plugins) do
    if (generatorName == 'Audio/Generators/VST3/' .. ReduxVST3Identifier) then
      return true
    end
  end
  return false
end

function ReduxPluginHelpers:generateReduxPresetDataForInstrument(instr, deviceSavePath)
  local selectedInstrIndex = SongHelpers:getInstrumentIndex(Song.selected_instrument)
  Song.selected_instrument_index = SongHelpers:getInstrumentIndex(instr)
  renoise.app():save_instrument(deviceSavePath .. ".xrni")
  Song.selected_instrument_index = selectedInstrIndex

  local data = Helpers:readFile(deviceSavePath .. ".xrni")
  -- data contains data length + data
  data = Helpers:intToBinaryLE(string.len(data), 4) .. data

  local stringPresetData = DeviceHelpers:convertBinaryToVst3Preset(ReduxVST3Identifier, data)
  Helpers:writeFile(deviceSavePath .. ".vstpreset", stringPresetData)
  return stringPresetData
end

function ReduxPluginHelpers:convertCurrentInstrumentToRedux()
  if (Song.selected_instrument.plugin_properties.plugin_device ~= nil or #Song.selected_instrument.samples == 0) then
    return
  end
  local name = Song.selected_instrument.name
  local stringPresetData = self:generateReduxPresetDataForInstrument(Song.selected_instrument,
    TempDir .. "/plugins/_temp")
  Song.selected_instrument.plugin_properties:load_plugin('Audio/Generators/VST3/' ..
    ReduxVST3Identifier)
  local activePresetData = Helpers:readFile('./templates/redux_instrument.xml')
  activePresetData = string.gsub(activePresetData, 'CHUNKDATA', Helpers:stringToBase64(stringPresetData))
  Song.selected_instrument:clear()
  Song.selected_instrument.name = name .. ' (Reduxed)'
  Song.selected_instrument.plugin_properties.plugin_device.active_preset_data =
      activePresetData
end
