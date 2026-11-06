# Daw Project Export Tool for Renoise 3.5+ (early state)

An early state daw project export tool (and later import maybe) for the Renoise DAW, starting from version 3.5 and upwards.

Please also read my suggestions for the Renoise API below, the tool requires binary helper tools so far which provide required information that currently is not avaialble thru the Renoise API.

#### Working so far

- Auto converts Renoise sample instruments into Redux instances, to make it loadable in the target DAW
- Note data and song structure
- Tracks with multiple instruments are exported as group with one track per instrument, the mixer settings and effects stay on the group
- Hidden note columns are ignored, just like Renoise does not play them
- The transpose settings of plugin instruments are applied to the notes
- Plugin automation data
- Section naming
- Track coloring and naming
- Loads fine into Bitwig 5.3+/6 (all) and Studio One 7.2+ (VST3 completely, AU without automation)
- You can also convert any sample instrument to Redux VST3 via context menu
- AudioUnit preset and automation export (not working in S1, due to bugs in S1)
- VST2 preset and automation export (not working in S1, due to bugs in S1)
- VST3 preset and automation export
- VST2 shell plugins, e.g. WaveShell
- MIDI pattern automation, pitchbend, CC, aftertouch and program change
- Polyphonic aftertouch
- Progress dialog with cancel button, a list of all warnings and errors, and an expandable log

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

