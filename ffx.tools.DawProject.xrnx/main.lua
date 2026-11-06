-- @build:skip-start
_AUTO_RELOAD_DEBUG = function()
end
-- @build:skip-end
--------------------------------------------------------------------------------
-- Daw Project Export
-- by Jurek Raben
-- v@build:version@ (inserted from manifest.xml by the GitHub build)
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
--------------------------------------------------------------------------------

package.path = "lib/xml2lua/?.lua;" .. package.path
require('lib/lib-configurator')
require('lib/ToolConfig')
require('lib/ProgressDialog')
require('lib/ProcessSlicer')
require('lib/BackgroundTask')
require('lib/NoteAbstraction')
require('lib/GeneralHelpers')
require('lib/SongHelpers')
require('lib/DeviceHelpers')
require('lib/ReduxPluginHelpers')
require('lib/Cache')
require('lib/ProjectFiles')
require('lib/MeldaPreset')
require('lib/HealthCheck')
require('lib/HealthCheckDialog')
require('export/DawProjectExporter')
require('export/SubstitutionDialog')
require('import/DawProjectImporter')


--------------------------------------------------------------------------------
-- Global helpers
--------------------------------------------------------------------------------

Song = renoise.song() -- needs a refresh later
Tool = renoise.tool()
local progressDialog = nil
local healthCheckDialog = nil
local substitutionDialog = nil
local backgroundTask = nil
local config = {}


--------------------------------------------------------------------------------

class "DawProject"

DawProject.configurator = nil


--------------------------------------------------------------------------------
-- Main calls
--------------------------------------------------------------------------------

function DawProject:export()
  backgroundTask:stop()

  -- A bug while preparing the health check must not keep the user from exporting
  local success, checks = pcall(function()
    return HealthCheck(config):createChecks()
  end)
  if (not success) then
    print('warning: Health check could not be prepared', checks)
    self:configureSubstitutions()
    return
  end

  healthCheckDialog:start(checks, function() self:configureSubstitutions() end)
end

function DawProject:configureSubstitutions()
  -- nothing to choose on this operating system
  if (#SubstitutionTable:getOptionsOfCurrentSystem() == 0) then
    self:startExport()
    return
  end

  substitutionDialog:start(
    config,
    function(configKey, isEnabled)
      config[configKey] = isEnabled
      self.configurator:setConfig(config)
    end,
    function() self:startExport() end
  )
end

function DawProject:startExport()
  ProjectFiles:clearTempDirectory()

  local filePath = renoise.app():prompt_for_filename_to_write('dawproject', 'Export to dawproject...')
  if filePath == '' then
    return
  end

  local fileName = filePath:match('([^/\\]+)$') or filePath
  backgroundTask:run(
    "Exporting '" .. fileName .. "'",
    function() DawProjectExporter(config, progressDialog):export(filePath) end,
    'Export done!',
    'Export failed!'
  )
end

function DawProject:import()
  backgroundTask:stop()
  DawProjectImporter():import()
end

function DawProject:convertCurrentInstrumentToRedux()
  backgroundTask:stop()
  ProjectFiles:clearTempDirectory()
  ReduxPluginHelpers:convertCurrentInstrumentToRedux()
end

function DawProject:convertAllInstrumentsToRedux()
  backgroundTask:stop()
  ProjectFiles:clearTempDirectory()
  backgroundTask:run(
    'Converting to Redux',
    function()
      Song:describe_batch_undo('Convert all sample instruments to Redux', 10000)
      for index = 1, #Song.instruments do
        coroutine.yield()
        progressDialog:setStatus('Converting instrument #' .. index .. ' of ' .. #Song.instruments .. ' to Redux')
        progressDialog:setProgress((index - 1) / #Song.instruments)
        Song.selected_instrument_index = index
        ReduxPluginHelpers:convertCurrentInstrumentToRedux()
      end
    end,
    'Conversion done!',
    'Conversion failed!'
  )
end

function DawProject:repack()
  local filePath = renoise.app():prompt_for_filename_to_write('dawproject', 'Repack .dawproject...')
  if filePath == '' then
    return
  end
  ProjectFiles:packTempDirectory(filePath)
end


--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function DawProject:__init()
  local instrSwitchListener = function()
    if (config['convertToRedux'] == nil or Song.selected_instrument.plugin_properties.plugin_device ~= nil or #Song.selected_instrument.samples == 0) then
      MenuEntry:remove("Instrument Box:Convert to Redux")
    else
      MenuEntry:add("Instrument Box:Convert to Redux", function() self:convertCurrentInstrumentToRedux() end)
    end
  end

  local refreshMenus = function()
    MenuEntry:remove("Main Menu:Song:Convert all sample instruments to Redux")
    MenuEntry:remove("Main Menu:File:Repack .dawproject...")
    if (config['convertToRedux'] ~= nil) then
      MenuEntry:add("Main Menu:Song:Convert all sample instruments to Redux", function()
        self:convertAllInstrumentsToRedux()
      end)
    end

    if (config.devMode == true) then
      MenuEntry:add("Main Menu:File:Repack .dawproject...", function() self:repack() end)
    end
  end

  local toolIdle
  toolIdle = function()
    Notifiers:remove(Tool.app_idle_observable, toolIdle)

    if (not ReduxPluginHelpers:isReduxVST3Available()) then
      ToolConfig.defaults.convertToRedux = nil
    end

    self.configurator = LibConfigurator(LibConfigurator.SAVE_MODE.FILE, ToolConfig.defaults, "config.json")
    config = self.configurator:getConfig()

    self.configurator:addMenu("ffx.tools.DawProject", ToolConfig.descriptions,
      function(newConfig)
        config = newConfig
        refreshMenus()
      end
    )

    Tool:add_keybinding {
      name = "Global:Tools:Export to .dawproject...",
      invoke = function() self:export() end
    }

    -- TODO import
    --Tool:add_keybinding {
    --  name = "Global:Tools:Import .dawproject...",
    --  invoke = function() self:import() end
    --}

    MenuEntry:add("Main Menu:File:Export Song to .dawproject...", function() self:export() end)

    -- TODO import
    -- MenuEntry:add("Main Menu:File:Import .dawproject Song...", function() self:import() end)

    refreshMenus()
  end


  local newDocumentListener = function()
    Song = renoise.song()
    renoise.song()
    Notifiers:add(Song.selected_instrument_index_observable, instrSwitchListener)
  end

  local releaseDocumentListener = function()
    Song = renoise.song()
    backgroundTask:stop()
    progressDialog:close()
    healthCheckDialog:close()
    substitutionDialog:close()
    Notifiers:remove(Song.selected_instrument_index_observable, instrSwitchListener)
  end

  progressDialog = ProgressDialog()
  healthCheckDialog = HealthCheckDialog()
  substitutionDialog = SubstitutionDialog()
  backgroundTask = BackgroundTask(progressDialog)

  Notifiers:add(Tool.app_idle_observable, toolIdle)
  Notifiers:add(Tool.app_new_document_observable, newDocumentListener)
  Notifiers:add(Tool.app_release_document_observable, releaseDocumentListener)
end

DawProject()
