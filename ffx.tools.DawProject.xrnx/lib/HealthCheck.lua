-------------------------------------------------------------------------------
-- Health Check, finds out if everything an export needs is working. Each check
-- returns a result with a status, a message and instructions for fixing it.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('lib/HealthCheckFixes')

-- The command line length is limited, especially on Windows
local MAX_PATHS_PER_TOOL_RUN = 20

HealthCheckStatus = {
  OK = 'ok',
  WARNING = 'warning',
  FAILED = 'failed',
}

local function okResult(message)
  return { status = HealthCheckStatus.OK, message = message }
end

local function warningResult(message, fix)
  return { status = HealthCheckStatus.WARNING, message = message, fix = fix }
end

local function failedResult(message, fix)
  return { status = HealthCheckStatus.FAILED, message = message, fix = fix }
end

-- The export can't work at all without the things checked with this result
local function blockingResult(message, fix)
  local result = failedResult(message, fix)
  result.isBlocking = true
  return result
end


class "HealthCheck"

function HealthCheck:__init(config)
  self.config = config
end

-- Returns a list of checks, each with a title and a run function returning the result
function HealthCheck:createChecks()
  local checks = {
    { title = 'Temporary directory', run = function() return self:checkTempDirectory() end },
    { title = 'Packing command',     run = function() return self:checkPackCommand() end },
  }

  local enabledFormats = self:getEnabledPluginFormats()
  if (#enabledFormats == 0) then
    return checks
  end

  local usage = self:collectInfoToolUsage(enabledFormats)

  table.insert(checks, {
    title = 'Renoise plugin database',
    run = function() return self:checkPluginDatabases(enabledFormats) end,
  })

  for _, toolName in ipairs(usage.toolNames) do
    table.insert(checks, {
      title = 'Helper tool ' .. toolName,
      run = function() return self:checkInfoTool(toolName, usage.filePathsByTool[toolName]) end,
    })
  end

  if (#usage.unreadablePlugins > 0) then
    table.insert(checks, {
      title = 'Bridged plugins',
      run = function()
        return warningResult(
          'These plugins can not be read:\n' .. table.concat(usage.unreadablePlugins, '\n'),
          HealthCheckFixes:getBridgedPluginFix()
        )
      end,
    })
  end

  return checks
end

function HealthCheck:getEnabledPluginFormats()
  local formats = {}
  if (self.config.exportVST2 == true and self.config.useVST2InfoTool == true) then
    table.insert(formats, 'vst2')
  end
  if (self.config.exportVST3 == true and self.config.useVST3InfoTool == true) then
    table.insert(formats, 'vst3')
  end
  return formats
end

function HealthCheck:getSongPluginDevices()
  local devices = {}

  for _, instrument in ipairs(Song.instruments) do
    local pluginDevice = instrument.plugin_properties.plugin_device
    if (pluginDevice ~= nil) then
      table.insert(devices, pluginDevice)
    end
  end

  for _, track in ipairs(Song.tracks) do
    for _, device in ipairs(track.devices) do
      if (DeviceHelpers:getPluginFormat(device.device_path) ~= nil) then
        table.insert(devices, device)
      end
    end
  end

  return devices
end

-- Finds out which tool binaries are required, and which plugin files they have to access.
-- The native tools are always checked. Plugins of a disabled format are skipped.
function HealthCheck:collectInfoToolUsage(enabledFormats)
  local usage = { toolNames = {}, filePathsByTool = {}, unreadablePlugins = {} }

  local addTool = function(toolName)
    if (usage.filePathsByTool[toolName] == nil) then
      usage.filePathsByTool[toolName] = {}
      table.insert(usage.toolNames, toolName)
    end
  end

  for _, pluginFormat in ipairs(enabledFormats) do
    addTool(DeviceHelpers:getInfoToolName(pluginFormat, false))
  end

  local checkedPlugins = {}
  local addedFilePaths = {}

  for _, device in ipairs(self:getSongPluginDevices()) do
    local pluginFormat = DeviceHelpers:getPluginFormat(device.device_path)
    local isFormatEnabled = pluginFormat ~= nil and Helpers:tableContains(enabledFormats, pluginFormat)

    if (isFormatEnabled and not checkedPlugins[device.device_path]) then
      checkedPlugins[device.device_path] = true

      local toolName = DeviceHelpers:getInfoToolName(pluginFormat, DeviceHelpers:isPluginBridged(device))
      local filePath = DeviceHelpers:findPluginFilePath(device.device_path)

      if (toolName == nil) then
        table.insert(usage.unreadablePlugins, device.device_path)
      elseif (filePath ~= nil) then
        addTool(toolName)
        -- all the plugins of a shell are in the same file
        if (not addedFilePaths[toolName .. filePath]) then
          addedFilePaths[toolName .. filePath] = true
          table.insert(usage.filePathsByTool[toolName], filePath)
        end
      end
    end
  end

  return usage
end

function HealthCheck:checkTempDirectory()
  local testFilePath = TempDir .. '/healthcheck.tmp'

  os.mkdir(TempDir)
  local testFile = io.open(testFilePath, 'wb')
  if (testFile == nil) then
    return blockingResult(
      'Can not write into the temporary directory of the tool.',
      HealthCheckFixes:getTempDirectoryFix()
    )
  end
  testFile:close()
  os.remove(testFilePath)

  return okResult('The temporary directory is writable.')
end

function HealthCheck:checkPackCommand()
  -- Only the bsdtar of macOS and Windows can create zip files
  local command, expectedOutput = 'tar --version 2>&1', 'bsdtar'
  if (Helpers:getShortOSString() == 'linux') then
    command, expectedOutput = 'zip -v 2>&1', 'Info-ZIP'
  end

  local commandOutput = Helpers:captureConsole(command)
  if (string.find(commandOutput, expectedOutput, 1, true) == nil) then
    return blockingResult(
      'The command for packing the .dawproject file is not available:\n' .. commandOutput,
      HealthCheckFixes:getPackCommandFix()
    )
  end

  return okResult('The packing command is available.')
end

function HealthCheck:checkPluginDatabases(enabledFormats)
  for _, pluginFormat in ipairs(enabledFormats) do
    local databasePath = DeviceHelpers:getPluginDatabasePath(pluginFormat)

    if (databasePath == nil or not io.exists(databasePath)) then
      return warningResult(
        'The plugin database of Renoise was not found: ' .. tostring(databasePath),
        HealthCheckFixes:getPluginDatabaseFix()
      )
    end

    local database = renoise.SQLite.open(databasePath, 'ro')
    if (database == nil) then
      return warningResult(
        'The plugin database of Renoise can not be opened: ' .. databasePath,
        HealthCheckFixes:getPluginDatabaseFix()
      )
    end
    database:close()
  end

  return okResult('The plugin database is readable.')
end

function HealthCheck:checkInfoTool(toolName, filePaths)
  if (not io.exists('./bin/' .. toolName)) then
    return failedResult('The helper tool does not exist: bin/' .. toolName, HealthCheckFixes:getMissingToolFix())
  end

  local inaccessiblePlugins = {}
  local firstPathIndex = 1

  repeat
    local pathsOfRun = {}
    for index = firstPathIndex, math.min(firstPathIndex + MAX_PATHS_PER_TOOL_RUN - 1, #filePaths) do
      table.insert(pathsOfRun, filePaths[index])
    end
    firstPathIndex = firstPathIndex + MAX_PATHS_PER_TOOL_RUN

    local report, problem, toolOutput = DeviceHelpers:runInfoToolHealthcheck(toolName, pathsOfRun)

    if (report == nil) then
      return failedResult(
        toolName .. ' can not be started. ' .. problem .. '. Output of the system:\n' ..
        (toolOutput ~= '' and toolOutput or '(none, the system probably stopped the tool)'),
        HealthCheckFixes:getCannotStartFix(toolName, toolOutput)
      )
    end

    -- A tool without the health check treats the switch as a plugin path
    if (report['plugins'] == nil) then
      return failedResult(
        toolName .. ' does not support the health check: ' .. tostring(report['error']),
        HealthCheckFixes:getMissingToolFix()
      )
    end

    for _, plugin in ipairs(report['plugins']) do
      if (not plugin['accessible']) then
        table.insert(inaccessiblePlugins, plugin['path'] .. ': ' .. tostring(plugin['error']))
      end
    end
  until firstPathIndex > #filePaths

  if (#inaccessiblePlugins > 0) then
    return warningResult(
      toolName .. ' can not access these plugins:\n' .. table.concat(inaccessiblePlugins, '\n'),
      HealthCheckFixes:getPluginAccessFix()
    )
  end

  return okResult(toolName .. ' is working and can access all ' .. #filePaths .. ' plugin files.')
end
