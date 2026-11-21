-------------------------------------------------------------------------------
-- Migratable Plugins, finds the installed VST2 plugins which an installed VST3
-- version can replace, and what the migration can keep of them.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--
-- The plugin database of Renoise doesn't know the VST2 ids, so each VST2 file
-- is read once by the VST2 helper tool. Each VST3 version is asked once,
-- whether it maps the VST2 parameters by itself (IRemapParamID). Both results
-- are saved in the preferences directory of Renoise, so a later listing only
-- reads new and changed plugins.
-------------------------------------------------------------------------------

local json = require('lib/shared/json')

local FILE_NAME = 'DawProjectMigratablePlugins.json'
local FORMAT_VERSION = 1

-- Saves the state regularly, so a cancelled listing can be continued
local SAVE_INTERVAL = 25

MigratablePlugins = {}

-- How the automation of a VST2 plugin is moved to the VST3 version
MigratablePlugins.AUTOMATION_BY_PLUGIN = 'by plugin'
MigratablePlugins.AUTOMATION_BY_NAMES = 'by index and name'
MigratablePlugins.AUTOMATION_UNKNOWN = 'unknown'

local function getFilePath()
  local preferencesPath = DeviceHelpers:getPreferencesPath()
  return preferencesPath and (preferencesPath .. FILE_NAME) or nil
end

local function loadCache()
  local cache = { version = FORMAT_VERSION, vst2 = {}, remap = {} }
  local filePath = getFilePath()
  if (filePath == nil or not io.exists(filePath)) then
    return cache
  end
  local file = io.open(filePath, 'rb')
  if (file == nil) then
    return cache
  end
  local content = file:read('*a')
  file:close()

  local success, data = pcall(json.decode, content)
  if (not success or type(data) ~= 'table' or data.version ~= FORMAT_VERSION) then
    print('warning: the cache of the migratable plugins is invalid and is read again: ' .. filePath)
    return cache
  end
  cache.vst2 = type(data.vst2) == 'table' and data.vst2 or {}
  cache.remap = type(data.remap) == 'table' and data.remap or {}
  return cache
end

local function saveCache(cache)
  local filePath = getFilePath()
  local file = filePath and io.open(filePath, 'wb')
  if (not file) then
    error('the cache of the migratable plugins can not be written to ' .. tostring(filePath))
  end
  file:write(json.encode(cache))
  file:close()
end

local function getModificationTime(path)
  local stat = io.stat(path)
  return stat and stat.mtime or 0
end

-------------------------------------------------------------------------------
-- Plugin database of Renoise
-------------------------------------------------------------------------------

local function openDatabase(dbPath)
  if (dbPath == nil or not io.exists(dbPath)) then
    return nil
  end
  local db, _, error = renoise.SQLite.open(dbPath, 'ro')
  if (db == nil or error ~= nil) then
    if (db ~= nil) then
      db:close()
    end
    return nil
  end
  return db
end

local function isTrue(value)
  return value == 1 or value == true
end

-- The files Renoise failed to load, they would fail in the helper tool, too
local function readFailedVst2Paths()
  local failedPaths = {}
  local db = openDatabase(DeviceHelpers:getPluginDatabasePath('vst2', true))
  if (db == nil) then
    return failedPaths
  end
  pcall(function()
    for row in db:rows('SELECT LocalFilePath FROM CachedFailedPlugins;') do
      if (row[1] ~= nil) then
        failedPaths[row[1]] = true
      end
    end
  end)
  db:close()
  return failedPaths
end

-- The installed VST2 plugins, each once, as list of { identifier, path, name, vendor, isInstrument, isBridged,
-- modificationTime }. The identifier is the one of the device path, a file can contain several plugins (a shell).
-- Returns nil and the reason on failure.
local function readInstalledVst2Plugins()
  local dbPath = DeviceHelpers:getPluginDatabasePath('vst2')
  local db = openDatabase(dbPath)
  if (db == nil) then
    return nil, 'the plugin database of Renoise can not be opened: ' .. tostring(dbPath)
  end

  local sql = 'SELECT CachedPlugins.DocumentIdentifier, CachedPlugins.LocalFilePath, CachedPlugins.IsBridged, ' ..
      'CachedPlugins.IsSynth, CachedPlugins.DisplayName, CachedPlugins.ShortDisplayName, ' ..
      'CachedLocalFileInfo.ModificationTime ' ..
      'FROM CachedPlugins LEFT JOIN CachedLocalFileInfo ' ..
      'ON CachedLocalFileInfo.LocalFilePath = CachedPlugins.LocalFilePath ' ..
      "WHERE CachedPlugins.LocalFilePath <> '';"

  local failedPaths = readFailedVst2Paths()
  local plugins = {}
  local isListed = {}
  for row in db:rows(sql) do
    local identifier, path = row[1], row[2]
    local isInstrument = isTrue(row[4])
    -- e.g. several installed versions of a shell, the first one is enough for the list
    local key = tostring(identifier) .. (isInstrument and '|instrument' or '|effect')
    if (identifier ~= nil and path ~= nil and not failedPaths[path] and not isListed[key]) then
      isListed[key] = true
      local displayName = tostring(row[5] or '')
      table.insert(plugins, {
        identifier = identifier,
        path = path,
        name = (row[6] ~= nil and row[6] ~= '') and row[6] or identifier,
        vendor = displayName:match('^(.-): ') or '',
        isInstrument = isInstrument,
        isBridged = isTrue(row[3]),
        modificationTime = tonumber(row[7]) or 0,
      })
    end
  end
  db:close()

  table.sort(plugins, function(a, b) return a.path < b.path end)
  return plugins
