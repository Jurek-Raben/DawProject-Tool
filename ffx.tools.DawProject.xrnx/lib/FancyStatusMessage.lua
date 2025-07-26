-- note: using { } as storage tricks the API into referencing the very same table regardless of
-- different app objects used to call :fancy_status_message
renoise.Application._fancy_status_message = {}

function renoise.Application:fancy_status_message(msg)
  renoise.Application._fancy_status_message.object =
      renoise.Application._fancy_status_message.object or FancyStatusMessage()
  renoise.Application._fancy_status_message.object:show_status(msg)
end

class 'FancyStatusMessage'

function FancyStatusMessage:__init()
  self.queue = table.create()

  self._show_status = function()
    if (#self.queue == 0) then
      self:terminate()
    else
      renoise.app():show_status(self.queue[#self.queue])
      self.queue:clear()
    end
  end
end

function FancyStatusMessage:terminate()
  renoise.tool():remove_timer(self._show_status)
end

function FancyStatusMessage:show_status(msg)
  if renoise.tool():has_timer(self._show_status) then
    self.queue:insert(msg)
  else
    renoise.app():show_status(msg)
    renoise.tool():add_timer(self._show_status, 1000 / 30)
  end
end
