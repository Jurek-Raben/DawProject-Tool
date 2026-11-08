-------------------------------------------------------------------------------
-- VST3 Migration, exports a VST2 plugin as its installed VST3 version, if the
-- VST3 version can replace the VST2 version.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--
-- Some DAWs (e.g. Cubase) don't load VST2 plugins of a .dawproject at all.
-- A VST3 plugin that can replace its VST2 version has a class id that is
-- derived from the VST2 id, and it accepts the VST2 state. The vendors derive
-- the class id in different ways, each scheme below knows one of them:
--  - Plugin compatibility: the VST3 plugin declares which VST2 plugins it
--    replaces, in its moduleinfo.json or its factory. These declarations are
--    read by the plugin migration data scan, see PluginMigrationData. The old
--    class ids are in the Steinberg scheme, the new one can be any class id.
--    The VST2 state is wrapped like in the Steinberg scheme.
--  - Steinberg scheme, also used by JUCE with JUCE_VST3_CAN_REPLACE_VST2:
--    'VST' + VST2 id + the lower case name. The name is the internal one of
--    the vendor, which can differ from the name in Renoise (e.g. 'Uhbik-A'
--    for 'Uhbik Ambience', or an old 'Diva Demo'). So the class id is found by
--    its prefix 'VST' + VST2 id, the name only decides between several hits.
--    The VST2 state is wrapped like Cubase does it when it migrates a project:
--    a 'VstW' header followed by a VST2 bank ('CcnK' / 'FBCh').
--  - MeldaProduction: 'Meldapro' + VST2 id + VST2 id. The VST2 chunk already
--    is the VST3 state (zlib compressed XML), for the component and the
--    controller.
-- A scheme is only used, if its class id is installed.
-------------------------------------------------------------------------------

local VST3_EFFECT_PATH_PREFIX = 'Audio/Effects/VST3/'
local VST3_INSTRUMENT_PATH_PREFIX = 'Audio/Generators/VST3/'
local VST3_HEADER_SIZE = 48

-- 'VST' as in the Steinberg scheme, for the component (not the controller)
local STEINBERG_CLASS_ID_PREFIX = '565354'
local STEINBERG_CLASS_ID_NAME_LENGTH = 9

-- The header Cubase adds to the VST2 state of migrated plugins
local USE_VSTW_HEADER = true
local VSTW_HEADER_SIZE = 8
local VSTW_VERSION = 1

local MELDA_CLASS_ID_PREFIX = 'Meldapro'

Vst3Migration = {}

-- Returns the class id a VST3 plugin has in the Steinberg scheme, if it is compatible with the VST2 plugin
function Vst3Migration:createSteinbergClassId(vst2Id, pluginName)
  local parts = { STEINBERG_CLASS_ID_PREFIX, string.format('%08X', vst2Id) }
  local name = string.lower(pluginName)
  for i = 1, STEINBERG_CLASS_ID_NAME_LENGTH do
    local byte = string.byte(name, i) or 0
    table.insert(parts, string.format('%02X', byte))
  end
  return table.concat(parts)
end

function Vst3Migration:createMeldaClassId(vst2Id)
  local vst2IdChars = Helpers:intToBinaryBE(vst2Id, 4)
  return Helpers:stringToHex(MELDA_CLASS_ID_PREFIX .. vst2IdChars .. vst2IdChars)
end

-- The state of the component and the controller, from the VST2 state
local function createSteinbergState(pluginInfo, chunkData)
  local state = DeviceHelpers:convertBinaryToVst2Bank(pluginInfo, chunkData)
  if (USE_VSTW_HEADER) then
    state = 'VstW' .. Helpers:intToBinaryBE(VSTW_HEADER_SIZE, 4) .. Helpers:intToBinaryBE(VSTW_VERSION, 4) ..
        Helpers:intToBinaryBE(0, 4) -- not bypassed
        .. state
  end
  return state, ''
end

local function createMeldaState(_, chunkData)
  return chunkData, chunkData
end

