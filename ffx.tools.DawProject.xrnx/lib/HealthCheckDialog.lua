-------------------------------------------------------------------------------
-- Health Check Dialog, runs the checks one after the other before an export.
-- If all of them pass, it closes and the export continues right away. Otherwise
-- it stays open and shows how to fix the problems on the current system.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local DIALOG_TITLE = 'DAW Project - Health Check'
local DIALOG_WIDTH = 560
local STATUS_WIDTH = 70
local BUTTON_WIDTH = 100
local DETAILS_HEIGHT = 240
local TIMER_INTERVAL_MS = 30

local PENDING_COLOR = { 150, 150, 150 }
local OK_COLOR = { 90, 200, 90 }
local WARNING_COLOR = { 255, 170, 40 }
local FAILED_COLOR = { 255, 80, 80 }

local STATUS_DISPLAYS = {
  [HealthCheckStatus.OK] = { text = 'OK', color = OK_COLOR },
  [HealthCheckStatus.WARNING] = { text = 'Warning', color = WARNING_COLOR },
  [HealthCheckStatus.FAILED] = { text = 'Failed', color = FAILED_COLOR },
}


class "HealthCheckDialog"

function HealthCheckDialog:__init()
  self.dialog = nil
  self.checks = {}
  self.statusViews = {}
  self.results = {}
  self.nextCheckIndex = 1
  self.onContinue = nil
  self.onTimer = function()
    self:update()
  end
end

-- Shows the dialog and runs the checks. onContinue is called, as soon as the export can start.
function HealthCheckDialog:start(checks, onContinue)
  self:close()

  self.checks = checks
  self.onContinue = onContinue

  local vb = renoise.ViewBuilder()

  self.checksView = vb:column { spacing = 2 }
  self.statusViews = {}
  for index, check in ipairs(checks) do
    self.statusViews[index] = vb:text {
      width = STATUS_WIDTH,
      font = 'bold',
      style = 'custom',
      color = PENDING_COLOR,
    }
    self.checksView:add_child(vb:row {
      self.statusViews[index],
      vb:text { width = DIALOG_WIDTH - STATUS_WIDTH, text = check.title },
    })
  end

  self.detailsView = vb:multiline_textfield {
    width = DIALOG_WIDTH,
    height = DETAILS_HEIGHT,
    font = 'mono',
    visible = false,
  }
  self.retryButton = vb:button {
    text = 'Check again',
    width = BUTTON_WIDTH,
    visible = false,
    notifier = function() self:restartChecks() end,
  }
  self.continueButton = vb:button {
    text = 'Export anyway',
    width = BUTTON_WIDTH,
    visible = false,
    notifier = function() self:continue() end,
  }
  self.cancelButton = vb:button {
    text = 'Cancel',
    width = BUTTON_WIDTH,
    notifier = function() self:close() end,
  }

  self.contentView = vb:column {
    margin = 8,
    spacing = 6,
    self.checksView,
    self.detailsView,
    vb:row {
      spacing = 4,
      self.cancelButton,
      self.retryButton,
      self.continueButton,
    },
  }

  self.dialog = renoise.app():show_custom_dialog(DIALOG_TITLE, self.contentView)
  self:restartChecks()
end

function HealthCheckDialog:restartChecks()
  self.results = {}
  self.nextCheckIndex = 1

  for _, statusView in ipairs(self.statusViews) do
    statusView.text = '...'
    statusView.color = PENDING_COLOR
  end

  self.detailsView.visible = false
  self.retryButton.visible = false
  self.continueButton.visible = false
  self.contentView:resize()

  if (not renoise.tool():has_timer(self.onTimer)) then
    renoise.tool():add_timer(self.onTimer, TIMER_INTERVAL_MS)
  end
end

function HealthCheckDialog:update()
  if (self.dialog == nil or not self.dialog.visible) then
    self:close()
    return
  end

  local check = self.checks[self.nextCheckIndex]
  if (check == nil) then
    self:finishChecks()
    return
  end

  local result = self:runCheck(check)
  self.results[self.nextCheckIndex] = result

  local statusDisplay = STATUS_DISPLAYS[result.status]
  self.statusViews[self.nextCheckIndex].text = statusDisplay.text
  self.statusViews[self.nextCheckIndex].color = statusDisplay.color

  self.nextCheckIndex = self.nextCheckIndex + 1
end

-- A bug in a check must not keep the user from exporting
function HealthCheckDialog:runCheck(check)
  local success, result = pcall(check.run)
  if (success) then
    return result
  end
  return {
    status = HealthCheckStatus.WARNING,
    message = 'The check itself failed: ' .. tostring(result),
    fix = { 'Please report this in the Renoise forum.' },
  }
end

function HealthCheckDialog:finishChecks()
  self:stopTimer()

  local hasProblems = false
  local hasBlockingProblems = false
  for _, result in ipairs(self.results) do
    hasProblems = hasProblems or result.status ~= HealthCheckStatus.OK
    hasBlockingProblems = hasBlockingProblems or result.isBlocking == true
  end

  if (not hasProblems) then
    self:continue()
    return
  end

  self:showDetails()
  self.retryButton.visible = true
  self.continueButton.visible = not hasBlockingProblems
  self.contentView:resize()
end

-- The instructions are shown in a text field, so they can be selected and copied
function HealthCheckDialog:showDetails()
  self.detailsView:clear()

  for index, result in ipairs(self.results) do
    if (result.status ~= HealthCheckStatus.OK) then
      self.detailsView:add_line('--- ' .. self.checks[index].title .. ' ---')
      self.detailsView:add_line(result.message)
      self.detailsView:add_line('')
      self.detailsView:add_line('How to fix it:')
      for _, line in ipairs(result.fix or {}) do
        self.detailsView:add_line(line)
      end
      self.detailsView:add_line('')
    end
  end

  self.detailsView.visible = true
  self.detailsView:scroll_to_first_line()
end

function HealthCheckDialog:continue()
  local onContinue = self.onContinue
  self:close()
  if (onContinue ~= nil) then
    onContinue()
  end
end

function HealthCheckDialog:stopTimer()
  if (renoise.tool():has_timer(self.onTimer)) then
    renoise.tool():remove_timer(self.onTimer)
  end
end

function HealthCheckDialog:close()
  self:stopTimer()
  if (self.dialog ~= nil and self.dialog.visible) then
    self.dialog:close()
  end
  self.dialog = nil
  self.onContinue = nil
end
