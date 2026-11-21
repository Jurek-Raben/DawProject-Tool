-- @build:skip-start
_AUTO_RELOAD_DEBUG = function()
end
-- @build:skip-end
--------------------------------------------------------------------------------
-- Plugin Migrator
-- by Jurek Raben
-- v@build:version@ (inserted from manifest.xml by the GitHub build)
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--
-- Replaces a VST2 plugin by its installed VST3 version, with the state of the
-- VST2 plugin and its automation, see Vst3Migration.
--------------------------------------------------------------------------------

require('lib/shared/GeneralHelpers')
require('lib/shared/ProgressDialog')
require('lib/shared/ProcessSlicer')
require('lib/shared/BackgroundTask')
require('lib/shared/Cache')
require('lib/shared/DeviceHelpers')
require('lib/shared/PluginMigrationData')
require('lib/shared/Vst3Migration')
require('lib/shared/MigratablePlugins')
require('lib/shared/MigratablePluginsDialog')


--------------------------------------------------------------------------------
-- Global helpers
--------------------------------------------------------------------------------

Song = renoise.song() -- needs a refresh later
Tool = renoise.tool()
local progressDialog = nil
local backgroundTask = nil
local migratablePluginsDialog = nil


--------------------------------------------------------------------------------

class "PluginMigrator"

local MENU_NAME = 'Migrate to VST3...'
local EFFECT_MENU_ENTRIES = { 'DSP Device:' .. MENU_NAME, 'Mixer:' .. MENU_NAME }
local INSTRUMENT_MENU_ENTRY = 'Instrument Box:' .. MENU_NAME

local function isVst2Device(device)
  return device ~= nil and string.find(device.device_path, '/VST/', 1, true) ~= nil
end

local function getSelectedEffect()
  return Song.selected_device
end

local function getSelectedInstrumentPlugin()
  local instrument = Song.selected_instrument
  return instrument and instrument.plugin_properties.plugin_device
end


-- The plugin state in the preset data of Renoise, base64 encoded
local PARAMETER_CHUNK_START = '<ParameterChunk><![CDATA['
local PARAMETER_CHUNK_END = ']]></ParameterChunk>'

-- Sets the plugin state of a device, returns false if its preset data has no place for it
local function setParameterChunk(device, base64Chunk)
  local presetData = device.active_preset_data
  local _, startEnd = string.find(presetData, PARAMETER_CHUNK_START, 1, true)
  if (startEnd == nil) then
    return false
  end
  local endStart = string.find(presetData, PARAMETER_CHUNK_END, startEnd + 1, true)
  if (endStart == nil) then
    return false
  end
  device.active_preset_data = string.sub(presetData, 1, startEnd) .. base64Chunk .. string.sub(presetData, endStart)
  return true
end

-- The automated parameters of the VST2 device as list of { id, name, parameter }. The id is the VST2 index.
local function findAutomatedParameters(device)
  local parameters = {}
  for index, parameter in ipairs(device.parameters) do
    if (parameter.is_automated) then
      table.insert(parameters, { id = index - 1, name = parameter.name, parameter = parameter })
    end
  end
  return parameters
end

-- Renoise lists the parameters of a VST3 plugin in the order of their index, like the VST3 tool.
-- Returns the parameter index of Renoise (1-based) by the VST3 parameter id.
local function createRenoiseIndicesByVst3Id(vst3Parameters)
  local indices = {}
  for position, parameter in ipairs(vst3Parameters) do
    indices[parameter.id] = (tonumber(parameter.index) or (position - 1)) + 1
  end
  return indices
end

-- Moves the automation of the VST2 parameters to the VST3 ones, in all patterns of the track.
-- Returns the number of moved envelopes and the names of the skipped parameters.
local function moveAutomation(trackIndex, oldParameters, newParametersByOldId)
  local envelopeCount = 0
  local skippedNames = {}
  for _, oldParameter in ipairs(oldParameters) do
    local newParameter = newParametersByOldId[oldParameter.id]
    if (newParameter == nil) then
      table.insert(skippedNames, oldParameter.name)
    else
      for _, pattern in ipairs(Song.patterns) do
        local patternTrack = pattern:track(trackIndex)
        local oldAutomation = patternTrack:find_automation(oldParameter.parameter)
        if (oldAutomation ~= nil) then
          local newAutomation = patternTrack:find_automation(newParameter) or
              patternTrack:create_automation(newParameter)
          newAutomation:copy_from(oldAutomation)
          envelopeCount = envelopeCount + 1
        end
      end
    end
  end
  return envelopeCount, skippedNames
