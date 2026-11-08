-------------------------------------------------------------------------------
-- Plugin Migration Data, knows which installed VST3 plugins can replace older
-- plugins, e.g. their own VST2 version.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--
-- The VST3 plugins are taken from the plugin database of Renoise, without the
-- ones Renoise failed to load. The VST3 helper tool reads one plugin at a time,
-- from its moduleinfo.json or its factory, see "--migration-info".
-- The result is saved as JSON in the preferences directory of Renoise, so it
-- survives updates of the tool. A refresh only reads new and changed plugins,
-- and the plugins that failed before.
-------------------------------------------------------------------------------

local json = require('lib/json')

local FILE_NAME = 'DawProjectPluginMigration.json'
local FORMAT_VERSION = 1
local MIGRATION_INFO_SWITCH = '--migration-info'

-- Saves the state regularly, so a cancelled scan can be continued by a refresh
local SAVE_INTERVAL = 25

PluginMigrationData = {}

function PluginMigrationData:getFilePath()
  local preferencesPath = DeviceHelpers:getPreferencesPath()
  return preferencesPath and (preferencesPath .. FILE_NAME) or nil
end

function PluginMigrationData:exists()
  local filePath = self:getFilePath()
  return filePath ~= nil and io.exists(filePath)
end

-- Returns the saved data, or nil if there is none or it is invalid
function PluginMigrationData:load()
  local filePath = self:getFilePath()
  if (filePath == nil or not io.exists(filePath)) then
    return nil
  end
  local file = io.open(filePath, 'rb')
  if (file == nil) then
    return nil
  end
  local content = file:read('*a')
  file:close()

  local success, data = pcall(json.decode, content)
  if (not success or type(data) ~= 'table' or type(data.plugins) ~= 'table') then
    print('warning: the plugin migration data is invalid and is read again: ' .. filePath)
    return nil
  end
  return data
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

local function readFailedPluginPaths()
  local failedPaths = {}
  local db = openDatabase(DeviceHelpers:getPluginDatabasePath('vst3', true))
  if (db == nil) then
    return failedPaths
  end
  for row in db:rows('SELECT LocalFilePath FROM CachedFailedPlugins;') do
    if (row[1] ~= nil) then
      failedPaths[row[1]] = true
    end
  end
  db:close()
  return failedPaths
end

-- The installed VST3 bundles, one entry per file, sorted by path. Returns nil and the reason on failure.
function PluginMigrationData:readInstalledBundles()
  local dbPath = DeviceHelpers:getPluginDatabasePath('vst3')
  local db = openDatabase(dbPath)
  if (db == nil) then
    return nil, 'the plugin database of Renoise can not be opened: ' .. tostring(dbPath)
  end

  -- A file can contain several plugins, but it is read only once
  local sql = 'SELECT CachedPlugins.LocalFilePath, MAX(CachedPlugins.IsBridged), CachedLocalFileInfo.ModificationTime ' ..
      'FROM CachedPlugins LEFT JOIN CachedLocalFileInfo ' ..
      'ON CachedLocalFileInfo.LocalFilePath = CachedPlugins.LocalFilePath ' ..
      "WHERE CachedPlugins.LocalFilePath <> '' GROUP BY CachedPlugins.LocalFilePath;"

  local failedPaths = readFailedPluginPaths()
  local bundles = {}
  for row in db:rows(sql) do
    local path = row[1]
    if (path ~= nil and not failedPaths[path]) then
      table.insert(bundles, {
        path = path,
        isBridged = row[2] == 1 or row[2] == true,
        modificationTime = tonumber(row[3]) or 0,
      })
    end
  end
  db:close()

  table.sort(bundles, function(a, b) return a.path < b.path end)
  return bundles
end

-------------------------------------------------------------------------------
-- Reading a plugin
-------------------------------------------------------------------------------

local function getBundleName(path)
  return path:match('([^/\\]+)$') or path
end

-- Returns the entry of a bundle, with an error instead of the infos if it could not be read
function PluginMigrationData:readBundle(bundle)
  local entry = {
    path = bundle.path,
    modificationTime = bundle.modificationTime,
  }

  local toolName, unavailableReason = DeviceHelpers:getInfoToolName('vst3', bundle.isBridged)
  if (toolName == nil) then
    entry.error = 'vst info tool ' .. unavailableReason
    return entry
  end
  if (not io.exists('./bin/' .. toolName)) then
    entry.error = 'vst info tool does not exist under ./bin/' .. toolName
    return entry
  end

  local toolOutput = DeviceHelpers:executeInfoTool(toolName,
    MIGRATION_INFO_SWITCH .. ' ' .. DeviceHelpers:quotePathForConsole(bundle.path))
  local info, problem = DeviceHelpers:decodeInfoToolOutput(toolOutput)
  if (info == nil) then
    -- without any result the tool didn't finish, which mostly means the plugin crashed it
    entry.error = problem .. ', the plugin probably crashed the vst info tool'
    if (toolOutput ~= nil and toolOutput ~= '') then
      print(toolOutput)
    end
    return entry
  end
  if (info.error ~= nil) then
    entry.error = tostring(info.error)
    return entry
  end

  entry.source = info.source
  entry.vendor = info.vendor
  entry.classes = info.classes or {}
  entry.compatibility = info.compatibility or {}
  return entry
end

local function isUpToDate(previousEntry, bundle)
  return previousEntry ~= nil and previousEntry.error == nil and
      previousEntry.modificationTime == bundle.modificationTime
end

-------------------------------------------------------------------------------
-- Writing the file
-------------------------------------------------------------------------------

local function encodeString(text)
  local escaped = text:gsub('[%c"\\]', function(character)
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return escapes[character] or string.format('\\u%04x', string.byte(character))
  end)
  return '"' .. escaped .. '"'
