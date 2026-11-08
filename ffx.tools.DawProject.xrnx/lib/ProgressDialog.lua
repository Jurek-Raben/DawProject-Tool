-------------------------------------------------------------------------------
-- Progress Dialog, shows the state of a long running process with a progress
-- bar, a cancel button and an expandable log of the console messages.
-- It is not a blocking dialog, since that would also block the ProcessSlicer.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local DIALOG_TITLE = 'DAW Project'
local DIALOG_WIDTH = 560
local PERCENTAGE_WIDTH = 40
local LOG_HEIGHT = 280
local TIMER_INTERVAL_MS = 100
local TIMER_TICKS_PER_ANIMATION_STEP = 4
local NUM_ANIMATION_DOTS = 3
local PROBLEMS_HEIGHT = 110
local WARNING_COLOR = { 255, 170, 40 }
local ERROR_COLOR = { 255, 80, 80 }

-- Text views grow with their text, which would change the layout of the dialog
local MAX_STATUS_LENGTH = 80

local activeDialog = nil

local function truncateText(text, maxLength)
  if (string.len(text) <= maxLength) then
    return text
  end
  return string.sub(text, 1, maxLength - 3) .. '...'
end

-- All messages also end up in the log of the currently active dialog
local consolePrint = print
print = function(...)
  consolePrint(...)

  if (activeDialog ~= nil) then
    local parts = {}
    for index = 1, select('#', ...) do
      parts[index] = tostring(select(index, ...))
    end
    activeDialog:addLogMessage(table.concat(parts, '  '))
  end
end


class "ProgressDialog"

function ProgressDialog:__init()
  self.dialog = nil
  self.running = false
  self.onCancel = nil
  self.pendingLogLines = {}
  self.problems = {}
  self.pendingProblemLines = {}
  self.hasErrors = false
  self.hasOpenedLogForErrors = false
  self.phaseStart = 0
  self.phaseEnd = 1
  self.phaseSteps = 0
  self.status = ''
  self.progress = 0
  self.animationDots = 1
  self.animationTicks = 0
  self.onTimer = function()
    self:update()
  end
end

-- Shows the dialog. onCancel is called, when the user cancels or closes the running process.
function ProgressDialog:start(title, onCancel)
  self:close()

  self.running = true
  self.onCancel = onCancel
  self.pendingLogLines = {}
  self.problems = {}
  self.pendingProblemLines = {}
  self.hasErrors = false
  self.hasOpenedLogForErrors = false
  self.phaseStart = 0
  self.phaseEnd = 1
  self.phaseSteps = 0
  self.status = 'Starting'
  self.progress = 0
  self.animationDots = 1
  self.animationTicks = 0

  local vb = renoise.ViewBuilder()

  self.statusView = vb:text {
    width = DIALOG_WIDTH - PERCENTAGE_WIDTH,
  }
  self.percentageView = vb:text {
    width = PERCENTAGE_WIDTH,
    align = 'right',
  }
  self.progressView = vb:minislider {
    min = 0,
    max = 1,
    value = 0,
    active = false,
    width = DIALOG_WIDTH,
    height = 14,
  }
  self.actionButton = vb:button {
    text = 'Cancel',
    width = 80,
    notifier = function()
      if (self.running) then
        self:cancel()
      else
        self:close()
      end
    end,
  }
  self.logToggleButton = vb:button {
    text = 'Show log',
    width = 80,
    notifier = function()
      self:setLogVisible(not self.logView.visible)
    end,
  }
  self.logView = vb:multiline_textfield {
    width = DIALOG_WIDTH,
    height = LOG_HEIGHT,
    font = 'mono',
    style = 'border',
    visible = false,
  }

  -- A multiline field can be scrolled and selected, but can't color its lines.
  -- So the color of the header shows the most severe problem.
  self.problemsHeaderView = vb:text {
    width = DIALOG_WIDTH,
    font = 'bold',
    style = 'custom',
    color = WARNING_COLOR,
  }
  self.problemLinesView = vb:multiline_textfield {
    width = DIALOG_WIDTH,
    height = PROBLEMS_HEIGHT,
    font = 'mono',
  }
  self.problemsView = vb:column {
    visible = false,
    self.problemsHeaderView,
    self.problemLinesView,
  }

  self.contentView = vb:column {
    margin = 8,
    spacing = 6,
    vb:row {
      self.statusView,
      self.percentageView,
    },
    self.progressView,
    vb:row {
      spacing = 4,
      self.logToggleButton,
      vb:space { width = DIALOG_WIDTH - 2 * 80 - 2 * 4 },
      self.actionButton,
    },
    self.problemsView,
    self.logView,
  }

  self:updateStatusView()
  self:updateProblemViews()

  self.dialog = renoise.app():show_custom_dialog(DIALOG_TITLE .. ' - ' .. title .. '...', self.contentView)
  activeDialog = self
  renoise.tool():add_timer(self.onTimer, TIMER_INTERVAL_MS)
end

-- A phase is a part of the whole progress, from startFraction to endFraction (0 to 1)
function ProgressDialog:setPhase(status, startFraction, endFraction)
  self.phaseStart = startFraction
  self.phaseEnd = endFraction
  self.phaseSteps = 0
  self:setStatus(status)
  self:setProgress(startFraction)
end

function ProgressDialog:setPhaseProgress(fraction)
  self:setProgress(self.phaseStart + (self.phaseEnd - self.phaseStart) * math.min(fraction, 1))
end

