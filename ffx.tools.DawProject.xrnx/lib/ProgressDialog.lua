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
local LOG_HEIGHT = 280
local TIMER_INTERVAL_MS = 100

local activeDialog = nil

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
  self.warningCount = 0
  self.phaseStart = 0
  self.phaseEnd = 1
  self.phaseSteps = 0
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
  self.warningCount = 0
  self.phaseStart = 0
  self.phaseEnd = 1
  self.phaseSteps = 0

  local vb = renoise.ViewBuilder()

  self.statusView = vb:text {
    text = title .. '...',
    width = DIALOG_WIDTH,
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
  self.contentView = vb:column {
    margin = 8,
    spacing = 6,
    self.statusView,
    self.progressView,
    vb:row {
      spacing = 4,
      self.logToggleButton,
      vb:space { width = DIALOG_WIDTH - 2 * 80 - 2 * 4 },
      self.actionButton,
    },
    self.logView,
  }

  self.dialog = renoise.app():show_custom_dialog(DIALOG_TITLE .. ' - ' .. title, self.contentView)
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
  if (self.statusView ~= nil) then
    self.statusView.text = status
  end
end

function ProgressDialog:setProgress(fraction)
  if (self.progressView ~= nil) then
    self.progressView.value = math.max(0, math.min(fraction, 1))
  end
end

function ProgressDialog:addLogMessage(message)
  if (string.find(message, '^warning:') ~= nil or string.find(message, '^error:') ~= nil) then
    self.warningCount = self.warningCount + 1
  end
  table.insert(self.pendingLogLines, message)
end

function ProgressDialog:setLogVisible(isVisible)
  self.logView.visible = isVisible
  self.logToggleButton.text = isVisible and 'Hide log' or 'Show log'
  self.contentView:resize()
  if (isVisible) then
    self.logView:scroll_to_last_line()
  end
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

  if (self.warningCount > 0) then
    status = status .. ' (' .. self.warningCount .. ' warnings, see log)'
  end
  self:setProgress(1)
  self:setStatus(status)
  self.actionButton.text = 'Close'
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
  self:flushLog()
  self:stopTimer()
  self.running = false
  activeDialog = nil

  self:setStatus('Cancelled')
  self.actionButton.text = 'Close'
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
  self.progressView = nil
  self.logView = nil
  self.actionButton = nil
  self.logToggleButton = nil
  self.contentView = nil
end