end

-------------------------------------------------------------------------------
-- Reading the plugins
-------------------------------------------------------------------------------

-- Reads the VST2 ids of a file, as list of { id, name }. A shell lists all its plugins.
local function readVst2File(plugin)
  local entry = { modificationTime = plugin.modificationTime }

  local toolName, unavailableReason = DeviceHelpers:getInfoToolName('vst2', plugin.isBridged)
  if (toolName == nil) then
    entry.error = 'vst info tool ' .. unavailableReason
    return entry
  end
  if (not io.exists('./bin/' .. toolName)) then
    entry.error = 'vst info tool does not exist under ./bin/' .. toolName
    return entry
  end

  local toolOutput = DeviceHelpers:executeInfoTool(toolName, DeviceHelpers:quotePathForConsole(plugin.path))
  local info, problem = DeviceHelpers:decodeInfoToolOutput(toolOutput)
  if (info == nil) then
    entry.error = problem .. ', the plugin probably crashed the vst info tool'
    return entry
  end
  if (info.error ~= nil) then
    entry.error = tostring(info.error)
    return entry
  end

  entry.plugins = {}
  if (type(info.shellPlugins) == 'table') then
    for _, shellPlugin in ipairs(info.shellPlugins) do
      table.insert(entry.plugins, { id = shellPlugin.id, name = shellPlugin.name })
    end
  else
    table.insert(entry.plugins, { id = info.id, name = info.name })
  end
  return entry
end