-- All installed class ids of the Steinberg scheme for a VST2 id, independent of the name
local function findSteinbergClassIds(vst2Id, installedClassIds)
  local prefix = STEINBERG_CLASS_ID_PREFIX .. string.format('%08X', vst2Id)
  local classIds = {}
  for classId in pairs(installedClassIds) do
    if (string.sub(classId, 1, #prefix) == prefix) then
      table.insert(classIds, classId)
    end
  end
  table.sort(classIds)
  return classIds
end

local function findSteinbergClassId(vst2Id, pluginNames, installedClassIds)
  local classIds = findSteinbergClassIds(vst2Id, installedClassIds)
  if (#classIds <= 1) then
    return classIds[1]
  end

  -- e.g. a demo and a full version, the name has to match
  for _, pluginName in ipairs(pluginNames) do
    if (type(pluginName) == 'string' and pluginName ~= '') then
      local classId = Vst3Migration:createSteinbergClassId(vst2Id, pluginName)
      for _, installedClassId in ipairs(classIds) do
        if (installedClassId == classId) then
          return classId
        end
      end
    end
  end
  print('warning: VST2 plugin ' .. tostring(pluginNames[1]) .. ' stays VST2, since several VST3 versions match: ' ..
    table.concat(classIds, ', '))
  return nil
end

-- The replaced VST2 plugin is named by its class id in the Steinberg scheme
local function findMeldaClassId(vst2Id, pluginNames, installedClassIds)
  local classId = Vst3Migration:createMeldaClassId(vst2Id)
  if (not installedClassIds[classId]) then
    return nil
  end
  return classId, Vst3Migration:createSteinbergClassId(vst2Id, tostring(pluginNames[1] or ''))
end

-- The declared compatibilities of the plugin migration data, by the prefix 'VST' + VST2 id of the old
-- class id. Each one is { newClassId, oldClassId }.
function Vst3Migration:getCompatibilityIndex()
  if (self.compatibilityIndex ~= nil) then
    return self.compatibilityIndex
  end

  local index = {}
  local data = PluginMigrationData:load()
  for _, entry in ipairs(data and data.plugins or {}) do
    for _, compatibility in ipairs(entry.error == nil and entry.compatibility or {}) do
      for _, oldClassId in ipairs(compatibility.old or {}) do
        -- other old class ids are VST3 ones, or the ones of a controller ('VSE')
        local prefix = string.sub(oldClassId, 1, #STEINBERG_CLASS_ID_PREFIX + 8)
        if (string.sub(oldClassId, 1, #STEINBERG_CLASS_ID_PREFIX) == STEINBERG_CLASS_ID_PREFIX and
              type(compatibility.new) == 'string') then
          index[prefix] = index[prefix] or {}
          table.insert(index[prefix], { newClassId = compatibility.new, oldClassId = oldClassId })
        end
      end
    end
  end

  self.compatibilityIndex = index
  return index
end

local function findDeclaredClassId(vst2Id, pluginNames, installedClassIds)
  local prefix = STEINBERG_CLASS_ID_PREFIX .. string.format('%08X', vst2Id)
  local candidates = {}
  local candidateCount = 0
  for _, compatibility in ipairs(Vst3Migration:getCompatibilityIndex()[prefix] or {}) do
    if (installedClassIds[compatibility.newClassId]) then
      if (candidates[compatibility.newClassId] == nil) then
        candidateCount = candidateCount + 1
      end
      candidates[compatibility.newClassId] = candidates[compatibility.newClassId] or {}
      table.insert(candidates[compatibility.newClassId], compatibility.oldClassId)
    end
  end

  local classIds = {}
  for classId in pairs(candidates) do
    table.insert(classIds, classId)
  end
  table.sort(classIds)
  if (candidateCount <= 1) then
    return classIds[1], classIds[1] and candidates[classIds[1]][1]
  end

  -- e.g. a VST3 shell with several versions, the old class id contains the name of the VST2 plugin
  for _, pluginName in ipairs(pluginNames) do
    if (type(pluginName) == 'string' and pluginName ~= '') then
      local oldClassId = Vst3Migration:createSteinbergClassId(vst2Id, pluginName)
      for _, classId in ipairs(classIds) do
        for _, candidateOldClassId in ipairs(candidates[classId]) do
          if (candidateOldClassId == oldClassId) then
            return classId, oldClassId
          end
        end
      end
    end
  end
  print('warning: VST2 plugin ' .. tostring(pluginNames[1]) .. ' stays VST2, since several VST3 plugins replace it: ' ..
    table.concat(classIds, ', '))
  return nil
end

-- Each scheme finds the installed class id of a VST2 plugin, and creates the VST3 state
local SCHEMES = {
  {
    name = 'plugin compatibility',
    findClassId = findDeclaredClassId,
    createState = createSteinbergState,
  },
  {
    name = 'Steinberg',
    findClassId = findSteinbergClassId,
    createState = createSteinbergState,
  },
  {
    name = 'MeldaProduction',
    findClassId = findMeldaClassId,
    createState = createMeldaState,
  },
}

-- Plugins can be installed and the migration data can be refreshed between two exports
function Vst3Migration:resetCaches()
  self.installedClassIds = nil
  self.compatibilityIndex = nil
end

-- The installed VST3 plugins, as set of upper case class ids
function Vst3Migration:getInstalledClassIds(deviceRole)
  self.installedClassIds = self.installedClassIds or {}
  if (self.installedClassIds[deviceRole] ~= nil) then
    return self.installedClassIds[deviceRole]
  end

  local classIds = {}
  local prefix, paths
  if (deviceRole == 'instrument') then
    prefix = VST3_INSTRUMENT_PATH_PREFIX
    paths = Song:instrument(1).plugin_properties.available_plugins
  else
    prefix = VST3_EFFECT_PATH_PREFIX
    paths = {}
    for _, deviceInfo in ipairs(Song:track(1).available_device_infos) do
      table.insert(paths, deviceInfo.path)
    end
  end
  for _, path in ipairs(paths) do
    if (string.sub(path, 1, #prefix) == prefix) then
      classIds[string.upper(string.sub(path, #prefix + 1))] = true
    end
  end

  self.installedClassIds[deviceRole] = classIds
  return classIds
end

-- Returns the installed compatible VST3 plugin as { classId, replacedClassId, scheme }, or nil.
-- The replaced class id names the VST2 plugin for the VST3 plugin, in the Steinberg scheme it is the same.
-- The names only decide, if several VST3 plugins match the VST2 id.
function Vst3Migration:findInstalledTarget(vst2Id, pluginNames, deviceRole)
  if (type(vst2Id) ~= 'number') then
    return nil
  end
  local installedClassIds = self:getInstalledClassIds(deviceRole)
  for _, scheme in ipairs(SCHEMES) do
    local classId, replacedClassId = scheme.findClassId(vst2Id, pluginNames, installedClassIds)
    if (classId ~= nil) then
      return { classId = classId, replacedClassId = replacedClassId or classId, scheme = scheme }
    end
  end
  return nil
end

-- Runs the VST3 helper tool, returns its result or nil and the reason
local function runVst3Tool(argumentsString)
  local toolName, unavailableReason = DeviceHelpers:getInfoToolName('vst3', false)
  if (toolName == nil or not io.exists('./bin/' .. toolName)) then
    return nil, 'the vst info tool ' .. (unavailableReason or 'does not exist')
  end
  local result, problem = DeviceHelpers:decodeInfoToolOutput(DeviceHelpers:executeInfoTool(toolName, argumentsString))
  if (result == nil) then
    return nil, problem
  end
  if (result.error ~= nil) then
    return nil, tostring(result.error)
  end
  return result
end

-- The VST3 plugin itself tells the ids, through IRemapParamID. Returns nil, if it doesn't.
local function remapByPlugin(filePath, target, oldParameters)
  local arguments = { '--remap-parameters', DeviceHelpers:quotePathForConsole(filePath), target.classId,
    target.replacedClassId }
  for _, parameter in ipairs(oldParameters) do
    table.insert(arguments, string.format('%d', parameter.id))
  end
  local result = runVst3Tool(table.concat(arguments, ' '))
  if (result == nil or result.supported ~= true) then
    return nil
  end

  local newParameterIds = {}
  for _, parameter in ipairs(result.parameters or {}) do
    newParameterIds[parameter.old] = parameter.new
  end
  return newParameterIds
end

local function normalizeParameterName(name)
  return (string.lower(tostring(name or '')):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

-- VST2 names are often shortened, so the beginning of the longer name is enough
local MIN_SHORTENED_NAME_LENGTH = 4

local function areSimilarNames(vst2Name, vst3Name)
  if (vst2Name == '' or vst3Name == '') then
    return false
  end
  if (vst2Name == vst3Name) then
    return true
  end
  local shortName, longName = vst2Name, vst3Name
  if (#shortName > #longName) then
    shortName, longName = longName, shortName
  end
  return #shortName >= MIN_SHORTENED_NAME_LENGTH and string.sub(longName, 1, #shortName) == shortName
end

-- Many VST3 versions use the VST2 index as parameter id, and keep the names of the parameters:
--  1. the parameter with the old index as id is used, if its name is similar
--  2. otherwise the only parameter with the same name is used
local function remapByNames(filePath, target, oldParameters, newParameterIds)
  local plugin, problem = runVst3Tool(DeviceHelpers:quotePathForConsole(filePath) .. ' --class-id ' .. target.classId)
  if (plugin == nil) then
    return problem
  end

  local namesById = {}
  local idsByName = {}
  for _, parameter in ipairs(plugin.parameters or {}) do
    local name = normalizeParameterName(parameter.title)
    namesById[parameter.id] = name
    -- a name of several parameters can't be assigned
    idsByName[name] = (idsByName[name] == nil) and parameter.id or false
  end

  for _, oldParameter in ipairs(oldParameters) do
    if (newParameterIds[oldParameter.id] == nil) then
      local oldName = normalizeParameterName(oldParameter.name)
      if (namesById[oldParameter.id] ~= nil and areSimilarNames(oldName, namesById[oldParameter.id])) then
        newParameterIds[oldParameter.id] = oldParameter.id
      elseif (idsByName[oldName]) then
        newParameterIds[oldParameter.id] = idsByName[oldName]
      end
    end
  end
  return nil
end

-- Finds the parameter ids of the VST3 plugin, which replace the parameter indices of the VST2 plugin.
-- oldParameters is a list of { id, name }. Returns a table of the new ids by the old indices, the
-- method, or nil and the reason.
function Vst3Migration:remapParameters(target, deviceRole, oldParameters)
  local pathPrefix = (deviceRole == 'instrument') and VST3_INSTRUMENT_PATH_PREFIX or VST3_EFFECT_PATH_PREFIX
  local filePath = DeviceHelpers:findPluginFilePath(pathPrefix .. target.classId)
  if (filePath == nil) then
    return nil, 'the file of the VST3 version is unknown'
  end

  local newParameterIds = remapByPlugin(filePath, target, oldParameters)
  local method = 'told by the plugin'
  if (newParameterIds == nil) then
    newParameterIds = {}
    method = 'by index and name'
  end

  -- the plugin might not know all the parameters
  local unmappedCount = 0
  for _, oldParameter in ipairs(oldParameters) do
    if (newParameterIds[oldParameter.id] == nil) then
      unmappedCount = unmappedCount + 1
    end
  end
  if (unmappedCount > 0) then
    local problem = remapByNames(filePath, target, oldParameters, newParameterIds)
    if (problem ~= nil and next(newParameterIds) == nil) then
      return nil, problem
    end
  end
  return newParameterIds, method
end

local function isVst2DevicePath(devicePath)
  return string.find(devicePath, '/VST/', 1, true) ~= nil
end

-- The VST2 plugins of the song, as track effects and as plugin instruments
function Vst3Migration:countVst2PluginsInSong()
  local count = 0
  for _, track in ipairs(Song.tracks) do
    for _, device in ipairs(track.devices) do
      if (isVst2DevicePath(device.device_path)) then
        count = count + 1
      end
    end
  end
  for _, instrument in ipairs(Song.instruments) do
    local device = instrument.plugin_properties.plugin_device
    if (device ~= nil and isVst2DevicePath(device.device_path)) then
      count = count + 1
    end
  end
  return count
end

-- Creates the .vstpreset data for the VST3 plugin, with the state of the VST2 plugin
function Vst3Migration:createPresetData(target, pluginInfo, chunkData)
  local componentState, controllerState = target.scheme.createState(pluginInfo, chunkData)
  local componentSize = string.len(componentState)
  local controllerSize = string.len(controllerState)
  local controllerOffset = VST3_HEADER_SIZE + componentSize
  local listOffset = controllerOffset + controllerSize

  return table.concat({
    'VST3',
    Helpers:intToBinaryLE(1, 4),
    target.classId,
    Helpers:intToBinaryLE(listOffset, 8),
    componentState,
    controllerState,
    'List',
    Helpers:intToBinaryLE(2, 4),
    'Comp', Helpers:intToBinaryLE(VST3_HEADER_SIZE, 8), Helpers:intToBinaryLE(componentSize, 8),
    'Cont', Helpers:intToBinaryLE(controllerOffset, 8), Helpers:intToBinaryLE(controllerSize, 8),
  })
end
