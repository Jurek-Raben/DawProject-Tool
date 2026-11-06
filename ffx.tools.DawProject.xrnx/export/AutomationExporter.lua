-------------------------------------------------------------------------------
-- Automation Exporter, generates the automation lanes and the parameters they
-- are targeting. MIDI data becomes an expression instead of a parameter.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

class "AutomationExporter"

function AutomationExporter:__init(config, progress, layout, pluginInfoCache)
  self.config = config
  self.progress = progress
  self.layout = layout
  self.pluginInfoCache = pluginInfoCache
end

function AutomationExporter:mapExpressionType(automationEvent)
  if (automationEvent.type == 'PB') then
    return 'pitchBend'
  end
  if (automationEvent.type == 'CC') then
    return 'channelController'
  end
  if (automationEvent.type == 'CP') then
    return 'channelPressure'
  end
  if (automationEvent.type == 'Prg') then
    return 'programChange'
  end

  return nil
end

function AutomationExporter:generateAutomationEventsDataForXML(songEvents)
  local automationEvents = songEvents.automationEvents

  local automationsObj = {}
  local automationLanes = {}
  local parametersObj = {}
  local scaleFactor = SongHelpers:getBeatsPerTick()

  self.progress:setPhase('Exporting automation', 0.35, 0.55)

  for eventIndex, automationEvent in pairs(automationEvents) do
    local trackNum = automationEvent.trackNum
    local paramIndex = automationEvent.paramIndex
    local parameterIdPrefix = 'paramid-' .. trackNum .. '-' .. automationEvent.deviceIndex

    -- automation of an instrument belongs to its track, the rest to the track with the effects
    local automationLaneKey = trackNum
    if (automationEvent.instrumentNum ~= nil) then
      automationLaneKey = self.layout:getInstrumentLaneKey(trackNum, automationEvent.instrumentNum)
    end

    if (automationsObj[automationLaneKey] == nil) then
      automationsObj[automationLaneKey] = {}
      self.progress:setPhaseProgress(eventIndex / #automationEvents)
      coroutine.yield()
    end

    -- A lane belongs to one parameter of one device. The lanes are stored with numeric keys,
    -- because xml2lua only repeats a tag for those and turns string keys into tag names.
    local laneKey = parameterIdPrefix .. '-' .. paramIndex .. '-' .. automationEvent.type
    local automationLane = automationLanes[laneKey]
    local expression = self:mapExpressionType(automationEvent)
    if (automationLane == nil) then
      automationLane = {
        _attr = {
          name = automationEvent.parameterName,
          unit = "normalized"
        },
        Target = {
          _attr = {
            parameter = expression == nil and (parameterIdPrefix .. '-' .. paramIndex) or nil,
            expression = expression,
            controller = automationEvent.type == 'CC' and automationEvent.paramIndex or nil,
            channel = "0"
          }
        },
        RealPoint = {}
      }
      automationLanes[laneKey] = automationLane
      table.insert(automationsObj[automationLaneKey], automationLane)
    end

    local points = automationLane.RealPoint
    local pointTime = Helpers:round(automationEvent.timestamp * scaleFactor, 6)

    -- Not every DAW respects "hold" on import. A point with the previous value directly before the
    -- new value keeps the step, even if the points get interpolated linearly.
    local previousPoint = points[#points]
    if (previousPoint ~= nil and previousPoint._attr.interpolation == 'hold') then
      local stepTime = Helpers:round(pointTime - scaleFactor, 6)
      if (stepTime > previousPoint._attr.time) then
        points[#points + 1] = {
          _attr = {
            time = stepTime,
            value = previousPoint._attr.value,
            interpolation = 'hold',
          }
        }
      end
    end

    points[#points + 1] = {
      _attr = {
        time = pointTime,
        value = Helpers:round(automationEvent.value, 6),
        interpolation = automationEvent.interpolation,
      }
    }

    -- MIDI data is no plugin parameter. Its number would be read as the index of a parameter.
    if (expression ~= nil) then
      goto nextAutomationEvent
    end

    if (parametersObj[parameterIdPrefix] == nil) then
      parametersObj[parameterIdPrefix] = {}
      self.progress:setPhaseProgress(eventIndex / #automationEvents)
      coroutine.yield()
    end

    if (parametersObj[parameterIdPrefix][paramIndex] == nil) then
      local parameterID = automationEvent.paramIndex
      -- sample instruments have no plugin device
      local devicePath = automationEvent.device and automationEvent.device.device_path or ''
      local deviceName = automationEvent.device and automationEvent.device.name or 'sample instrument'
      if (self.config['useVST3InfoTool'] == true and string.find(devicePath, "VST3/") ~= nil) then
        self.progress:setStatus('Reading parameters of ' .. deviceName)
        local pluginInfo = self.pluginInfoCache:get(automationEvent.device.device_path)
        if (pluginInfo == nil) then
          pluginInfo = DeviceHelpers:readPluginInfo(automationEvent.device)
        end

        self.pluginInfoCache:set(automationEvent.device.device_path, pluginInfo)

        if (pluginInfo) then
          local foundParamObj = DeviceHelpers:findPluginInfoParameterObjectByIndex(pluginInfo, automationEvent
            .paramIndex)
          if (foundParamObj) then
            print('found param name', foundParamObj['title'])
            print('found param id', foundParamObj['id'])
            print('matching param name', automationEvent.parameterName)
            parameterID = foundParamObj['id']
          end
        end
      end

      if (os.platform() == 'MACINTOSH' and self.config['exportAU'] == true and string.find(devicePath, "AU/") ~= nil) then
        local pluginInfo = self.pluginInfoCache:get(automationEvent.device.device_path)
        if (pluginInfo == nil) then
          local deviceID = DeviceHelpers:getActivePresetDataContent(automationEvent.device, 'PluginIdentifier')
          pluginInfo = DeviceHelpers:extractAUDeviceParameterIDs(deviceID)
        end

        self.pluginInfoCache:set(automationEvent.device.device_path, pluginInfo)

        if (pluginInfo) then
          local foundParamObj = DeviceHelpers:findPluginInfoParameterObjectByIndex(pluginInfo, automationEvent
            .paramIndex)
          if (foundParamObj) then
            print('found param id', foundParamObj['id'])
            print('matching param name', automationEvent.parameterName)
            parameterID = foundParamObj['id']
          end
        end
      end

      print('linked param for instr ' .. deviceName, automationEvent.parameterName,
        automationEvent.type, automationEvent.value,
        parameterIdPrefix,
        paramIndex)
      parametersObj[parameterIdPrefix][paramIndex] = {
        _attr = {
          id = parameterIdPrefix .. '-' .. paramIndex,
          name = automationEvent.parameterName,
          parameterID = parameterID,
          unit = automationEvent.unit or 'normalized',
          min = automationEvent.min or "0",
          max = automationEvent.max or "1",
        }
      }
    end

    ::nextAutomationEvent::
  end

  return { automationsObj = automationsObj, parametersObj = parametersObj }
end
