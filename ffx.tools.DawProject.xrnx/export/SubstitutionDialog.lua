-------------------------------------------------------------------------------
-- Substitution Dialog, the phase after the health check. Here you decide which
-- parts of Renoise are exported as plugin. An option is disabled, as long as its
-- plugin is not installed.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local DIALOG_TITLE = 'DAW Project - Plugin Substitutions'

local CHECKBOX_SIZE = 18
local CHECKBOX_COLUMN_WIDTH = 24
local DEVICE_COLUMN_WIDTH = 180
local COUNT_COLUMN_WIDTH = 50
local PLUGIN_COLUMN_WIDTH = 200
local STATUS_COLUMN_WIDTH = 90
local ACTION_COLUMN_WIDTH = 80
local LEADING_COLUMNS_WIDTH = CHECKBOX_COLUMN_WIDTH + DEVICE_COLUMN_WIDTH + COUNT_COLUMN_WIDTH
local TABLE_WIDTH = LEADING_COLUMNS_WIDTH + PLUGIN_COLUMN_WIDTH + STATUS_COLUMN_WIDTH + ACTION_COLUMN_WIDTH
local CONTINUE_BUTTON_WIDTH = 120
local CONTINUE_BUTTON_HEIGHT = 24
local OPTION_MARGIN = 3

local MAX_Q_FACTOR_OCTAVES = 2

local TRACK_DELAY_NOTES_HINT = 'Notes are moved'
local TRACK_DELAY_PLUGIN_HINT = 'Audio is delayed'

local HEADER_COLOR = { 160, 190, 215 }
local DEVICE_COLOR = { 225, 225, 225 }
local PLUGIN_COLOR = { 110, 195, 225 }
local INSTALLED_COLOR = { 90, 200, 90 }
local MISSING_COLOR = { 255, 170, 40 }
local DISABLED_COLOR = { 125, 125, 125 }
local CONTINUE_BUTTON_COLOR = { 60, 130, 80 }


local function formatQFactor(octaves)
  return string.format('x %.2f', 2 ^ octaves)
end


class "SubstitutionDialog"

function SubstitutionDialog:__init()
  self.dialog = nil
end

-- onOptionChanged gets the config key and the new value, onContinue starts the export
function SubstitutionDialog:start(options, config, onOptionChanged, onContinue)
  self:close()

  local vb = renoise.ViewBuilder()
  local tableView = vb:column {
    style = 'group',
    margin = 6,
    spacing = 4,
    self:createHeaderRow(vb),
  }

  for _, option in ipairs(options) do
    tableView:add_child(self:createOptionView(vb, option, config, onOptionChanged))
  end

  local contentView = vb:column {
    margin = 8,
    spacing = 8,
    vb:text {
      width = TABLE_WIDTH,
      text = 'A DAW can\'t load Renoise devices. Which parts should be exported as plugin?',
    },
    tableView,
    vb:horizontal_aligner {
      mode = 'right',
      vb:button {
        text = 'Continue',
        width = CONTINUE_BUTTON_WIDTH,
        height = CONTINUE_BUTTON_HEIGHT,
        color = CONTINUE_BUTTON_COLOR,
        notifier = function()
          self:close()
          onContinue()
        end,
      },
    },
  }

  self.dialog = renoise.app():show_custom_dialog(DIALOG_TITLE, contentView)
end

function SubstitutionDialog:createCell(vb, width, text, color, font)
  return vb:text {
    width = width,
    text = text,
    style = 'custom',
    color = color,
    font = font or 'normal',
  }
end

function SubstitutionDialog:createHeaderRow(vb)
  -- the same margin as the rows of the options, so the columns are aligned
  return vb:row {
    margin = OPTION_MARGIN,
    vb:space { width = CHECKBOX_COLUMN_WIDTH },
    self:createCell(vb, DEVICE_COLUMN_WIDTH, 'Renoise', HEADER_COLOR, 'bold'),
    self:createCell(vb, COUNT_COLUMN_WIDTH, 'Count', HEADER_COLOR, 'bold'),
    self:createCell(vb, PLUGIN_COLUMN_WIDTH, 'VST3 plugin', HEADER_COLOR, 'bold'),
    self:createCell(vb, STATUS_COLUMN_WIDTH, 'Status', HEADER_COLOR, 'bold'),
  }
