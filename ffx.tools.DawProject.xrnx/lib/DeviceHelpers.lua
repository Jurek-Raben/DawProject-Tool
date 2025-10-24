-------------------------------------------------------------------------------
-- General Device Helpers, collection of useful additional
-- renoise.AudioDevice object functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('lib/Cache')
local json = require('lib/json')


DeviceHelpers = {}

DeviceHelpers.cache = Cache()

function DeviceHelpers:getParameterChunk(device)
  local startOffset, endOffset = string.find(device.active_preset_data, "<ParameterChunk>")
  local nodeEndOffset = string.find(device.active_preset_data, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(device.active_preset_data, startOffset + 16 + 9, nodeEndOffset - 1 - 3)
  end
  return nil
end

function DeviceHelpers:getActivePresetDataContent(device, nodeName)
  local startOffset, endOffset = string.find(device.active_preset_data, "<" .. nodeName .. ">")
  local nodeEndOffset = string.find(device.active_preset_data, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(device.active_preset_data, startOffset + string.len(nodeName) + 2,
      nodeEndOffset - 1)
  end
  return nil
end

function DeviceHelpers:convertBinaryToVst2Preset(pluginInfo, presetName, data)
  local lenData = string.len(data)
  presetName = string.sub(presetName, 1, 27)
  return table.concat({
    'CcnK',                                                              -- VST2 root chunk identifier
    Helpers:intToBinaryBE(lenData + 52, 4),                              -- size of this chunk, excl. magic + byteSize, 4 bytes, +52
    'FPCh',                                                              -- 'FxCk' (regular) or 'FPCh' (opaque chunk)
    Helpers:intToBinaryBE(1, 4),                                         -- format version (currently 1)
    Helpers:intToBinaryBE(pluginInfo.id, 4),                             -- fx unique ID
    Helpers:intToBinaryBE(pluginInfo.version, 4),                        -- fx version
    Helpers:intToBinaryBE(pluginInfo.countParameters, 4),                -- number of parameters
    presetName .. Helpers:intToBinaryBE(0, 28 - string.len(presetName)), -- program name (null-terminated ASCII string), 28 bytes
    Helpers:intToBinaryBE(lenData, 4),                                   -- size of program data, 4 bytes
    data,                                                                -- chunk data
  }, '')
end

function DeviceHelpers:convertBinaryToVst3Preset(pluginId, data)
  local lenData = string.len(data)
  return table.concat({
    'VST3',                                             -- VST3 header
    Helpers:intToBinaryLE(1, 4),                        -- version 1, little endian, 4 bytes
    pluginId,                                           -- Plugin ID, 32 bytes length
    Helpers:intToBinaryLE(lenData + 4 + 4 + 32 + 8, 8), -- Offset to list chunk, 8 bytes length, little endian
    data,                                               -- chunk data
    'List',                                             -- List chunk start
    Helpers:intToBinaryLE(2, 4),                        -- entry count, little endian, 4 bytes
    'Comp',                                             -- actual preset chunk id
    Helpers:intToBinaryLE(4 + 4 + 32 + 8, 8),           -- Offset to chunk data, 8 bytes length, little endian
    Helpers:intToBinaryLE(lenData, 8),                  -- chunk data length, 8 bytes length, little endian
    'Cont',                                             -- fake end chunk id
    Helpers:intToBinaryLE(lenData + 4 + 4 + 32 + 8, 8), -- Offset to chunk data, 8 bytes length, little endian
    Helpers:intToBinaryLE(0, 8)                         -- chunk data length, 8 bytes length, little endian
  }, '')
end

function DeviceHelpers:convertAUDeviceIDToWeirdS1Format(deviceID)
  return Helpers:stringToHex(table.concat({
    string.sub(deviceID, 1, 4),                                                                   -- "aufx" stays unchanged
    string.sub(deviceID, 8, 9) .. string.sub(deviceID, 6, 7),                                     -- "MyId" turns into "IdMy" 🥳
    string.sub(deviceID, 14, 14) ..
    string.sub(deviceID, 13, 13) .. string.sub(deviceID, 12, 12) .. string.sub(deviceID, 11, 11), -- "MyId" now is reversed into "dIyM" 😵‍💫
    "BALK"                                                                                        -- this also is added for unknown reasons
  }, ''))
end

function DeviceHelpers:extractAUDeviceParameterIDs(deviceID)
  local auValOutput = Helpers:captureConsole('auval -v  ' .. deviceID:gsub(":", " "))

  local pluginInfo = {
    parameters = {}
  }
  local startOffset = 0
  local endOffset = 0
  local _endOffset = 0
  local _endOffset2 = 0
  local index = 0

  while (startOffset ~= nil and endOffset ~= nil) do
    startOffset, _endOffset = string.find(auValOutput, "Parameter ID:", startOffset)
    endOffset, _endOffset2 = string.find(auValOutput, " ", _endOffset)
    if (startOffset ~= nil and _endOffset2 ~= nil) then
      table.insert(pluginInfo.parameters,
        { id = tonumber(string.sub(auValOutput, startOffset + 13, endOffset - 1)), index = index }
      )
      startOffset = _endOffset2
      index = index + 1
    end
  end

  return pluginInfo
end

function DeviceHelpers:isPluginBridged(device)
  local pluginInfos = Song:instrument(1).plugin_properties.available_plugin_infos

  pcall(function()
    if device.display_name then -- is a dsp
      pluginInfos = Song:track(1).available_device_infos
    end
  end)

  for i = 1, #pluginInfos do
    if (pluginInfos[i].path == device.device_path) then
      return pluginInfos[i].is_bridged
    end
  end

  print('error: no plugin info found for', device.device_path)
  return false
end

function DeviceHelpers:readPluginInfo(device)
  local pluginPath = device.device_path
  local pluginInfo = self.cache:get(pluginPath)
  local filePath = nil
  local isBridged = DeviceHelpers:isPluginBridged(device)
  local dbPath = renoise.tool().bundle_path:match("(.*Renoise/V" .. renoise.RENOISE_VERSION .. "/)")
  local vstToolPath = nil
  local osString = Helpers:getShortOSString()

  if (pluginInfo) then
    return pluginInfo
  end

  local _, pluginId = pluginPath:match("(.*/)(.*)")

  local dbPathAddon = jit.arch
  if (jit.arch == 'x86_64' or jit.arch == 'amd64' or isBridged) then
    dbPathAddon = 'x64'
  end

  if (string.find(pluginPath, "VST/")) then -- vst2
    dbPath = dbPath .. "CachedVSTs_" .. dbPathAddon .. ".db"
    vstToolPath = "vst2info-tool-" .. osString
  elseif (string.find(pluginPath, "VST3/")) then -- vst3
    dbPath = dbPath .. "CachedVST3s_" .. dbPathAddon .. ".db"
    vstToolPath = "vst3info-tool-" .. osString
  else
    return nil
  end

  if (Helpers:getShortOSString() == "win") then
    vstToolPath = vstToolPath .. ".exe"
  end

  print("opening db at", dbPath, "for", pluginId)

  local db, status, error = renoise.SQLite.open(dbPath, "ro")
  if (db == nil) then
    print('error: Error while opening db', dbPath)
    return nil
  end
  if (error ~= nil) then
    print('error: Error while opening db', dbPath)
    db:close()
    return nil
  end

  local sql = "SELECT LocalFilePath FROM CachedPlugins WHERE DocumentIdentifier = '" .. pluginId .. "';"
  local result = {}
  for a in db:rows(sql) do
    for _, v in ipairs(a) do
      table.insert(result, v)
    end
  end

  db:close()

  if (result[1] == nil) then
    return nil
  end

  filePath = result[1]

  if (osString == 'mac') then
    if (jit.arch == "arm64" and isBridged == true or (jit.arch == "x86_64" or jit.arch == "amd64") and isBridged == false) then
      vstToolPath = vstToolPath .. '-x64'
    elseif (jit.arch == "arm64" and isBridged == false) then
      vstToolPath = vstToolPath .. '-arm'
    elseif ((jit.arch == "x86_64" or jit.arch == "amd64") and isBridged == true) then
      return nil
    end
  end

  if (not io.exists('./bin/' .. vstToolPath)) then
    print("error: vst info tool does not exist under", './bin/' .. vstToolPath)
    return nil
  end

  print("executing", vstToolPath .. " '" .. filePath .. "'")
  -- execute within bin directory, since some plugins will generate trash file data
  vstToolPath = "cd ./bin;./" .. vstToolPath
  local toolOutput = Helpers:captureConsole(vstToolPath .. " '" .. filePath .. "'")

  -- plugins might output to the console by themselves
  local startOffset = string.find(toolOutput, "{\"")
  local endOffset = string.find(toolOutput, "\"}")

  if (startOffset == nil or endOffset == nil) then
    print('error: Tool output offsets not found', toolOutput)
    return nil
  end
  toolOutput = string.sub(toolOutput, startOffset, endOffset + 2)

  pcall(function()
    pluginInfo = json.decode(toolOutput)
    if (pluginInfo['error'] ~= nil) then
      print("error: vst info tool thrown", pluginInfo['error'])
      return nil
    end

    print("tool output:")
    if (string.find(pluginPath, "VST3/")) then
      print('parameters size', #pluginInfo['parameters'])
    else
      rprint(pluginInfo)
    end

    self.cache:set(pluginPath, pluginInfo)
  end)
  return pluginInfo
end

function DeviceHelpers:findPluginInfoParameterObjectByIndex(pluginInfo, searchIndex)
  for i = 1, #pluginInfo['parameters'] do
    local paramObj = pluginInfo['parameters'][i]
    if (paramObj['index'] == searchIndex) then
      return paramObj
    end
  end
  return nil
end

function DeviceHelpers:convertPListPresetToXML(presetPath)
  return Helpers:captureConsole('plutil -convert xml1 -s ' .. presetPath)
end
