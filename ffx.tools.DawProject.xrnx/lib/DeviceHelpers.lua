-------------------------------------------------------------------------------
-- General Device Helpers, collection of useful additional
-- renoise.AudioDevice object functionality
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------


DeviceHelpers = {}

function DeviceHelpers:getParameterChunk(device)
  local startOffset, endOffset = string.find(device.active_preset_data, "<ParameterChunk>")
  local nodeEndOffset = string.find(device.active_preset_data, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(device.active_preset_data, startOffset + 16 + 9, nodeEndOffset - 1 - 3)
  end
  return nil
end

function DeviceHelpers:getActivePresetDataContent(device, nodeName)
  local startOffset, endOffset = string.find(device.active_preset_data, "<" .. nodeName .. ">")
  local nodeEndOffset = string.find(device.active_preset_data, "</", endOffset)
  if (startOffset ~= nil and nodeEndOffset ~= nil) then
    return string.sub(device.active_preset_data, startOffset + string.len(nodeName) + 2,
      nodeEndOffset - 1)
  end
  return nil
end
