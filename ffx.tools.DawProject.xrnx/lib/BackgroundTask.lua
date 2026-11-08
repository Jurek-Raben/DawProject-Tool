-------------------------------------------------------------------------------
-- Background Task, runs one long running job at a time without blocking
-- Renoise, and shows its state in the progress dialog.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "BackgroundTask"

function BackgroundTask:__init(progressDialog)
  self.progressDialog = progressDialog
  self.process = nil
end

function BackgroundTask:isRunning()
  return self.process ~= nil and self.process:running()
end

function BackgroundTask:stop()
  if (self.process and self.process:running()) then
    self.process:stop()
  end
end

-- The job runs in a coroutine, so it has to call coroutine.yield() regularly.
-- With autoCloseSeconds the dialog closes by itself after a successful job.
function BackgroundTask:run(title, job, finishedStatus, failedStatus, autoCloseSeconds)
  self.progressDialog:start(title, function() self:stop() end)

  self.process = ProcessSlicer(
    job,
    function()
      self.progressDialog:finish(finishedStatus)
      if (autoCloseSeconds ~= nil) then
        self.progressDialog:closeAfterDelay(autoCloseSeconds)
      end
    end
  )
  self.process:set_error_callback(function(errorMessage)
    self.progressDialog:fail(failedStatus, errorMessage)
  end)

  self.process:start()
end
