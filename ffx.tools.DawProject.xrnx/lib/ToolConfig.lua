-------------------------------------------------------------------------------
-- Tool Config, the options of the tool with their defaults and descriptions
-- by Jurek Raben
--
-- Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
-- Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
-------------------------------------------------------------------------------

ToolConfig = {}

ToolConfig.defaults = {
  convertToRedux = true,
  exportVST2 = true,
  exportVST3 = true,
  migrateVST2ToVST3 = false,
  exportForCubase = false,
  addTrackDelayToClips = true,
  splitTracksByInstrument = true,
  substitutePreMixer = true,
  substituteGainer = true,
  substituteEq5 = true,
  substituteCompressor = false,
  substituteBusCompressor = false,
  substituteEq10 = true,
  trackDelayTarget = 'clips',
  substituteEq5QFactor = 0,
  substituteEq10QFactor = 0,
  devMode = true,
  useVST2InfoTool = true,
  useVST3InfoTool = true
}

ToolConfig.descriptions = {
  convertToRedux = { type = "boolean", txt = "Convert sample instruments to Redux" },
  exportVST2 = { type = "boolean", txt = "Export VST2 plugins (not possible due to api limitations)" },
  exportVST3 = { type = "boolean", txt = "Export VST3 plugins" },
  migrateVST2ToVST3 = { type = "boolean", txt = "Export VST2 plugins as their installed VST3 version, if compatible (for Cubase, experimental)" },
  exportForCubase = { type = "boolean", txt = "Export for Cubase: groups as separate group channels (other DAWs lose the group plugins)" },
  addTrackDelayToClips = { type = "boolean", txt = "Add the track delay ms to the clip position" },
  splitTracksByInstrument = { type = "boolean", txt = "Export tracks with multiple instruments as group with one track per instrument" },
  devMode = { type = "boolean", txt = "Adds some debugging menu entries / functionality" },
  useVST2InfoTool = { type = "boolean", txt = "Hacky workaround using a binary tool for plugin id extraction" },
  useVST3InfoTool = { type = "boolean", txt = "Hacky workaround using a binary tool for parameter id extraction" },
  substituteEq5 = { type = "boolean", txt = "Export EQ 5 devices as plugin" },
  substituteEq10 = { type = "boolean", txt = "Export EQ 10 devices as plugin" },
  substituteCompressor = { type = "boolean", txt = "Export Compressor devices as plugin" },
  substituteBusCompressor = { type = "boolean", txt = "Export Bus Compressor devices as plugin" },
}

-- MeldaProduction has no plugins for Linux, see the substitution table
if (os.platform() ~= 'LINUX') then
  ToolConfig.descriptions.substitutePreMixer = { type = "boolean", txt = "Export the track pre gain, panning and delay as Melda MUtility" }
  ToolConfig.descriptions.substituteGainer = { type = "boolean", txt = "Export Gainer devices as Melda MUtility" }
end

if (os.platform() == 'MACINTOSH') then
  ToolConfig.defaults.exportAU = true
  ToolConfig.descriptions.exportAU = {
    type = "boolean",
    txt = "Export AudioUnit plugins (not possible due to api limitations)",
  }
end