end

-- Finds the parameter index of Renoise in the VST3 version for each automated VST2 parameter, before the
-- song is changed. Returns the indices by the VST2 index, the method, or nil and the reason.
local function mapParameterIndices(target, deviceRole, oldParameters)
  local newIds, methodOrProblem = Vst3Migration:remapParameters(target, deviceRole, oldParameters)
  if (newIds == nil) then
    return nil, methodOrProblem
  end
  local vst3Parameters, problem = Vst3Migration:readParameters(target, deviceRole)
  if (vst3Parameters == nil) then
    return nil, problem
  end

  local renoiseIndices = createRenoiseIndicesByVst3Id(vst3Parameters)
  local indices = {}
  for _, oldParameter in ipairs(oldParameters) do
    indices[oldParameter.id] = renoiseIndices[newIds[oldParameter.id]]
  end
  return indices, methodOrProblem
end

-- The VST3 parameters of the new device by the VST2 index
local function findNewParameters(newDevice, oldParameters, indices)
  local newParameters = {}
  for _, oldParameter in ipairs(oldParameters) do
    local index = indices[oldParameter.id]
    if (index ~= nil and index <= #newDevice.parameters) then
      newParameters[oldParameter.id] = newDevice:parameter(index)
      print('info: parameter ' .. oldParameter.name .. ' (' .. oldParameter.id .. ') becomes ' ..
        newParameters[oldParameter.id].name .. ' (' .. index .. ')')
    end
  end
  return newParameters
end

-- Meta devices (e.g. *LFO, *Hydra) target a parameter by a group of their own parameters, named
-- '<prefix>Track', '<prefix>Effect' and '<prefix>Parameter' (e.g. 'Dest. ' or 'Out1 '). Their values are
-- indices with an unknown offset, but their value strings show the names of the targets. So a link is found
-- by the names, and its new value is calculated relative to the old one.
local META_EFFECT_SUFFIX = 'Effect'
local META_PARAMETER_SUFFIX = 'Parameter'
local META_TRACK_SUFFIX = 'Track'

local function containsName(text, name)
  return name ~= nil and name ~= '' and string.find(tostring(text), name, 1, true) ~= nil
end

local function findParametersByName(device)
  local parametersByName = {}
  for _, parameter in ipairs(device.parameters) do
    parametersByName[parameter.name] = parameter
  end
  return parametersByName
end

-- Without a track parameter, or set to its minimum ('current track'), the meta device targets its own track
local function targetsTrack(trackParameter, metaTrackIndex, targetTrackIndex)
  if (trackParameter == nil or trackParameter.value == trackParameter.value_min) then
    return metaTrackIndex == targetTrackIndex
  end
  return containsName(trackParameter.value_string, Song:track(targetTrackIndex).name)
end

-- The 1-based index of the device parameter shown by a value string, an exact name before a contained one
local function findParameterIndexByValueString(device, valueString)
  for index, parameter in ipairs(device.parameters) do
    if (parameter.name == valueString) then
      return index
    end
  end
  for index, parameter in ipairs(device.parameters) do
    if (containsName(valueString, parameter.name)) then
      return index
    end
  end
  return nil
end

-- The links of the meta devices to the device, as list of { trackIndex, deviceIndex, prefix, label, effectValue,
-- parameterOffset, oldId }, and the labels of the links whose parameter is unknown
local function findMetaLinks(device, trackIndex, deviceIndex)
  local links = {}
  local unknownLabels = {}
  for metaTrackIndex, metaTrack in ipairs(Song.tracks) do
    for metaDeviceIndex, metaDevice in ipairs(metaTrack.devices) do
      if (metaTrackIndex ~= trackIndex or metaDeviceIndex ~= deviceIndex) then
        local parametersByName = findParametersByName(metaDevice)
        for name, effectParameter in pairs(parametersByName) do
          local prefix = string.match(name, '^(.-)' .. META_EFFECT_SUFFIX .. '$')
          local parameterParameter = prefix and parametersByName[prefix .. META_PARAMETER_SUFFIX]
          if (parameterParameter ~= nil and
                targetsTrack(parametersByName[prefix .. META_TRACK_SUFFIX], metaTrackIndex, trackIndex) and
                containsName(effectParameter.value_string, device.display_name)) then
            local label = metaTrack.name .. ', ' .. metaDevice.display_name .. ' (' .. prefix .. '...)'
            local oldIndex = findParameterIndexByValueString(device, parameterParameter.value_string)
            if (oldIndex == nil) then
              table.insert(unknownLabels, label .. ': ' .. tostring(parameterParameter.value_string))
            else
              table.insert(links, {
                trackIndex = metaTrackIndex,
                deviceIndex = metaDeviceIndex,
                prefix = prefix,
                label = label,
                effectValue = effectParameter.value,
                parameterOffset = parameterParameter.value - (oldIndex - 1),
                oldId = oldIndex - 1,
              })
            end
          end
        end
      end
    end
  end
  return links, unknownLabels
end

-- The automated parameters and the ones the meta devices target, each once, as list of { id, name }
local function collectParametersToMap(device, automatedParameters, metaLinks)
  local parameters = {}
  local isCollected = {}
  for _, parameter in ipairs(automatedParameters) do
    isCollected[parameter.id] = true
    table.insert(parameters, { id = parameter.id, name = parameter.name })
  end
  for _, link in ipairs(metaLinks) do
    if (not isCollected[link.oldId]) then
      isCollected[link.oldId] = true
      table.insert(parameters, { id = link.oldId, name = device:parameter(link.oldId + 1).name })
    end
  end
  table.sort(parameters, function(a, b) return a.id < b.id end)
  return parameters
end

-- Sets the meta devices to the new device, which is at the position of the old one. Effect first, since it
-- might reset the parameter. Returns the labels of the links, which don't show the new parameter afterwards.
local function retargetMetaLinks(metaLinks, indices, newDevice)
  local failedLabels = {}
  for _, link in ipairs(metaLinks) do
    local parametersByName = findParametersByName(Song:track(link.trackIndex):device(link.deviceIndex))
    local effectParameter = parametersByName[link.prefix .. META_EFFECT_SUFFIX]
    local parameterParameter = parametersByName[link.prefix .. META_PARAMETER_SUFFIX]
    local newParameter = newDevice:parameter(indices[link.oldId])
    local parameterValue = link.parameterOffset + indices[link.oldId] - 1

    effectParameter.value = link.effectValue
    if (parameterValue >= parameterParameter.value_min and parameterValue <= parameterParameter.value_max) then
      parameterParameter.value = parameterValue
    end
    print('info: ' .. link.label .. ' targets ' .. tostring(effectParameter.value_string) .. ', ' ..
      tostring(parameterParameter.value_string))
    if (not containsName(parameterParameter.value_string, newParameter.name)) then
      table.insert(failedLabels, link.label)
    end
  end
  return failedLabels
end

-- Replaces the selected VST2 track effect by its VST3 version at the same position, with its state, automation
-- and the meta devices targeting it. Renoise objects can't be compared, so the device has to be the selected one.
function PluginMigrator:migrateEffect(device, pluginInfo, target)
  local trackIndex = Song.selected_track_index
  local track = Song.selected_track
  local deviceIndex = Song.selected_device_index

  local chunk = DeviceHelpers:getParameterChunk(device)
  if (chunk == nil) then
    renoise.app():show_warning('The state of ' .. device.name .. ' could not be read.')
    return
  end
  local presetData = Vst3Migration:createPresetData(target, pluginInfo, Helpers:base64ToString(chunk))
  local devicePath = Vst3Migration:getDevicePath(target, 'audioFX')
  local oldParameters = findAutomatedParameters(device)
  local metaLinks, unknownMetaLabels = findMetaLinks(device, trackIndex, deviceIndex)
  if (#unknownMetaLabels > 0) then
    renoise.app():show_warning(device.name .. ' stays VST2, since the targeted parameter of these meta devices ' ..
      'is unknown:\n\n' .. table.concat(unknownMetaLabels, '\n'))
    return
  end

  -- the automation and the meta devices have to stay intact, so nothing is changed if they can't be mapped
  local indices, methodOrProblem = {}, nil
  local parametersToMap = collectParametersToMap(device, oldParameters, metaLinks)
  if (#parametersToMap > 0) then
    indices, methodOrProblem = mapParameterIndices(target, 'audioFX', parametersToMap)
    if (indices == nil) then
      renoise.app():show_warning(device.name .. ' stays VST2, since its automated parameters could not be mapped: ' ..
        methodOrProblem)
      return
    end
  end
  local unmappedMetaLabels = {}
  for _, link in ipairs(metaLinks) do
    if (indices[link.oldId] == nil) then
      table.insert(unmappedMetaLabels, link.label)
    end
  end
  if (#unmappedMetaLabels > 0) then
    renoise.app():show_warning(device.name .. ' stays VST2, since the VST3 version has no parameter for these ' ..
      'meta devices:\n\n' .. table.concat(unmappedMetaLabels, '\n'))
    return
  end

  Song:describe_undo('Migrate ' .. device.name .. ' to VST3')
  local newDevice = track:insert_device_at(devicePath, deviceIndex + 1)
  if (not setParameterChunk(newDevice, Helpers:stringToBase64(presetData))) then
    track:delete_device_at(deviceIndex + 1)
    renoise.app():show_warning('The state of ' .. device.name .. ' could not be set for its VST3 version.')
    return
  end
  newDevice.is_active = device.is_active
  newDevice.is_maximized = device.is_maximized
  if (device.display_name ~= device.name) then
    newDevice.display_name = device.display_name
  end

  local report = { device.name .. ' is replaced by its VST3 version (' .. target.scheme.name .. ' scheme).' }
  if (#oldParameters > 0) then
    local newParameters = findNewParameters(newDevice, oldParameters, indices)
    local envelopeCount, skippedNames = moveAutomation(trackIndex, oldParameters, newParameters)
    table.insert(report, (#oldParameters - #skippedNames) .. ' of ' .. #oldParameters ..
      ' automated parameters are moved (' .. envelopeCount .. ' envelopes, mapped ' .. methodOrProblem .. ').')
    if (#skippedNames > 0) then
      table.insert(report, 'Lost automation, the VST3 version has no parameter for: ' ..
        table.concat(skippedNames, ', '))
    end
  end

  track:delete_device_at(deviceIndex)
  Song.selected_device_index = deviceIndex

  -- after deleting, so the new device is at the position the meta devices know
  if (#metaLinks > 0) then
    local failedLabels = retargetMetaLinks(metaLinks, indices, newDevice)
    table.insert(report, (#metaLinks - #failedLabels) .. ' of ' .. #metaLinks ..
      ' meta device targets are set to the VST3 version.')
    if (#failedLabels > 0) then
      table.insert(report, 'Please check these meta devices, they don\'t show the new parameter:\n' ..
        table.concat(failedLabels, '\n'))
    end
  end

  table.insert(report, 'Not adjusted yet: pattern commands, which target the device.')
  local text = table.concat(report, '\n\n')
  print('info: ' .. text)
  renoise.app():show_message(text)
end

local INSTRUMENT_AUTOMATION_DEVICE_PATH = 'Audio/Effects/Native/*Instr. Automation'
local UNASSIGNED_PARAMETER_NAME = 'No Parameter'

-- The slots of an *Instr. Automation device are its parameters. Each slot controls a parameter of the plugin,
-- its preset data has the plugin parameter index (0-based) by the slot index (0-based).
local PARAMETER_NUMBER_PATTERN = '<ParameterNumber(%d+)>(%-?%d+)</ParameterNumber(%d+)>'

local function readParameterNumbers(device)
  local numbers = {}
  for slot, number in string.gmatch(device.active_preset_data, PARAMETER_NUMBER_PATTERN) do
    numbers[tonumber(slot)] = tonumber(number)
  end
  return numbers
end

-- Sets the plugin parameter indices of the slots, the ones without a new index stay
local function writeParameterNumbers(device, numbers)
  device.active_preset_data = string.gsub(device.active_preset_data, PARAMETER_NUMBER_PATTERN,
    function(slot, number, closingSlot)
      return '<ParameterNumber' .. slot .. '>' .. (numbers[tonumber(slot)] or number) ..
          '</ParameterNumber' .. closingSlot .. '>'
    end)
end

-- A slot controls the plugin, if it has the name of the plugin parameter it is assigned to
local function controlsPlugin(device, numbers, pluginDevice)
  local matchCount = 0
  for slot, number in pairs(numbers) do
    local slotParameter = device.parameters[slot + 1]
    local pluginParameter = pluginDevice.parameters[number + 1]
    if (slotParameter ~= nil and slotParameter.name ~= UNASSIGNED_PARAMETER_NAME) then
      if (pluginParameter == nil or slotParameter.name ~= pluginParameter.name) then
        return false
      end
      matchCount = matchCount + 1
    end
  end
  return matchCount > 0
end

-- The *Instr. Automation devices controlling the plugin, as list of { trackIndex, deviceIndex, label, numbers }.
-- Their target instrument can't be read via API, so all their slots have to match the parameters of the plugin.
local function findInstrumentAutomationDevices(pluginDevice)
  local automationDevices = {}
  for trackIndex, track in ipairs(Song.tracks) do
    for deviceIndex, device in ipairs(track.devices) do
      if (device.device_path == INSTRUMENT_AUTOMATION_DEVICE_PATH) then
        local numbers = readParameterNumbers(device)
        if (controlsPlugin(device, numbers, pluginDevice)) then
          table.insert(automationDevices, {
            trackIndex = trackIndex,
            deviceIndex = deviceIndex,
            label = track.name .. ', device ' .. deviceIndex,
            numbers = numbers,
          })
        end
      end
    end
  end
  return automationDevices
end

-- The plugin parameters the slots are assigned to, as list of { id, name }. The id is the VST2 index.
local function collectAssignedParameters(automationDevices, pluginDevice)
  local parameters = {}
  local isCollected = {}
  for _, automationDevice in ipairs(automationDevices) do
    for _, number in pairs(automationDevice.numbers) do
      local pluginParameter = pluginDevice.parameters[number + 1]
      if (pluginParameter ~= nil and not isCollected[number]) then
        isCollected[number] = true
        table.insert(parameters, { id = number, name = pluginParameter.name })
      end
    end
  end
  table.sort(parameters, function(a, b) return a.id < b.id end)
  return parameters
end

-- The new plugin parameter index (0-based) of each slot. Returns them by the slot, and the labels of the
-- automated slots without one.
local function remapSlots(automationDevice, indices)
  local device = Song:track(automationDevice.trackIndex):device(automationDevice.deviceIndex)
  local newNumbers = {}
  local unmappedLabels = {}
  for slot, number in pairs(automationDevice.numbers) do
    local index = indices[number]
    if (index ~= nil) then
      newNumbers[slot] = index - 1
    elseif (device.parameters[slot + 1] ~= nil and device.parameters[slot + 1].is_automated) then
      table.insert(unmappedLabels, automationDevice.label .. ': ' .. device.parameters[slot + 1].name)
    end
  end
  return newNumbers, unmappedLabels
end

-- Replaces the VST2 plugin of the selected instrument by its VST3 version, with its state. The slots of the
-- *Instr. Automation devices are assigned to the VST3 parameters, so their automation stays.
-- Renoise objects can't be compared, so the device has to be the one of the selected instrument.
function PluginMigrator:migrateInstrument(device, pluginInfo, target)
  local instrument = Song.selected_instrument
  local pluginProperties = instrument.plugin_properties

  -- the automation has to stay intact, so nothing is changed if an automated slot can't be mapped
  local automationDevices = findInstrumentAutomationDevices(device)
  local newNumbersByDevice = {}
  local method
  if (#automationDevices > 0) then
    local indices, methodOrProblem = mapParameterIndices(target, 'instrument',
      collectAssignedParameters(automationDevices, device))
    if (indices == nil) then
      renoise.app():show_warning(device.name .. ' stays VST2, since the parameters of its *Instr. Automation ' ..
        'devices could not be mapped: ' .. methodOrProblem)
      return
    end
    method = methodOrProblem

    local unmappedLabels = {}
    for index, automationDevice in ipairs(automationDevices) do
      local newNumbers, unmapped = remapSlots(automationDevice, indices)
      newNumbersByDevice[index] = newNumbers
      for _, label in ipairs(unmapped) do
        table.insert(unmappedLabels, label)
      end
    end
    if (#unmappedLabels > 0) then
      renoise.app():show_warning(device.name .. ' stays VST2, since the VST3 version has no parameter for these ' ..
        'automated slots:\n\n' .. table.concat(unmappedLabels, '\n'))
      return
    end
  end

  local chunk = DeviceHelpers:getParameterChunk(device)
  if (chunk == nil) then
    renoise.app():show_warning('The state of ' .. device.name .. ' could not be read.')
    return
  end
  local presetData = Vst3Migration:createPresetData(target, pluginInfo, Helpers:base64ToString(chunk))
  local devicePath = Vst3Migration:getDevicePath(target, 'instrument')
  local deviceName = device.name

  -- loading a plugin can change the settings of the instrument
  local instrumentName = instrument.name
  local volume = pluginProperties.volume
  local autoSuspend = pluginProperties.auto_suspend

  Song:describe_undo('Migrate ' .. deviceName .. ' to VST3')
  if (not pluginProperties:load_plugin(devicePath)) then
    renoise.app():show_warning('The VST3 version of ' .. deviceName .. ' could not be loaded.')
    return
  end
  local newDevice = pluginProperties.plugin_device

  instrument.name = instrumentName
  pluginProperties.volume = volume
  pluginProperties.auto_suspend = autoSuspend

  local report = { deviceName .. ' is replaced by its VST3 version (' .. target.scheme.name .. ' scheme).' }
  if (not setParameterChunk(newDevice, Helpers:stringToBase64(presetData))) then
    table.insert(report, 'Its state could not be set, so the VST3 version has its default settings. ' ..
      'Undo restores the VST2 version.')
  end

  -- after loading, since Renoise might reset the slots for the new plugin
  local labels = {}
  for index, automationDevice in ipairs(automationDevices) do
    local automationDeviceObj = Song:track(automationDevice.trackIndex):device(automationDevice.deviceIndex)
    writeParameterNumbers(automationDeviceObj, newNumbersByDevice[index])
    table.insert(labels, automationDevice.label)
    for slot, number in pairs(newNumbersByDevice[index]) do
      local slotParameter = automationDeviceObj.parameters[slot + 1]
      print('info: ' .. automationDevice.label .. ', slot ' .. slot .. ': parameter ' .. automationDevice.numbers[slot] ..
        ' becomes ' .. number .. ' (' .. (slotParameter and slotParameter.name or '?') .. ')')
    end
  end
  if (#labels > 0) then
    table.insert(report, #labels .. ' *Instr. Automation devices are assigned to the VST3 parameters (mapped ' ..
      method .. '):\n' .. table.concat(labels, '\n'))
  end

  local text = table.concat(report, '\n\n')
  print('info: ' .. text)
  renoise.app():show_message(text)
end


--------------------------------------------------------------------------------
-- Main calls
--------------------------------------------------------------------------------

function PluginMigrator:migrate(device, deviceRole)
  if (not isVst2Device(device)) then
    return
  end
  Vst3Migration:resetCaches()

  local pluginInfo = DeviceHelpers:readPluginInfo(device)
  if (pluginInfo == nil) then
    renoise.app():show_warning('The VST2 plugin ' .. device.name .. ' could not be read.')
    return
  end

  local target = Vst3Migration:findInstalledTarget(pluginInfo['id'],
    { pluginInfo['name'], device.short_name, device.name }, deviceRole)
  if (target == nil) then
    local hint = ''
    if (not PluginMigrationData:exists()) then
      hint = '\n\nThe plugin migration data is not built yet, it finds more VST3 versions: ' ..
          'Tools > Plugin Migrator > Build plugin migration data...'
    end
    renoise.app():show_message('There is no installed VST3 version of ' .. device.name .. ', which can replace it.' ..
      hint)
    return
  end

  if (deviceRole == 'audioFX') then
    self:migrateEffect(device, pluginInfo, target)
  else
    self:migrateInstrument(device, pluginInfo, target)
  end
end

-- Reads which installed VST3 plugins can replace older plugins. The data is shared with the DAW Project Tool.
function PluginMigrator:scanPluginMigrationData()
  backgroundTask:stop()
  local isRefresh = PluginMigrationData:exists()
  backgroundTask:run(
    isRefresh and 'Refreshing plugin migration data' or 'Building plugin migration data',
    function()
      PluginMigrationData:scan(progressDialog)
      self:refreshScanMenu()
    end,
    'Plugin migration data done!',
    'Plugin migration data failed!'
  )
end

local SCAN_MENU_PREFIX = 'Main Menu:Tools:Plugin Migrator:'
local SCAN_MENU_BUILD = SCAN_MENU_PREFIX .. 'Build plugin migration data...'
local SCAN_MENU_REFRESH = SCAN_MENU_PREFIX .. 'Refresh plugin migration data...'
local LIST_MENU = SCAN_MENU_PREFIX .. 'List migratable plugins...'

-- The progress dialog closes by itself, when the list is shown
local LIST_PROGRESS_CLOSE_SECONDS = 1

-- Lists the installed VST2 plugins, which an installed VST3 version can replace. retryFailed also reads the
-- plugins again, which failed before.
function PluginMigrator:listMigratablePlugins(retryFailed)
  backgroundTask:stop()
  migratablePluginsDialog:close()
  backgroundTask:run(
    'Listing migratable plugins',
    function()
      local result = MigratablePlugins:scan(progressDialog, retryFailed)
      local hint = nil
      if (not PluginMigrationData:exists()) then
        hint = 'The plugin migration data is not built yet, it finds more VST3 versions: ' ..
            'Tools > Plugin Migrator > Build plugin migration data...'
      end
      migratablePluginsDialog:show(result, hint, function() self:listMigratablePlugins(true) end)
    end,
    'Migratable plugins listed!',
    'Listing migratable plugins failed!',
    LIST_PROGRESS_CLOSE_SECONDS
  )
end

-- The first scan builds the data, every later one refreshes it
function PluginMigrator:refreshScanMenu()
  MenuEntry:remove(SCAN_MENU_BUILD)
  MenuEntry:remove(SCAN_MENU_REFRESH)
  MenuEntry:add(PluginMigrationData:exists() and SCAN_MENU_REFRESH or SCAN_MENU_BUILD,
    function() self:scanPluginMigrationData() end)
end

-- Menu entries can't be hidden, so they are added for a VST2 plugin and removed otherwise. The check is cheap,
-- so it runs while idle, which also notices a plugin loaded into the selected instrument.
function PluginMigrator:watchSelection()
  local hasEffectEntries = nil
  local hasInstrumentEntry = nil

  local refreshMigrationMenu = function()
    -- there is no song while a song is loaded
    Song = renoise.song()
    if (Song == nil) then
      return
    end

    local isEffectVst2 = isVst2Device(getSelectedEffect())
    if (isEffectVst2 ~= hasEffectEntries) then
      hasEffectEntries = isEffectVst2
      for _, name in ipairs(EFFECT_MENU_ENTRIES) do
        if (isEffectVst2) then
          MenuEntry:add(name, function() self:migrate(getSelectedEffect(), 'audioFX') end)
        else
          MenuEntry:remove(name)
        end
      end
    end

    local isInstrumentVst2 = isVst2Device(getSelectedInstrumentPlugin())
    if (isInstrumentVst2 ~= hasInstrumentEntry) then
      hasInstrumentEntry = isInstrumentVst2
      if (isInstrumentVst2) then
        MenuEntry:add(INSTRUMENT_MENU_ENTRY, function() self:migrate(getSelectedInstrumentPlugin(), 'instrument') end)
      else
        MenuEntry:remove(INSTRUMENT_MENU_ENTRY)
      end
    end
  end

  Notifiers:add(Tool.app_idle_observable, refreshMigrationMenu)
end


--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function PluginMigrator:__init()
  progressDialog = ProgressDialog('Plugin Migrator')
  backgroundTask = BackgroundTask(progressDialog)
  migratablePluginsDialog = MigratablePluginsDialog()

  self:refreshScanMenu()
  MenuEntry:add(LIST_MENU, function() self:listMigratablePlugins(false) end)
  self:watchSelection()

  Notifiers:add(Tool.app_new_document_observable, function()
    Song = renoise.song()
  end)

  Notifiers:add(Tool.app_release_document_observable, function()
    backgroundTask:stop()
    progressDialog:close()
    migratablePluginsDialog:close()
  end)
end

PluginMigrator()
