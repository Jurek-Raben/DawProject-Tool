-------------------------------------------------------------------------------
-- Plugin Substitutions, finds the substitution for a part of Renoise, depending
-- on the options of the user and the installed plugins.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('export/SubstitutionTable')

local VST3_DEVICE_PATH_PREFIX = 'Audio/Effects/VST3/'


class "PluginSubstitutions"

-- Plugins can only be found in the current song
function PluginSubstitutions:isPluginInstalled(classId)
  local devicePath = VST3_DEVICE_PATH_PREFIX .. classId
  for _, deviceInfo in ipairs(Song:track(1).available_device_infos) do
    if (deviceInfo.path == devicePath) then
      return true
    end
  end
  return false
end

-- Returns the installed targets of an option, ordered by priority
function PluginSubstitutions:findInstalledTargets(option)
  local installedTargets = {}
  for _, target in ipairs(option.targets) do
    if (self:isPluginInstalled(target.classId)) then
      table.insert(installedTargets, target)
    end
  end
  return installedTargets
end

function PluginSubstitutions:getTargetConfigKey(option)
  return option.configKey .. 'Target'
end

-- Returns the target the user selected, otherwise the installed one with the highest priority.
-- A selected plugin can be uninstalled in the meantime.
function PluginSubstitutions:findSelectedTarget(option, config)
  local installedTargets = self:findInstalledTargets(option)
  local selectedClassId = config[self:getTargetConfigKey(option)]

  for _, target in ipairs(installedTargets) do
    if (target.classId == selectedClassId) then
      return target
    end
  end
  return installedTargets[1]
end

function PluginSubstitutions:__init(config)
  self.substitutionsByKey = {}
  self.targetsByDevicePath = {}
  self.preMixerTarget = nil

  for _, option in ipairs(SubstitutionTable:getOptionsOfCurrentSystem()) do
    local target = config[option.configKey] == true and self:findSelectedTarget(option, config) or nil
    if (target ~= nil) then
      if (option.devicePath ~= nil) then
        self.targetsByDevicePath[option.devicePath] = target
      else
        self.preMixerTarget = target
      end
    end
  end
end

-- Keeps a substitution for the whole export, nil is stored as false.
function PluginSubstitutions:getCached(cacheKey, createSubstitution)
  if (self.substitutionsByKey[cacheKey] == nil) then
    self.substitutionsByKey[cacheKey] = createSubstitution() or false
  end
  return self.substitutionsByKey[cacheKey] or nil
end

function PluginSubstitutions:findPreMixerSubstitution(trackNum)
  if (self.preMixerTarget == nil) then
    return nil
  end

  return self:getCached('premixer-' .. trackNum, function()
    local substitution = self.preMixerTarget.create(Song:track(trackNum))
    return substitution:isUsed() and substitution or nil
  end)
end

-- Returns nil for all devices that are not substituted
function PluginSubstitutions:findDeviceSubstitution(device, trackNum, deviceIndex)
  local target = self.targetsByDevicePath[device.device_path]
  if (target == nil) then
    return nil
  end

  return self:getCached('device-' .. trackNum .. '-' .. deviceIndex, function()
    local substitution = target.create(device)
    if (substitution:isUsable()) then
      return substitution
    end
    print('warning: ' .. device.name .. ' at track ' .. trackNum ..
      ' is missing in the export, since its parameters are unknown')
    return nil
  end)
end

-- The first device of a track is its mixer
function PluginSubstitutions:findSubstitutionAtDeviceIndex(trackNum, deviceIndex)
  if (deviceIndex == 1) then
    return self:findPreMixerSubstitution(trackNum)
  end
  return self:findDeviceSubstitution(Song:track(trackNum):device(deviceIndex), trackNum, deviceIndex)
end
