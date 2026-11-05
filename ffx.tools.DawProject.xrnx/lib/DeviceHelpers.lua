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

InfoToolOutputBegin = '@@VSTINFO_BEGIN@@'
InfoToolOutputEnd = '@@VSTINFO_END@@'

function DeviceHelpers:getParameterChunk(device)
  local activePresetData = device.active_preset_data
  local startOffset, endOffset = string.find(activePresetData, "<ParameterChunk>")
  local nodeEndOffset = string.find(activePresetData, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(activePresetData, startOffset + 16 + 9, nodeEndOffset - 1 - 3)
  end
  return nil
end

function DeviceHelpers:getActivePresetDataContent(device, nodeName)
  local activePresetData = device.active_preset_data
  local startOffset, endOffset = string.find(activePresetData, "<" .. nodeName .. ">")
  local nodeEndOffset = string.find(activePresetData, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(activePresetData, startOffset + string.len(nodeName) + 2,
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
  local dbPath = renoise.tool().bundle_path:gsub("\\", "/"):match("(.*/V" .. renoise.RENOISE_VERSION .. "/)")
  local vstToolPath = nil
  local osString = Helpers:getShortOSString()

  if (pluginInfo) then
    return pluginInfo
  end

  if (dbPath == nil) then
    print('error: Renoise preferences path not found in', renoise.tool().bundle_path)
    return nil
  end

  -- the identifier itself can contain slashes, e.g. "NX 5.0/Stereo" inside of a VST2 shell
  local pluginId = pluginPath:match("VST3?/(.*)$")

  local dbPathAddon = jit.arch
  if (jit.arch == 'x86_64' or jit.arch == 'amd64') then
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

  -- A plugin can have multiple entries, e.g. one per installed version of a VST2 shell.
  -- Entries of plugins that are not installed anymore have no path.
  local sql = "SELECT LocalFilePath FROM CachedPlugins WHERE DocumentIdentifier = '" .. pluginId:gsub("'", "''") ..
      "' AND LocalFilePath <> '';"
  local result = {}
  for a in db:rows(sql) do
    for _, v in ipairs(a) do
      table.insert(result, v)
    end
  end

  db:close()

  if (result[1] == nil) then
    print('warning: no plugin file known, it seems to be not installed:', pluginId)
    return nil
  end

  filePath = result[1]
  for _, localFilePath in ipairs(result) do
    if (io.exists(localFilePath)) then
      filePath = localFilePath
      break
    end
  end

  if (osString == 'mac') then
    if (jit.arch == "arm64" and isBridged == true or (jit.arch == "x86_64" or jit.arch == "amd64") and isBridged == false) then
      vstToolPath = vstToolPath .. '-x64'
    elseif (jit.arch == "arm64" and isBridged == false) then
      vstToolPath = vstToolPath .. '-arm'
    elseif ((jit.arch == "x86_64" or jit.arch == "amd64") and isBridged == true) then
      return nil
    end
  elseif (isBridged == true) then
    -- the included tools can't load plugins of a different architecture on this os
    print('error: vst info tool can not read the bridged plugin', filePath)
    return nil
  end

  if (not io.exists('./bin/' .. vstToolPath)) then
    print("error: vst info tool does not exist under", './bin/' .. vstToolPath)
    return nil
  end

  pluginInfo = self:runInfoTool(vstToolPath, filePath)

  -- a VST2 shell contains multiple plugins, so the one of this device has to be read separately
  if (pluginInfo ~= nil and pluginInfo['shellPlugins'] ~= nil) then
    local shellPlugin = self:findShellPluginByName(pluginInfo['shellPlugins'], pluginId)
    if (shellPlugin == nil) then
      print('error: no plugin found in shell for', pluginId, filePath)
      return nil
    end
    pluginInfo = self:runInfoTool(vstToolPath, filePath, shellPlugin['id'])
  end

  if (pluginInfo == nil) then
    return nil
  end

  print("tool output:")
  if (string.find(pluginPath, "VST3/")) then
    print('parameters size', #(pluginInfo['parameters'] or {}))
  else
    for key, value in pairs(pluginInfo) do
      print('[' .. key .. '] => ', value)
    end
  end

  self.cache:set(pluginPath, pluginInfo)
  return pluginInfo
end

function DeviceHelpers:runInfoTool(vstToolPath, filePath, shellPluginId)
  local shellArgument = shellPluginId and (' ' .. shellPluginId) or ''

  -- execute within bin directory, since some plugins will generate trash file data
  -- stderr is included, because the tools report their errors there
  local toolCommand
  if (Helpers:getShortOSString() == 'win') then
    -- cmd.exe only knows double quotes, and Windows needs backslashes for loading a library
    toolCommand = 'cd bin && .\\' .. vstToolPath .. ' "' .. filePath:gsub("/", "\\") .. '"' .. shellArgument .. ' 2>&1'
  else
    toolCommand = "cd ./bin && ./" .. vstToolPath .. " '" .. filePath:gsub("'", "'\\''") .. "'" .. shellArgument .. " 2>&1"
  end

  print("executing", toolCommand)
  local toolOutput = Helpers:captureConsole(toolCommand)

  -- plugins might print to the console by themselves, so the result is enclosed by markers
  local _, beginOffset = string.find(toolOutput, InfoToolOutputBegin, 1, true)
  local endOffset = beginOffset and string.find(toolOutput, InfoToolOutputEnd, beginOffset + 1, true)

  if (endOffset == nil) then
    print('error: Tool output not found', toolOutput)
    return nil
  end

  local success, decodedInfo = pcall(json.decode, string.sub(toolOutput, beginOffset + 1, endOffset - 1))
  if (not success) then
    print('error: Tool output is invalid', decodedInfo)
    return nil
  end

  if (decodedInfo['error'] ~= nil) then
    print("error: vst info tool thrown", decodedInfo['error'])
    return nil
  end

  return decodedInfo
end

-- Renoise uses the name of the plugin inside of a shell as its identifier
function DeviceHelpers:findShellPluginByName(shellPlugins, name)
  for _, shellPlugin in ipairs(shellPlugins) do
    if (shellPlugin['name'] == name) then
      return shellPlugin
    end
  end
  return nil
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
