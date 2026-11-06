-------------------------------------------------------------------------------
-- Substitution Table, lists which parts of Renoise can be replaced by which VST3
-- plugin, depending on the operating system. An operating system without a target
-- doesn't get the option. A new substitution only needs a new entry here.
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

require('export/MeldaScales')
require('export/MUtilitySubstitution')
require('export/EqParameters')
require('export/MEqualizerSubstitution')
require('export/ShadeSubstitution')
require('export/ZlEqualizerSubstitution')
require('export/MCompressorSubstitution')

local MELDA_DOWNLOAD_URL = 'https://www.meldaproduction.com/downloads'
local UVI_SHADE_DOWNLOAD_URL = 'https://www.uvi.net/shade'
local ZL_EQUALIZER_DOWNLOAD_URL = 'https://zl-audio.github.io/plugins'

-- create gets the Renoise device and the config, or the track for a part of the track itself
local MUTILITY_FOR_PRE_MIXER = {
  pluginName = 'Melda MUtility (VST3)',
  classId = MUTILITY_CLASS_ID,
  downloadUrl = MELDA_DOWNLOAD_URL,
  create = function(track, config) return MUtilityPreMixerSubstitution(track, config) end,
}

local MUTILITY_FOR_GAINER = {
  pluginName = 'Melda MUtility (VST3)',
  classId = MUTILITY_CLASS_ID,
  downloadUrl = MELDA_DOWNLOAD_URL,
  create = function(device) return MUtilityGainerSubstitution(device) end,
}

local MEQUALIZER_FOR_EQ5 = {
  pluginName = 'Melda MEqualizer (VST3)',
  classId = MEQUALIZER_CLASS_ID,
  downloadUrl = MELDA_DOWNLOAD_URL,
  create = function(device, config) return MEqualizerSubstitution(device, config) end,
}

local SHADE_FOR_EQ5 = {
  pluginName = 'UVI Shade (VST3)',
  classId = SHADE_CLASS_ID,
  downloadUrl = UVI_SHADE_DOWNLOAD_URL,
  create = function(device, config) return ShadeSubstitution(device, config, EQ5_LAYOUT) end,
}

local ZL_EQUALIZER_FOR_EQ5 = {
  pluginName = 'ZL Equalizer 2 (VST3)',
  classId = ZL_EQUALIZER_CLASS_ID,
  downloadUrl = ZL_EQUALIZER_DOWNLOAD_URL,
  create = function(device, config) return ZlEqualizerSubstitution(device, config, EQ5_LAYOUT) end,
}

local SHADE_FOR_EQ10 = {
  pluginName = 'UVI Shade (VST3)',
  classId = SHADE_CLASS_ID,
  downloadUrl = UVI_SHADE_DOWNLOAD_URL,
  create = function(device, config) return ShadeSubstitution(device, config, EQ10_LAYOUT) end,
}

local ZL_EQUALIZER_FOR_EQ10 = {
  pluginName = 'ZL Equalizer 2 (VST3)',
  classId = ZL_EQUALIZER_CLASS_ID,
  downloadUrl = ZL_EQUALIZER_DOWNLOAD_URL,
  create = function(device, config) return ZlEqualizerSubstitution(device, config, EQ10_LAYOUT) end,
}

local MCOMPRESSOR_FOR_COMPRESSOR = {
  pluginName = 'Melda MCompressor (VST3)',
  classId = MCOMPRESSOR_CLASS_ID,
  downloadUrl = MELDA_DOWNLOAD_URL,
  create = function(device) return MCompressorSubstitution:createForCompressor(device) end,
}

local MCOMPRESSOR_FOR_BUS_COMPRESSOR = {
  pluginName = 'Melda MCompressor (VST3)',
  classId = MCOMPRESSOR_CLASS_ID,
  downloadUrl = MELDA_DOWNLOAD_URL,
  create = function(device) return MCompressorSubstitution:createForBusCompressor(device) end,
}

-- The targets of an operating system are ordered by priority, the first installed one is used.
-- MeldaProduction and UVI have no plugins for Linux.
local SUBSTITUTIONS = {
  {
    configKey = 'substitutePreMixer',
    title = 'Track pre gain, panning, delay',
    hasTrackDelayTarget = true,
    targets = { mac = { MUTILITY_FOR_PRE_MIXER }, win = { MUTILITY_FOR_PRE_MIXER } },
  },
  {
    configKey = 'substituteGainer',
    title = 'Gainer devices',
    devicePath = 'Audio/Effects/Native/Gainer',
    targets = { mac = { MUTILITY_FOR_GAINER }, win = { MUTILITY_FOR_GAINER } },
  },
  {
    configKey = 'substituteEq5',
    title = 'EQ 5 devices',
    devicePath = 'Audio/Effects/Native/EQ 5',
    qFactorConfigKey = EQ5_LAYOUT.qFactorConfigKey,
    targets = {
      mac = { SHADE_FOR_EQ5, ZL_EQUALIZER_FOR_EQ5, MEQUALIZER_FOR_EQ5 },
      win = { SHADE_FOR_EQ5, ZL_EQUALIZER_FOR_EQ5, MEQUALIZER_FOR_EQ5 },
      linux = { ZL_EQUALIZER_FOR_EQ5 },
    },
  },
  {
    configKey = 'substituteEq10',
    title = 'EQ 10 devices',
    devicePath = 'Audio/Effects/Native/EQ 10',
    qFactorConfigKey = EQ10_LAYOUT.qFactorConfigKey,
    targets = {
      mac = { SHADE_FOR_EQ10, ZL_EQUALIZER_FOR_EQ10 },
      win = { SHADE_FOR_EQ10, ZL_EQUALIZER_FOR_EQ10 },
      linux = { ZL_EQUALIZER_FOR_EQ10 },
    },
  },
  {
    configKey = 'substituteCompressor',
    title = 'Compressor devices',
    devicePath = 'Audio/Effects/Native/Compressor',
    targets = { mac = { MCOMPRESSOR_FOR_COMPRESSOR }, win = { MCOMPRESSOR_FOR_COMPRESSOR } },
  },
  {
    configKey = 'substituteBusCompressor',
    title = 'Bus Compressor devices',
    devicePath = 'Audio/Effects/Native/Bus Compressor',
    targets = { mac = { MCOMPRESSOR_FOR_BUS_COMPRESSOR }, win = { MCOMPRESSOR_FOR_BUS_COMPRESSOR } },
  },
}

SubstitutionTable = {}

-- Returns the substitutions of this operating system, each with its targets
function SubstitutionTable:getOptionsOfCurrentSystem()
  local osString = Helpers:getShortOSString()
  local options = {}

  for _, substitution in ipairs(SUBSTITUTIONS) do
    local targets = substitution.targets[osString]
    if (targets ~= nil) then
      table.insert(options, {
        configKey = substitution.configKey,
        title = substitution.title,
        devicePath = substitution.devicePath,
        qFactorConfigKey = substitution.qFactorConfigKey,
        hasTrackDelayTarget = substitution.hasTrackDelayTarget,
        targets = targets,
      })
    end
  end

  return options
end