-- Advances the current phase by one of totalSteps steps
function ProgressDialog:advancePhase(totalSteps)
  self.phaseSteps = self.phaseSteps + 1
  self:setPhaseProgress(self.phaseSteps / totalSteps)
end

function ProgressDialog:setStatus(status)
  self.status = status
  self:updateStatusView()
end

function ProgressDialog:setProgress(fraction)
  self.progress = math.max(0, math.min(fraction, 1))
  if (self.progressView ~= nil) then
    self.progressView.value = self.progress
  end
  self:updateStatusView()
end

-- While running, the status has animated dots and the percentage is shown above the end of the progress bar
function ProgressDialog:updateStatusView()
  if (self.statusView == nil) then
    return
  end
  if (self.running) then
    self.statusView.text = truncateText(self.status, MAX_STATUS_LENGTH) .. string.rep('.', self.animationDots)
    self.percentageView.text = math.floor(self.progress * 100) .. '%'
  else
    self.statusView.text = truncateText(self.status, MAX_STATUS_LENGTH)
    self.percentageView.text = ''
  end
end

function ProgressDialog:advanceAnimation()
  self.animationTicks = self.animationTicks + 1
  if (self.animationTicks >= TIMER_TICKS_PER_ANIMATION_STEP) then
    self.animationTicks = 0
    self.animationDots = self.animationDots % NUM_ANIMATION_DOTS + 1
    self:updateStatusView()
  end
end

function ProgressDialog:addLogMessage(message)
  local isError = string.find(message, '^error:') ~= nil
  if (isError or string.find(message, '^warning:') ~= nil) then
    table.insert(self.problems, message)
    table.insert(self.pendingProblemLines, message)
    self.hasErrors = self.hasErrors or isError
  end
  table.insert(self.pendingLogLines, message)
end

function ProgressDialog:setLogVisible(isVisible)
  self.logView.visible = isVisible
  self.logToggleButton.text = isVisible and 'Hide log' or 'Show log'
  self:updateProblemViews()
  if (isVisible) then
    self.logView:scroll_to_last_line()
  end
end

-- Shows the warnings and errors above the log, as soon as there are any
function ProgressDialog:updateProblemViews()
  self.problemsHeaderView.text = 'Warnings and errors: ' .. #self.problems
  self.problemsHeaderView.color = self.hasErrors and ERROR_COLOR or WARNING_COLOR

  if (#self.pendingProblemLines > 0) then
    for _, line in ipairs(self.pendingProblemLines) do
      self.problemLinesView:add_line(line)
    end
    self.pendingProblemLines = {}
    self.problemLinesView:scroll_to_last_line()
  end

  self.problemsView.visible = #self.problems > 0
  self.contentView:resize()
end

function ProgressDialog:flushLog()
  if (self.logView == nil or #self.pendingLogLines == 0) then
    return
  end
  for _, line in ipairs(self.pendingLogLines) do
    self.logView:add_line(line)
  end
  self.pendingLogLines = {}
  self.logView:scroll_to_last_line()
  self:updateProblemViews()

  -- An error is explained by the messages around it, so the log opens by itself once
  if (self.hasErrors and not self.hasOpenedLogForErrors) then
    self.hasOpenedLogForErrors = true
    self:setLogVisible(true)
  end
end

function ProgressDialog:update()
  if (self.dialog ~= nil and not self.dialog.visible) then
    -- closed with the window button
    if (self.running) then
      self:cancel()
    end
    self:close()
    return
  end
  self:flushLog()
  self:advanceAnimation()
end

function ProgressDialog:stopTimer()
  if (renoise.tool():has_timer(self.onTimer)) then
    renoise.tool():remove_timer(self.onTimer)
  end
end

-- Shows the final state. The dialog stays open, so the log can still be read.
function ProgressDialog:finish(status)
  self:flushLog()
  self:stopTimer()
  self.running = false
  activeDialog = nil

  if (#self.problems > 0) then
    status = status .. ' (' .. #self.problems .. ' warnings)'
  end
  self:setProgress(1)
  self:setStatus(status)
  self.actionButton.text = 'Close'
end

-- Closes the finished dialog after some seconds, e.g. after a job the user didn't start.
-- It stays open with errors, and when another job uses the dialog in the meantime.
function ProgressDialog:closeAfterDelay(seconds)
  if (self.hasErrors) then
    return
  end
  local dialog = self.dialog
  local closeTimer
  closeTimer = function()
    renoise.tool():remove_timer(closeTimer)
    if (not self.running and self.dialog == dialog and self.dialog ~= nil) then
      self:close()
    end
  end
  renoise.tool():add_timer(closeTimer, seconds * 1000)
end

function ProgressDialog:fail(status, errorMessage)
  print('error: ' .. errorMessage)
  self:flushLog()
  self:stopTimer()
  self.running = false
  activeDialog = nil

  self:setStatus(status)
  self.actionButton.text = 'Close'
  self:setLogVisible(true)
end

function ProgressDialog:cancel()
  local onCancel = self.onCancel
  self:close()
  if (onCancel ~= nil) then
    onCancel()
  end
end

function ProgressDialog:close()
  self:stopTimer()
  self.running = false
  if (activeDialog == self) then
    activeDialog = nil
  end
  if (self.dialog ~= nil and self.dialog.visible) then
    self.dialog:close()
  end
  self.dialog = nil
  self.statusView = nil
  self.percentageView = nil
  self.progressView = nil
  self.logView = nil
  self.problemsView = nil
  self.problemsHeaderView = nil
  self.problemLinesView = nil
  self.actionButton = nil
  self.logToggleButton = nil
  self.contentView = nil
end
