# Daw Project Export Tool for Renoise 3.5+ (early state)

An early state daw project export tool (and later import maybe) for the Renoise DAW, starting from version 3.5 and upwards.

Please also read my suggestions for the Renoise API below, the tool requires binary helper tools so far which provide required information that currently is not avaialble thru the Renoise API.

#### Working so far

- Auto converts Renoise sample instruments into Redux instances, to make it loadable in the target DAW
- Note data and song structure
- Plugin automation data
- Section naming
- Track coloring and naming
- Loads fine into Bitwig 5.3+/6 (all) and Studio One 7.2+ (VST3 completely, AU without automation)
- You can also convert any sample instrument to Redux VST3 via context menu
- AudioUnit preset and automation export (not working in S1, due to bugs in S1)
- VST2 preset and automation export (not working in S1, due to bugs in S1)
- VST3 preset and automation export
- MIDI pattern automation, pitchbend, CC, aftertouch and program change
- Polyphonic aftertouch

#### Workarounds thru helper tools

- VST2 preset export (included VST2 helper tool provides missing plugin id)
- VST2 automation (included VST2 helper tool provides missing plugin id)
- VST3 automation mapping (included VST3 helper tool provides parameter ids)
- AU preset export (plist util converts preset file)
- AU automation mapping (auval provides missing parameter ids)

#### Not yet working, but planned

- Master track automation conversion
- Redux macro device to instrument device automation conversion
- No idea why VST3 preset loading fails in Cubase 14+. Might be the preset data itself. As a workaround, load the exported dawproject into S1 and then again export as dawproject. Bitwig exports also fail to load in Cubase. S1 uses an uncompressed zip type.
- VST2 preset loading and mapping is buggy in Studio One currently and needs to be fixed.
- Studio One will incorrectly set/interpret the parameter ids for AudioUnits. Therefore automation for AudioUnits currently is lost in Studio One.
- Internal plugin substitution (mostly gain and panning), if there is a free VST3 with easily changeable preset data (not found yet).

## How to use / install

This tool has been tested on macOS only so far. It currently requires the included binary tools to be executable. Most certainly you will have to disable SIP (system integrity protection) under macOS, since the binaries are not approved by the all-controlling Apple Corp.

The VST3 helper tool is known to not fully work on Windows. You will have to try yourself on Windows and Linux, but the tools are also included for these OSes.

## Song requirements

A song has to fulfill the following requirements for a working export:

