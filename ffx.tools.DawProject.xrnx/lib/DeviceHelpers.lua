-------------------------------------------------------------------------------
-- General Device Helpers, collection of useful additional
-- renoise.AudioDevice object functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('lib/Cache')


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

function DeviceHelpers:convertBinaryToVst2Preset(pluginInfo, data)
  local lenData = string.len(data)
  local vstPresetData = {
    'CcnK',                                               -- VST2 root chunk identifier
    Helpers:intToBinaryBE(lenData + 52, 4),               -- size of this chunk, excl. magic + byteSize, 4 bytes, +52
    'FPCh',                                               -- 'FxCk' (regular) or 'FPCh' (opaque chunk)
    Helpers:intToBinaryBE(1, 4),                          -- format version (currently 1)
    Helpers:intToBinaryBE(pluginInfo.id, 4),              -- fx unique ID
    Helpers:intToBinaryBE(pluginInfo.version, 4),         -- fx version
    Helpers:intToBinaryBE(pluginInfo.countParameters, 4), -- number of parameters
    'Default' .. Helpers:intToBinaryBE(0, 28 - 7),        -- program name (null-terminated ASCII string), 28 bytes
    Helpers:intToBinaryBE(lenData, 4),                    -- size of program data, 4 bytes
    data,                                                 -- chunk data
  }

  return table.concat(vstPresetData, '')
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

function DeviceHelpers:readPluginInfo(device)
  local pluginPath = device.device_path
  local pluginInfo = self.cache:get(pluginPath)
  local filePath = nil
  local dbPath = renoise.tool().bundle_path:match("(.*Renoise/V" .. renoise.RENOISE_VERSION .. "/)")
  local vst2ToolPath = "./bin/vst2info-tool-" .. Helpers:getShortOSString()

  if (Helpers:getShortOSString() == "win") then
    vst2ToolPath = vst2ToolPath .. ".exe"
  end


  if (pluginInfo) then
    return pluginInfo
  end

  if (not io.exists(vst2ToolPath)) then
    print("error: vst2 info tool does not exist under", vst2ToolPath)
    return nil
  end

  local _, pluginId = pluginPath:match("(.*/)(.*)")

  -- vst2
  if (string.find(pluginPath, "VST/")) then
    dbPath = dbPath .. "CachedVSTs_" .. jit.arch .. ".db"
  end

  -- vst3
  if (string.find(pluginPath, "VST3/")) then
    dbPath = dbPath .. "CachedVST3s_" .. jit.arch .. ".db"
  end

  print("opening db at", dbPath, "for", pluginId)

  local db, status, error = renoise.SQLite.open(dbPath, "ro")
  if (db == nil or error ~= nil) then
    return nil
  end

  -- Files CachedVST3s_arm64/_x64 or CachedVSTs_arm64/_x64
  -- Table "CachedPlugins", column "DocumentIdentifier"
  local sql = "SELECT LocalFilePath FROM CachedPlugins WHERE DocumentIdentifier = '" .. pluginId .. "';"
  for a in db:rows(sql) do
    for _, v in ipairs(a) do
      filePath = v
      break
    end
    break
  end

  db:close()

  if (filePath == nil) then
    return nil
  end

  print("executing", vst2ToolPath .. " '" .. filePath .. "'")
  local toolOutput = Helpers:captureConsole(vst2ToolPath .. " '" .. filePath .. "'")
  local json = require('lib/json')
  pluginInfo = json.decode(toolOutput)
  print("tool output:")
  rprint(pluginInfo)
  self.cache:set(pluginPath, pluginInfo)
  return pluginInfo
end
