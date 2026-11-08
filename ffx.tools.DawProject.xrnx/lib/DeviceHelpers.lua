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

-- The parameter chunk of Renoise is the whole state of the plugin, so it is stored as bank (.fxb).
-- As program (.fxp), hosts like Studio set it as program chunk, which some plugins reject.
function DeviceHelpers:convertBinaryToVst2Bank(pluginInfo, data)
  local bankContent = table.concat({
    'FBCh',                                          -- 'FxBk' (regular) or 'FBCh' (opaque chunk)
    Helpers:intToBinaryBE(2, 4),                     -- format version, 2 has the current program
    Helpers:intToBinaryBE(pluginInfo.id, 4),         -- fx unique ID
    Helpers:intToBinaryBE(pluginInfo.version or 0, 4), -- fx version
    Helpers:intToBinaryBE(1, 4),                     -- number of programs
    Helpers:intToBinaryBE(0, 4),                     -- current program
    string.rep(string.char(0), 124),                 -- reserved, 124 bytes
    Helpers:intToBinaryBE(string.len(data), 4),      -- size of bank data, 4 bytes
    data,                                            -- chunk data
  })
  return 'CcnK' .. Helpers:intToBinaryBE(string.len(bankContent), 4) .. bankContent -- size excl. magic + byteSize
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

function DeviceHelpers:isIntelArchitecture()
  return jit.arch == 'x64' or jit.arch == 'x86_64' or jit.arch == 'amd64'
end

-- Returns 'vst2', 'vst3', or nil for all other kinds of devices
function DeviceHelpers:getPluginFormat(pluginPath)
  if (string.find(pluginPath, "VST/")) then
    return 'vst2'
  elseif (string.find(pluginPath, "VST3/")) then
    return 'vst3'
  end
  return nil
end

-- The preferences directory of the running Renoise version, which contains the tools and plugin databases
function DeviceHelpers:getPreferencesPath()
  return renoise.tool().bundle_path:gsub("\\", "/"):match("(.*/V" .. renoise.RENOISE_VERSION .. "/)")
end

-- The database of the plugins, or with isFailed of the plugins Renoise couldn't load
function DeviceHelpers:getPluginDatabasePath(pluginFormat, isFailed)
  local preferencesPath = self:getPreferencesPath()
  if (preferencesPath == nil) then
    return nil
  end

  local architecture = self:isIntelArchitecture() and 'x64' or jit.arch
  local databaseName = (pluginFormat == 'vst2') and 'VSTs_' or 'VST3s_'
  local prefix = isFailed and 'CachedFailed' or 'Cached'
  return preferencesPath .. prefix .. databaseName .. architecture .. ".db"
end

-- Returns the name of the tool binary for reading a plugin, or nil and the reason if there is none
function DeviceHelpers:getInfoToolName(pluginFormat, isBridged)
  local toolName = pluginFormat .. "info-tool-" .. Helpers:getShortOSString()

  if (Helpers:getShortOSString() == 'win') then
    toolName = toolName .. ".exe"
  end

  if (Helpers:getShortOSString() == 'mac') then
    if (self:isIntelArchitecture()) then
      if (isBridged) then
        return nil, 'can not read bridged plugins on an Intel Mac'
      end
      return toolName .. '-x64'
    end
    -- bridged plugins run as Intel code, so these are read by the Intel binary through Rosetta
    return toolName .. (isBridged and '-x64' or '-arm')
  end

  if (isBridged) then
    -- the included tools can't load plugins of a different architecture on this os
    return nil, 'can not read bridged plugins on this operating system'
  end
  return toolName
end

-- Returns the file Renoise knows for a plugin that exists, or nil if it seems to be not installed
function DeviceHelpers:findPluginFilePath(pluginPath)
  local filePaths = self:findPluginFilePaths(pluginPath)
  return filePaths and filePaths[1]
end

-- Returns all the files Renoise knows for a plugin, the ones that exist first
function DeviceHelpers:findPluginFilePaths(pluginPath)
  local pluginFormat = self:getPluginFormat(pluginPath)
  if (pluginFormat == nil) then
    return nil
  end

  local dbPath = self:getPluginDatabasePath(pluginFormat)
  if (dbPath == nil) then
    print('error: Renoise preferences path not found in', renoise.tool().bundle_path)
    return nil
  end

  -- the identifier itself can contain slashes, e.g. "NX 5.0/Stereo" inside of a VST2 shell
  local pluginId = pluginPath:match("VST3?/(.*)$")

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

  local existingFilePaths = {}
  local missingFilePaths = {}
  for _, localFilePath in ipairs(result) do
    table.insert(io.exists(localFilePath) and existingFilePaths or missingFilePaths, localFilePath)
  end
  for _, localFilePath in ipairs(missingFilePaths) do
    table.insert(existingFilePaths, localFilePath)
  end
  return existingFilePaths