end

function SubstitutionDialog:createOptionView(vb, option, config, onOptionChanged)
  local installedTargets = PluginSubstitutions:findInstalledTargets(option)
  local isInstalled = #installedTargets > 0

  local firstRow = vb:row {
    -- a row doesn't get wider than its content, so the column is filled up with a space
    vb:checkbox {
      width = CHECKBOX_SIZE,
      height = CHECKBOX_SIZE,
      value = isInstalled and config[option.configKey] == true,
      active = isInstalled,
      notifier = function(isEnabled) onOptionChanged(option.configKey, isEnabled) end,
    },
    vb:space { width = CHECKBOX_COLUMN_WIDTH - CHECKBOX_SIZE },
    self:createCell(vb, DEVICE_COLUMN_WIDTH, option.title, isInstalled and DEVICE_COLOR or DISABLED_COLOR),
    self:createCell(vb, COUNT_COLUMN_WIDTH, option.usageCount .. 'x', isInstalled and DEVICE_COLOR or DISABLED_COLOR),
  }

  local optionView = vb:column {
    style = 'plain',
    margin = OPTION_MARGIN,
    spacing = 2,
    firstRow,
  }

  if (isInstalled) then
    firstRow:add_child(self:createInstalledPluginCell(vb, option, installedTargets, config, onOptionChanged))
    firstRow:add_child(self:createCell(vb, STATUS_COLUMN_WIDTH, 'Installed', INSTALLED_COLOR))
    -- the column of the download button is empty here, but all the rows have the same width
    firstRow:add_child(vb:space { width = ACTION_COLUMN_WIDTH })
    if (option.qFactorConfigKey ~= nil) then
      optionView:add_child(self:createQFactorRow(vb, option, config, onOptionChanged))
    end
    if (option.hasTrackDelayTarget and PluginSubstitutions:isTrackDelayUsedInSong()) then
      optionView:add_child(self:createTrackDelayRow(vb, config, onOptionChanged))
    end
    self:addAlternativeTargetRows(vb, optionView, option)
    return optionView
  end

  for targetIndex, target in ipairs(option.targets) do
    self:addMissingTargetCells(vb, firstRow, optionView, target, targetIndex)
  end
  return optionView
end