Download the `.xrnx` file from the [releases](https://github.com/Jurek-Raben/DawProject-Tool/releases) and drag it into Renoise. The export then is available under `File > Export Song to .dawproject...`.

This tool has been tested on macOS only so far. The helper tools are also included for Windows and Linux, but you will have to try these yourself. Please report back.

A single step of the export, e.g. reading a plugin that takes long to load, might exceed the maximum execution time. In this case just click on "continue", multiple times if required.

### Getting the helper tools to run

The export starts the helper tools from the `bin` directory of the installed tool, so they have to be executable. If they can't be started, the warnings and errors of the export dialog will show `error: Tool output not found`, usually together with the message of the operating system.

The steps below have to be repeated after installing a new version of the tool, because this replaces the directory. Replace `V3.5.4` with your version of Renoise.

If you don't want to use the helper tools at all, disable `useVST2InfoTool` and `useVST3InfoTool` in the options of the tool. You will lose VST2 presets and VST2 automation, and VST3 automation will only work for plugins using the index as parameter id.

#### macOS

The binaries are not signed, so macOS might block them. Disabling SIP (system integrity protection) should not be required for this.

```bash
cd ~/Library/Preferences/Renoise/V3.5.4/Scripts/Tools/ffx.tools.DawProject.xrnx/bin
chmod +x vst2info-tool-* vst3info-tool-*
xattr -dr com.apple.quarantine .
```

If macOS still blocks a binary on Apple Silicon, sign it locally:

```bash
codesign --force --sign - vst2info-tool-mac-arm vst3info-tool-mac-arm
```

Plugins running bridged in Renoise on Apple Silicon are read by the Intel binaries, which require Rosetta:

```bash
softwareupdate --install-rosetta
```

Plugins running bridged on an Intel Mac can't be read.

#### Windows

Only x86_64 is supported. Bridged plugins can't be read. In PowerShell, remove the download marker of the binaries:

```powershell
Get-ChildItem "$env:APPDATA\Renoise\V3.5.4\Scripts\Tools\ffx.tools.DawProject.xrnx\bin\*.exe" | Unblock-File
```

If your virus scanner removes or blocks the binaries, add an exception for the `bin` directory.

#### Linux

Only x86_64 is supported. Bridged plugins can't be read. The `zip` command is required for packing the .dawproject file.

```bash
cd ~/.renoise/V3.5.4/Scripts/Tools/ffx.tools.DawProject.xrnx/bin
chmod +x vst2info-tool-* vst3info-tool-*
```

Some plugins need additional system libraries for being loaded. These have to be installed through your package manager.

#### Testing a helper tool

You can start a helper tool manually with the path of a plugin, e.g. on macOS:

```bash
./vst3info-tool-mac-arm "/Library/Audio/Plug-Ins/VST3/MyPlugin.vst3"
```

If it works, the output contains the plugin infos as JSON between `@@VSTINFO_BEGIN@@` and `@@VSTINFO_END@@`. Otherwise you will see the actual error message.

## Reporting problems

If an export fails or sounds wrong, please report it in the [Renoise forum](https://forum.renoise.com/). The most helpful thing is the complete list of warnings and errors:

1. Keep the export dialog open after the export, it does not close by itself.
2. Select the whole text in the "Warnings and errors" field with the cursor and copy it. Please copy all of it, not only the last lines or a screenshot, since the cause often is mentioned further up.
3. If the export was aborted, or if there are no warnings at all, also click on "Show log" and copy the whole log the same way.
4. Paste everything into your post, and also mention:
   - your operating system and whether it is Intel or ARM
   - the versions of Renoise and this tool
   - the DAW you imported the .dawproject into, and its version
   - what you expected and what actually happened, e.g. which track and plugin is affected

If possible, also attach the song, or a small song that shows the same problem.

## Song requirements

A song has to fulfill the following requirements for a working export:

- The Instr. Automation Device has to be placed onto the track where the target instrument is playing.
- Don't use pre-mixer gain and panning, if you did, replace it with MUtility VST3 or TrackControl VST3
- Don't use the gainer device, if you did, replace it with MUtility VST3 or TrackControl VST3

## Disclaimer

The release packages of this Renoise tool **contain pre-built binaries of the VST info helper tools**. These are built from this source code by the GitHub workflow of this repository. If you are unsure you can build these yourself, or simply disable the usage in the tool's preferences. Building will require basic knowledge about how to setup a Rust dev environment. macOS should work best for that purpose.

So I am not responsible for any damage these binaries could do to your system and your data. Use at your own risk! However, the binaries appear to behave normally here.

## Download

[Automatic release builds](https://github.com/Jurek-Raben/DawProject-Tool/releases)

## DAW specific workarounds

Bitwig loads all the exports just fine, just like it should be. Studio One 7.2+ only correctly works with VST3s. If you want to import into Cubase 14/15, first import to Studio One, then export as dawproject again. Then Cubase also loads the VST3 presets. Most likely these problems are caused by bugs inside Studio One and Cubase, not this exporter tool.

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

The tool can use VST2/3 info tools to extract the missing plugin infos, which I coded in Rust. The release packages include pre-built binaries in the `/bin` sub directory, for macOS (arm/intel), windows x86_64 and linux x86_64. See [Getting the helper tools to run](#getting-the-helper-tools-to-run).

#### Manual workarounds

- You can manipulate the generated dawproject data inside the "tmp" directory of the tool directory and then use the "Repack .dawproject" menu entry. It is only available with `devMode` enabled in the options of the tool.

#### How to build from source

The binaries are not part of the repository, so build these first with `./build_vst_tools.sh`. They end up in the `bin` directory of the tool. The scripts might need a chmod +x first.

These tools try to circumvent the current limitations of the Renoise API. The VST2/VST3 tool will give detailed infos for a given plugin path.

The tools require Rust / cargo to be installed on the system. The VST3 tool also requires the VST3 SDK under `vst3info-tool/vst3sdk`, see `.github/workflows/build.yml` for the used version. On macOS the script builds for all platforms, which also requires `cross` and Docker. On Windows and Linux it only builds for the current system.

For packing the tool itself, create a `build` directory and use `./build_for_mac_linux.sh`. Windows users can test the same script, which should work in Windows 11 at least. In contrast to the release builds, this package still contains the development-only code.

#### Releases

Every push to `main` builds the helper tools for all platforms and packages the tool. The version comes from `manifest.xml`: a new version creates a new release, otherwise the package of the existing release is replaced. Code between `-- @build:skip-start` and `-- @build:skip-end` is removed from the package.

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

Also ProcessSlicer.

#### License

Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International - https://creativecommons.org/licenses/by-nc-sa/4.0/

Can be changed.