end

-- A VST2 shell contains multiple plugins, so the one of this device has to be read separately.
-- Returns nil if the file is a shell not containing the plugin.
function DeviceHelpers:readPluginInfoFromFile(vstToolPath, filePath, pluginId)
  local pluginInfo = self:runInfoTool(vstToolPath, filePath)

  if (pluginInfo == nil or pluginInfo['shellPlugins'] == nil) then
    return pluginInfo
  end

  local shellPlugin = self:findShellPluginByName(pluginInfo['shellPlugins'], pluginId)
  if (shellPlugin == nil) then
    return nil
  end
  return self:runInfoTool(vstToolPath, filePath, shellPlugin['id'])
end

function DeviceHelpers:readPluginInfo(device)
  local pluginPath = device.device_path
  local pluginInfo = self.cache:get(pluginPath)

  if (pluginInfo) then
    return pluginInfo
  end

  local pluginFormat = self:getPluginFormat(pluginPath)
  if (pluginFormat == nil) then
    return nil
  end

  local pluginId = pluginPath:match("VST3?/(.*)$")
  local filePaths = self:findPluginFilePaths(pluginPath)
  if (filePaths == nil) then
    return nil
  end

  local vstToolPath, unavailableReason = self:getInfoToolName(pluginFormat, self:isPluginBridged(device))
  if (vstToolPath == nil) then
    print('error: vst info tool ' .. unavailableReason .. ':', filePaths[1])
    return nil
  end

  if (not io.exists('./bin/' .. vstToolPath)) then
    print("error: vst info tool does not exist under", './bin/' .. vstToolPath)
    return nil
  end

  -- A plugin can be listed with multiple files, e.g. the installed versions of a VST2 shell,
  -- and each version of the shell only contains some of the plugins or even none at all.
  for _, filePath in ipairs(filePaths) do
    pluginInfo = self:readPluginInfoFromFile(vstToolPath, filePath, pluginId)
    if (pluginInfo ~= nil) then
      break
    end
  end

  if (pluginInfo == nil) then
    print('error: no plugin file could provide the infos for', pluginId, table.concat(filePaths, ', '))
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

function DeviceHelpers:quotePathForConsole(path)
  if (Helpers:getShortOSString() == 'win') then
    -- cmd.exe only knows double quotes, and Windows needs backslashes for loading a library
    return '"' .. path:gsub("/", "\\") .. '"'
  end
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

-- Executes within bin directory, since some plugins will generate trash file data.
-- stderr is included, because the tools report their errors there.
function DeviceHelpers:executeInfoTool(vstToolPath, argumentsString)
  local toolCommand
  if (Helpers:getShortOSString() == 'win') then
    toolCommand = 'cd bin && .\\' .. vstToolPath .. ' ' .. argumentsString .. ' 2>&1'
  else
    toolCommand = "cd ./bin && ./" .. vstToolPath .. " " .. argumentsString .. " 2>&1"
  end

  print("executing", toolCommand)
  return Helpers:captureConsole(toolCommand)
end

-- Plugins might print to the console by themselves, so the result is enclosed by markers.
-- Returns the decoded result, or nil and a description of the problem.
function DeviceHelpers:decodeInfoToolOutput(toolOutput)
  local _, beginOffset = string.find(toolOutput, InfoToolOutputBegin, 1, true)
  local endOffset = beginOffset and string.find(toolOutput, InfoToolOutputEnd, beginOffset + 1, true)

  if (endOffset == nil) then
    return nil, 'Tool output not found'
  end

  local success, decodedInfo = pcall(json.decode, string.sub(toolOutput, beginOffset + 1, endOffset - 1))
  if (not success) then
    return nil, 'Tool output is invalid'
  end

  return decodedInfo
end

-- Returns the report of the tool, or nil, a description of the problem and the console output
function DeviceHelpers:runInfoToolHealthcheck(vstToolPath, filePaths)
  local arguments = { '--healthcheck' }
  for _, filePath in ipairs(filePaths) do
    table.insert(arguments, (self:quotePathForConsole(filePath)))
  end

  local toolOutput = self:executeInfoTool(vstToolPath, table.concat(arguments, ' '))
  local report, problem = self:decodeInfoToolOutput(toolOutput)
  return report, problem, toolOutput
end

function DeviceHelpers:runInfoTool(vstToolPath, filePath, shellPluginId)
  local shellArgument = shellPluginId and (' ' .. shellPluginId) or ''
  local toolOutput = self:executeInfoTool(vstToolPath, self:quotePathForConsole(filePath) .. shellArgument)

  local decodedInfo, problem = self:decodeInfoToolOutput(toolOutput)
  if (decodedInfo == nil) then
    print('error: ' .. problem, toolOutput)
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