-- Several installed plugins can be selected, a single one is only displayed
function SubstitutionDialog:createInstalledPluginCell(vb, option, installedTargets, config, onOptionChanged)
  if (#installedTargets == 1) then
    return self:createCell(vb, PLUGIN_COLUMN_WIDTH, installedTargets[1].pluginName, PLUGIN_COLOR)
  end

  local selectedTarget = PluginSubstitutions:findSelectedTarget(option, config)
  local pluginNames = {}
  local selectedIndex = 1

  for index, target in ipairs(installedTargets) do
    pluginNames[index] = target.pluginName
    if (target.classId == selectedTarget.classId) then
      selectedIndex = index
    end
  end

  return vb:popup {
    width = PLUGIN_COLUMN_WIDTH,
    items = pluginNames,
    value = selectedIndex,
    notifier = function(index)
      onOptionChanged(PluginSubstitutions:getTargetConfigKey(option), installedTargets[index].classId)
    end,
  }
end

-- The slider works in octaves, its value is displayed as the resulting factor of the Q
function SubstitutionDialog:createQFactorRow(vb, option, config, onOptionChanged)
  local octaves = config[option.qFactorConfigKey] or 0
  local valueView = self:createCell(vb, STATUS_COLUMN_WIDTH, formatQFactor(octaves), PLUGIN_COLOR)

  return vb:row {
    vb:space { width = CHECKBOX_COLUMN_WIDTH },
    self:createCell(vb, DEVICE_COLUMN_WIDTH + COUNT_COLUMN_WIDTH, 'Q factor', DEVICE_COLOR),
    vb:slider {
      width = PLUGIN_COLUMN_WIDTH,
      min = -MAX_Q_FACTOR_OCTAVES,
      max = MAX_Q_FACTOR_OCTAVES,
      value = octaves,
      default = 0,
      tooltip = 'Makes the filters narrower or wider. Double click to reset.',
      notifier = function(newOctaves)
        valueView.text = formatQFactor(newOctaves)
        onOptionChanged(option.qFactorConfigKey, newOctaves)
      end,
    },
    valueView,
    vb:space { width = ACTION_COLUMN_WIDTH },
  }
end

function SubstitutionDialog:createTrackDelayRow(vb, config, onOptionChanged)
  local isInPlugin = config[TRACK_DELAY_TARGET_CONFIG_KEY] == TRACK_DELAY_IN_PLUGIN
  local hintView = self:createCell(vb, STATUS_COLUMN_WIDTH + ACTION_COLUMN_WIDTH,
    isInPlugin and TRACK_DELAY_PLUGIN_HINT or TRACK_DELAY_NOTES_HINT, DISABLED_COLOR)

  return vb:row {
    vb:space { width = CHECKBOX_COLUMN_WIDTH },
    self:createCell(vb, DEVICE_COLUMN_WIDTH + COUNT_COLUMN_WIDTH, 'Track delay', DEVICE_COLOR),
    vb:popup {
      width = PLUGIN_COLUMN_WIDTH,
      items = { 'Shift MIDI notes', 'MUtility delay' },
      value = isInPlugin and 2 or 1,
      tooltip = 'Shift MIDI notes: The notes in the DAW are moved by the delay of the track.\n' ..
          'MUtility delay: The notes stay in place, a plugin delays the audio of the track.',
      notifier = function(index)
        local isPluginSelected = index == 2
        hintView.text = isPluginSelected and TRACK_DELAY_PLUGIN_HINT or TRACK_DELAY_NOTES_HINT
        onOptionChanged(TRACK_DELAY_TARGET_CONFIG_KEY, isPluginSelected and TRACK_DELAY_IN_PLUGIN or TRACK_DELAY_IN_CLIPS)
      end,
    },
    hintView,
  }
end

function SubstitutionDialog:addMissingTargetInfo(vb, targetRow, target)
  targetRow:add_child(self:createCell(vb, PLUGIN_COLUMN_WIDTH, target.pluginName, DISABLED_COLOR))
  targetRow:add_child(self:createCell(vb, STATUS_COLUMN_WIDTH, 'Not installed', MISSING_COLOR))
  targetRow:add_child(vb:button {
    text = 'Download',
    width = ACTION_COLUMN_WIDTH,
    tooltip = target.downloadUrl,
    notifier = function() renoise.app():open_url(target.downloadUrl) end,
  })
end

-- Shows the plugins that could be used additionally, if they were installed
function SubstitutionDialog:addAlternativeTargetRows(vb, optionView, option)
  for _, target in ipairs(option.targets) do
    if (not PluginSubstitutions:isPluginInstalled(target.classId)) then
      local targetRow = vb:row { vb:space { width = LEADING_COLUMNS_WIDTH } }
      self:addMissingTargetInfo(vb, targetRow, target)
      optionView:add_child(targetRow)
    end
  end
end

-- The first target is displayed in the row of the option, the others below it
function SubstitutionDialog:addMissingTargetCells(vb, firstRow, optionView, target, targetIndex)
  local targetRow = firstRow
  local indentWidth = LEADING_COLUMNS_WIDTH

  if (targetIndex > 1) then
    targetRow = vb:row { vb:space { width = indentWidth } }
    optionView:add_child(targetRow)
  end

  self:addMissingTargetInfo(vb, targetRow, target)

  optionView:add_child(vb:row {
    vb:space { width = indentWidth },
    self:createCell(vb, PLUGIN_COLUMN_WIDTH + STATUS_COLUMN_WIDTH + ACTION_COLUMN_WIDTH,
      'Please install it from: ' .. target.downloadUrl, DISABLED_COLOR),
  })
end

function SubstitutionDialog:close()
  if (self.dialog ~= nil and self.dialog.visible) then
    self.dialog:close()
  end
  self.dialog = nil
end