-- The VST2 id and the internal name of a plugin, from the read entry of its file
local function findVst2Info(entry, plugin)
  local filePlugins = entry and entry.plugins or {}
  if (#filePlugins == 1) then
    return filePlugins[1]
  end
  -- Renoise uses the name of the plugin inside of a shell as its identifier
  for _, filePlugin in ipairs(filePlugins) do
    if (filePlugin.name == plugin.identifier) then
      return filePlugin
    end
  end
  return nil
end

-- The short names of the installed plugins by their device paths
local function readDeviceNames()
  local names = {}
  for _, deviceInfo in ipairs(Song:track(1).available_device_infos) do
    names[deviceInfo.path] = deviceInfo.short_name
  end
  for _, pluginInfo in ipairs(Song:instrument(1).plugin_properties.available_plugin_infos) do
    names[pluginInfo.path] = pluginInfo.short_name
  end
  return names
end

local function createRemapKey(filePath, target)
  return filePath .. '|' .. target.classId .. '|' .. target.replacedClassId
end

-------------------------------------------------------------------------------
-- Scan
-------------------------------------------------------------------------------

-- Lists the installed VST2 plugins with an installed VST3 version. Has to run inside of a coroutine, since it
-- yields after every plugin it reads. With retryFailed the plugins that failed before are read again.
-- Returns { rows, vst2Count, unreadableCount }. Each row is { name, vendor, isInstrument, vst3Name, scheme,
-- automation, automationProblem }.
function MigratablePlugins:scan(progress, retryFailed)
  progress:setPhase('Reading the plugin database of Renoise', 0, 0.02)
  coroutine.yield()

  Song = renoise.song()
  Vst3Migration:resetCaches()
  local plugins, problem = readInstalledVst2Plugins()
  if (plugins == nil) then
    error(problem)
  end
  local cache = loadCache()

  -- each file is read once, also if it contains several plugins
  local filesToRead = {}
  local isQueued = {}
  for _, plugin in ipairs(plugins) do
    local entry = cache.vst2[plugin.path]
    local isUpToDate = entry ~= nil and entry.modificationTime == plugin.modificationTime and
        (entry.error == nil or not retryFailed)
    if (not isUpToDate and not isQueued[plugin.path]) then
      isQueued[plugin.path] = true
      table.insert(filesToRead, plugin)
    end
  end
  print('info: ' .. #plugins .. ' VST2 plugins installed, ' .. #filesToRead .. ' files are read')

  progress:setPhase('Reading the VST2 plugins', 0.02, 0.7)
  for index, plugin in ipairs(filesToRead) do
    progress:setStatus('Reading ' .. plugin.name .. ' (' .. index .. ' of ' .. #filesToRead .. ')')
    coroutine.yield()

    local entry = readVst2File(plugin)
    cache.vst2[plugin.path] = entry
    if (entry.error ~= nil) then
      print('warning: VST2 plugin ' .. plugin.path .. ' could not be read: ' .. entry.error)
    end
    if (index % SAVE_INTERVAL == 0) then
      saveCache(cache)
    end
    progress:advancePhase(#filesToRead)
  end

  progress:setPhase('Finding the VST3 versions', 0.7, 0.72)
  coroutine.yield()

  local rows = {}
  local unreadableCount = 0
  for _, plugin in ipairs(plugins) do
    local vst2Info = findVst2Info(cache.vst2[plugin.path], plugin)
    if (vst2Info == nil or type(vst2Info.id) ~= 'number') then
      unreadableCount = unreadableCount + 1
    else
      local deviceRole = plugin.isInstrument and 'instrument' or 'audioFX'
      local target = Vst3Migration:findInstalledTarget(vst2Info.id, { vst2Info.name, plugin.name, plugin.identifier },
        deviceRole)
      if (target ~= nil) then
        table.insert(rows, { plugin = plugin, target = target, deviceRole = deviceRole })
      end
    end
  end

  -- each VST3 version is asked once, also if it replaces several VST2 plugins
  local remapsToCheck = {}
  local isRemapQueued = {}
  for _, row in ipairs(rows) do
    row.vst3FilePath = Vst3Migration:findTargetFilePath(row.target, row.deviceRole)
    if (row.vst3FilePath ~= nil) then
      local key = createRemapKey(row.vst3FilePath, row.target)
      local entry = cache.remap[key]
      local modificationTime = getModificationTime(row.vst3FilePath)
      local isUpToDate = entry ~= nil and entry.modificationTime == modificationTime and
          (entry.error == nil or not retryFailed)
      if (not isUpToDate and not isRemapQueued[key]) then
        isRemapQueued[key] = true
        table.insert(remapsToCheck, { key = key, row = row, modificationTime = modificationTime })
      end
    end
  end

  progress:setPhase('Asking the VST3 versions', 0.72, 0.98)
  for index, check in ipairs(remapsToCheck) do
    progress:setStatus('Asking the VST3 version of ' .. check.row.plugin.name .. ' (' .. index .. ' of ' ..
      #remapsToCheck .. ')')
    coroutine.yield()

    local supported, remapProblem = Vst3Migration:isRemapSupported(check.row.vst3FilePath, check.row.target)
    cache.remap[check.key] = { modificationTime = check.modificationTime, supported = supported, error = remapProblem }
    if (supported == nil) then
      print('warning: VST3 plugin ' .. check.row.vst3FilePath .. ' could not be asked: ' .. tostring(remapProblem))
    end
    if (index % SAVE_INTERVAL == 0) then
      saveCache(cache)
    end
    progress:advancePhase(#remapsToCheck)
  end

  progress:setPhase('Writing the list', 0.98, 1)
  coroutine.yield()
  saveCache(cache)

  local deviceNames = readDeviceNames()
  local result = { rows = {}, vst2Count = #plugins, unreadableCount = unreadableCount }
  for _, row in ipairs(rows) do
    local automation, automationProblem = self.AUTOMATION_UNKNOWN, 'the file of the VST3 version is unknown'
    local remapEntry = row.vst3FilePath and cache.remap[createRemapKey(row.vst3FilePath, row.target)]
    if (remapEntry ~= nil) then
      if (remapEntry.supported == true) then
        automation, automationProblem = self.AUTOMATION_BY_PLUGIN, nil
      elseif (remapEntry.supported == false) then
        automation, automationProblem = self.AUTOMATION_BY_NAMES, nil
      else
        automationProblem = remapEntry.error
      end
    end

    table.insert(result.rows, {
      name = row.plugin.name,
      vendor = row.plugin.vendor,
      isInstrument = row.plugin.isInstrument,
      vst3Name = deviceNames[Vst3Migration:getDevicePath(row.target, row.deviceRole)] or row.target.classId,
      scheme = row.target.scheme.name,
      automation = automation,
      automationProblem = automationProblem,
    })
  end

  print('info: ' .. #result.rows .. ' of ' .. #plugins .. ' VST2 plugins can be migrated to VST3, ' ..
    unreadableCount .. ' could not be read')
  return result
end