- Only one instrument per track! Use [Fladd's track splitter tool](https://www.renoise.com/tools/split-into-separate-tracks)!
- The Instr. Automation Device has to be placed onto the track where the target instrument is playing.
- Don't use pre-mixer gain and panning, if you did, replace it with MUtility VST3 or TrackControl VST3
- Don't use the gainer device, if you did, replace it with MUtility VST3 or TrackControl VST3

## Disclaimer

This Renoise tool currently **contains pre-built binaries of the VST info helper tools**. I built those on my macOS system using the recommended toolchains for Rust. If you are unsure you can build these yourself, or simply disable the usage in the tool's preferences. Building will require basic knowledge about how to setup a Rust dev environment. macOS should work best for that purpose.

So I am not responsible for any damage these binaries could do to your system and your data. Use at your own risk! However, the binaries appear to behave normally here.

## Download

[Automatic release builds](https://github.com/Jurek-Raben/DawProject-Tool/releases)

## Development insights

#### This can't work using API only, due to the API limitations

- VST2/AU preset generation/export. Renoise does not provide any way to get the .fxp / .aupreset data. The device.active_preset data only contains the individual inline song data of the VST2 or AU plugin, assumingly different to VST3. This is already implemented in Renoise via "import preset..." and "export preset...", just not made available in the API for unknown reasons.
- VST3 preset export might be wonky, because it grabs the preset data from device.active_preset_data's `<ParameterChunk>` node, assuming that this is simply the complete .vstpreset. But it might not be the case for every plugin...
- parameterID mapping, so most automation won’t work, except for some VST3 plugins still using the index as parameter id (e.g. Redux VST3)
- The correct VST2 plugin identifier can't be set (an integer, which you see as "Unique ID" in the plugin info tooltip), since it is neither available in the API nor in device.active_preset_data, but required for VST2 preset loading
- You can’t determine the target device of the "Instr. Automation Device" via API currently. Has to be done through a complete track search instead (so the device has to sit on the track where the instrument plays). That `<LinkedInstrument>` node is missing in the active_preset_data for some reason, if you access it via API (not copy-paste).
- An import can only work for the song structure, but not for preset transferring, due to the same API limitations.
- AudioUnit parameter mapping is not possible, due to missing parameter ID infos.

#### Helper tools

The tool can use VST2/3 info tools to extract the missing plugin infos, which I coded in Rust. There are pre-built binaries included in the `/bin` sub directory, pre-built for macOS (arm/intel ub2), windows x86_64, linux x86_64. Most likely you will need to disable SIP under macOS to make these tools startable, because these are not Apple aprroved in any way.

#### Manual workarounds

- You can manipulate the generated dawproject data inside the "tmp" directory of the tool directory and then use the "Repack .dawproject" menu entry.

#### How to build from source

macOS and Linux users use the `./build_for_mac_linux.sh` script. Might need a chmod +x first. Windows users can test the same script, which should work in Windows 11 at least.

You can also decide to build the binary vst-tools by yourself.

These tools try to circumvent the current limitations of the Renoise API. The VST2/VST3 tool will give detailed infos for a given plugin path. If you want to use those via the tool settings, you will have to build these as first step with `./build_vst_tools.sh`.

The tools require Rust / cargo to be installed on the system.

#### Suggestions for the API

> `renoise.DeviceParameter.plugin_parameter_id` - int, unique VST3 parameter id provided by the plugin, is a simple index for VST2 (should be avaialable for AudioUnit, too)

> `renoise.AudioDevice.unique_id` - Just as "Unique ID" in the info tooltip. Renoise does not use it for VST2, instead it uses the plugin filename. But the actual ID is needed for the export.

> `renoise.InstrumentPluginDevice.unique_id` - Just as "Unique ID" in the info tooltip. Renoise does not use it for VST2, instead it uses the plugin filename. But the actual ID is needed for the export.

> `renoise.AudioDevice.active_preset_data["LinkedInstrument"]` - Also contains `LinkedInstrument` node for Instr. Automation Device

> `renoise.AudioDevice:export_active_preset(file_path)` - saves the currently selected preset in plugin specific format, that is .vstpreset for VST3, .fxp for VST2, .aupreset for AudioUnit. Just as "export preset..."

> `renoise.InstrumentPluginDevice:export_active_preset(file_path)` - saves the currently selected preset in plugin specific format, that is .vstpreset for VST3, .fxp for VST2, .aupreset for AudioUnit. Just as "export preset..."

> `renoise.AudioDevice:import_active_preset(file_path)` - imports a plugin type format specific preset into the active preset. Just as "import preset..."

> `renoise.InstrumentPluginDevice:import_active_preset(file_path)` - imports a plugin type format specific preset into the active preset. Just as "import preset..."

#### Feel free to contribute

Feel free to improve, try yourself, get in touch, and discuss it. Contact me, if you have questions or ideas.

I have tested this tool so far for macOS. However, it should theoretically also work for Windows and maybe even Linux. Please report back.

I've also tried to make the source code nicely readable. You know, this is important for team work, like proper function-, variable- and parameter-naming. The goal should be that a new developer can understand what's going on on-the-fly. What is the method or object actually doing?

#### Source code

https://github.com/Jurek-Raben/DawProject-Tool

#### Uses the following libraries

JSON lua by RXI
https://github.com/rxi/json.lua?tab=readme-ov-file

xml2lua by Manoel Campos da Silva Filho, Paul Chakravarti
https://github.com/manoelcampos/xml2lua

Also FancyStatus and ProcessSlicer.

#### License

Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International - https://creativecommons.org/licenses/by-nc-sa/4.0/

Can be changed.