end

local function isArray(value)
  return next(value) == nil or value[1] ~= nil
end

-- The keys are written in this order, so an entry starts with its plugin. Unknown keys follow sorted.
local KEY_ORDER = {
  'version', 'plugins',
  'path', 'vendor', 'source', 'modificationTime', 'error', 'classes', 'compatibility',
  'cid', 'name', 'category',
  'new', 'old',
}
local KEY_RANKS = {}
for rank, key in ipairs(KEY_ORDER) do
  KEY_RANKS[key] = rank
end

local function compareKeys(a, b)
  local rankA = KEY_RANKS[a] or (#KEY_ORDER + 1)
  local rankB = KEY_RANKS[b] or (#KEY_ORDER + 1)
  if (rankA ~= rankB) then
    return rankA < rankB
  end
  return a < b
end

-- A fixed order of the keys and a fixed indentation, so git shows the changes line by line.
-- All empty tables are written as arrays, the data has no empty objects.
local function encodeValue(value, indentation)
  local valueType = type(value)
  if (valueType == 'string') then
    return encodeString(value)
  elseif (valueType == 'number') then
    return (value == math.floor(value)) and string.format('%d', value) or string.format('%.17g', value)
  elseif (valueType == 'boolean') then
    return tostring(value)
  elseif (valueType ~= 'table') then
    return 'null'
  end

  local innerIndentation = indentation .. '  '
  local lines = {}
  if (isArray(value)) then
    if (#value == 0) then
      return '[]'
    end
    for _, item in ipairs(value) do
      table.insert(lines, innerIndentation .. encodeValue(item, innerIndentation))
    end
    return '[\n' .. table.concat(lines, ',\n') .. '\n' .. indentation .. ']'
  end

  local keys = {}
  for key in pairs(value) do
    table.insert(keys, tostring(key))
  end
  table.sort(keys, compareKeys)
  for _, key in ipairs(keys) do
    table.insert(lines, innerIndentation .. encodeString(key) .. ': ' .. encodeValue(value[key], innerIndentation))
  end
  return '{\n' .. table.concat(lines, ',\n') .. '\n' .. indentation .. '}'
end

function PluginMigrationData:save(entriesByPath)
  local plugins = {}
  for _, entry in pairs(entriesByPath) do
    table.insert(plugins, entry)
  end
  table.sort(plugins, function(a, b) return a.path < b.path end)

  local filePath = self:getFilePath()
  local file = filePath and io.open(filePath, 'wb')
  if (not file) then
    error('the plugin migration data can not be written to ' .. tostring(filePath))
  end
  file:write(encodeValue({ version = FORMAT_VERSION, plugins = plugins }, '') .. '\n')
  file:close()
end

-------------------------------------------------------------------------------
-- Scan
-------------------------------------------------------------------------------

-- Reads all the installed VST3 plugins, which are new, changed or failed before.
-- Has to run inside of a coroutine, since it yields after every plugin.
function PluginMigrationData:scan(progress)
  progress:setPhase('Reading the plugin database of Renoise', 0, 0.02)
  coroutine.yield()

  local bundles, problem = self:readInstalledBundles()
  if (bundles == nil) then
    error(problem)
  end

  local previousEntries = {}
  local previousData = self:load()
  for _, entry in ipairs(previousData and previousData.plugins or {}) do
    if (type(entry) == 'table' and entry.path ~= nil) then
      previousEntries[entry.path] = entry
    end
  end

  -- plugins that are not installed anymore are left out
  local entriesByPath = {}
  local bundlesToRead = {}
  for _, bundle in ipairs(bundles) do
    if (isUpToDate(previousEntries[bundle.path], bundle)) then
      entriesByPath[bundle.path] = previousEntries[bundle.path]
    else
      table.insert(bundlesToRead, bundle)
    end
  end
  print('info: ' .. #bundles .. ' VST3 plugins installed, ' .. #bundlesToRead .. ' of them are read')

  progress:setPhase('Reading the plugins', 0.02, 0.98)
  local failedCount = 0
  for index, bundle in ipairs(bundlesToRead) do
    progress:setStatus('Reading ' .. getBundleName(bundle.path) .. ' (' .. index .. ' of ' .. #bundlesToRead .. ')')
    coroutine.yield()

    local entry = self:readBundle(bundle)
    entriesByPath[bundle.path] = entry
    if (entry.error ~= nil) then
      failedCount = failedCount + 1
      print('error: plugin migration data of ' .. bundle.path .. ' could not be read: ' .. entry.error)
    end

    if (index % SAVE_INTERVAL == 0) then
      self:save(entriesByPath)
    end
    progress:advancePhase(#bundlesToRead)
  end

  progress:setPhase('Writing the plugin migration data', 0.98, 1)
  coroutine.yield()
  self:save(entriesByPath)

  -- the read plugins are only a part, the state of the whole data matters
  local totalCount = 0
  local totalCompatibleCount = 0
  local totalFailedCount = 0
  for _, entry in pairs(entriesByPath) do
    totalCount = totalCount + 1
    if (entry.error ~= nil) then
      totalFailedCount = totalFailedCount + 1
    elseif (type(entry.compatibility) == 'table' and #entry.compatibility > 0) then
      totalCompatibleCount = totalCompatibleCount + 1
    end
  end

  print('info: plugin migration data written to ' .. self:getFilePath())
  print('info: ' .. #bundlesToRead .. ' plugins read, ' .. failedCount .. ' of them failed')
  print('info: ' .. totalCompatibleCount .. ' of ' .. totalCount .. ' plugins can replace other plugins, ' ..
    totalFailedCount .. ' could not be read')
end
