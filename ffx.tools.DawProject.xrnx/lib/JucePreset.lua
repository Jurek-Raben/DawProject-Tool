-------------------------------------------------------------------------------
-- JUCE Preset, creates .vstpreset data for plugins which save the XML of their
-- JUCE parameters, like the plugins of ZL Audio.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

local VST3_HEADER_SIZE = 48
local XML_HEADER = '<?xml version="1.0" encoding="UTF-8"?>\n'

-- JUCE stores the state of its bypass parameter behind the state of the plugin
local PRIVATE_DATA = string.rep(string.char(0), 9) .. 'JUCEPrivateData' ..
    string.char(0, 1, 1) .. 'Bypass' .. string.char(0, 1, 1, 3, 0, 0x1d, 0, 0, 0, 0, 0, 0, 0) .. 'JUCEPrivateData'

JucePreset = {}

function JucePreset:createParameterXml(id, value)
  return '<PARAM id="' .. id .. '" value="' .. MeldaPreset:formatNumber(value) .. '"/>'
end

function JucePreset:appendParameters(xmlParts, parameters)
  for id, value in pairs(parameters) do
    table.insert(xmlParts, self:createParameterXml(id, value))
  end
end

function JucePreset:create(classId, settingsXml)
  local xml = XML_HEADER .. settingsXml
  local state = 'VC2!' .. Helpers:intToBinaryLE(string.len(xml), 4) .. xml .. PRIVATE_DATA
  local stateSize = string.len(state)
  local listOffset = VST3_HEADER_SIZE + stateSize

  return table.concat({
    'VST3',
    Helpers:intToBinaryLE(1, 4),
    classId,
    Helpers:intToBinaryLE(listOffset, 8),
    state,
    'List',
    Helpers:intToBinaryLE(2, 4),
    'Comp', Helpers:intToBinaryLE(VST3_HEADER_SIZE, 8), Helpers:intToBinaryLE(stateSize, 8),
    'Cont', Helpers:intToBinaryLE(listOffset, 8), Helpers:intToBinaryLE(0, 8),
  })
end
