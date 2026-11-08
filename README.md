# Daw Project Export Tool for Renoise 3.5+ (early state)

A daw project export tool (and later import maybe) for the Renoise DAW, starting from version 3.5 and upwards.

Please also read my suggestions for the Renoise API below, the tool requires binary helper tools so far which provide required information that currently is not available through the Renoise API.

#### Working so far

- Auto converts Renoise sample instruments into Redux instances, to make it loadable in the target DAW
- Note data and song structure
- Tracks with multiple instruments are exported as group with one track per instrument, the mixer settings and effects stay on the group
- Hidden note columns are ignored, just like Renoise does not play them
- Notes in muted note columns are not exported
- The transpose settings of plugin instruments are applied to the notes
- Plugin automation data
- Section naming
- Track coloring and naming
- Loads fine into Bitwig 5.3+/6 (all), Fender Studio 8 / Studio One 7.2+ (VST2 and VST3, AU without automation) and Cubase 15/16 (VST3, with the option "Export for Cubase", see [DAW compatibility](#daw-compatibility))
- You can also convert any sample instrument to Redux VST3 via context menu
- AudioUnit preset and automation export (automation not working in Studio One, due to bugs in Studio One)
- VST2 preset and automation export, the presets are stored as banks (.fxb)
- VST3 preset and automation export
- VST2 plugins can be exported as their installed VST3 version, for DAWs without VST2 support like Cubase
- Routing of tracks into groups and of sends, also for Cubase
- The warnings name the track with its number and name, e.g. `track 16 (Bass)`
- VST2 shell plugins, e.g. WaveShell
- MIDI pattern automation, pitchbend, CC, aftertouch and program change
- Polyphonic aftertouch
- Progress dialog with cancel button, a list of all warnings and errors, and an expandable log
- Health check before the export, with instructions for fixing problems on your operating system

The master track always gets a limiter as last device, with a threshold of -0.2 dB and a release of 60 ms. It is a generic device of the format, so the DAW chooses its own limiter. Not every DAW has to support it.

#### Workarounds thru helper tools

- VST2 preset export (included VST2 helper tool provides missing plugin id)
- VST2 automation (included VST2 helper tool provides missing plugin id)
- VST3 automation mapping (included VST3 helper tool provides parameter ids)
- AU preset export (plist util converts preset file)
- AU automation mapping (auval provides missing parameter ids)

#### Not yet working, but planned

- Master track automation conversion
- Redux macro device to instrument device automation conversion
- Automation of VST2 plugins that are exported as their VST3 version, the parameter ids of the VST3 version are unknown
- Finding the VST3 version of more VST2 plugins, through the compatibility infos of the VST3 plugins (`moduleinfo.json`)
- Studio One will incorrectly set/interpret the parameter ids for AudioUnits. Therefore automation for AudioUnits currently is lost in Studio One.

## Support my work

Developing this tool took a lot of time and effort. If you'd like to support its ongoing development, you can buy me a coffee or donate here:
https://www.paypal.com/donate/?cmd=_s-xclick&hosted_button_id=UMTW5AHN53MCG

Thanks!

## How to use / install

Download the `.xrnx` file from the [releases](https://github.com/Jurek-Raben/DawProject-Tool/releases) and drag it into Renoise. The export then is available under `File > Export Song to .dawproject...`.

This tool has been tested on macOS only so far. The helper tools are also included for Windows and Linux, but you will have to try these yourself. Please report back.

A single step of the export, e.g. reading a plugin that takes long to load, might exceed the maximum execution time. In this case just click on "continue", multiple times if required.

### Getting the helper tools to run

The export starts the helper tools from the `bin` directory of the installed tool, so they have to be executable.

Before every export a health check runs. It checks the temporary directory, the packing command, the plugin database of Renoise, whether the helper tools can start, and whether they can access the plugins of the song. If everything is fine, the export continues right away. Otherwise the dialog shows the fitting instructions for your operating system, and you can check again after fixing the problem.

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

You can also run the health check of a helper tool manually, optionally with the paths of plugins. It only checks if it can access these files, and does not load the plugins. E.g. on macOS:

```bash
./vst3info-tool-mac-arm --healthcheck "/Library/Audio/Plug-Ins/VST3/MyPlugin.vst3"
```

To really load a plugin, leave out `--healthcheck`. If it works, the output contains the infos as JSON between `@@VSTINFO_BEGIN@@` and `@@VSTINFO_END@@`. Otherwise you will see the actual error message.

The VST3 tool can also list the scales of the parameters, optionally after loading a preset. This is useful for adding a new plugin substitution. Plugins that create parameters depending on their state, like UVI Shade, need the preset. On other systems than macOS such a plugin might not finish loading the state.

```bash
./vst3info-tool-mac-arm "/Library/Audio/Plug-Ins/VST3/MyPlugin.vst3" --parameter-values --preset "MyPreset.vstpreset"
```

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
- The width of the pre-mixer is not exported. Pre-mixer gain and panning, Gainer, EQ 5, EQ 10, Compressor and Bus Compressor devices are only exported with the plugin substitutions below.

## Plugin substitutions

A DAW can't load Renoise devices. After the health check you can choose which of them are exported as plugin instead. Only the devices that are used in the song are listed, together with their number of occurrences. The presets are generated and the automation is converted. Below them, the same dialog contains the [DAW compatibility](#daw-compatibility) options, so it is shown before every export.

If a plugin is not installed, it is displayed as not installed with a download button. An option without any installed plugin is disabled. If several plugins are installed for an option, you can select one in the dialog, by default in the order listed below. All the choices are saved.

| Renoise                           | macOS, Windows                        | Linux          | Default |
| --------------------------------- | ------------------------------------- | -------------- | ------- |
| Track pre gain, panning and delay | MUtility                              | -              | on      |
| Gainer                            | MUtility                              | -              | on      |
| EQ 5                              | UVI Shade, ZL Equalizer 2, MEqualizer | ZL Equalizer 2 | on      |
| EQ 10                             | UVI Shade, ZL Equalizer 2             | ZL Equalizer 2 | on      |
| Compressor                        | ZL Compressor, MCompressor            | ZL Compressor  | off     |
| Bus Compressor                    | ZL Compressor, MCompressor            | ZL Compressor  | off     |

All of them are VST3 plugins, available from [MeldaProduction](https://www.meldaproduction.com/downloads), [UVI](https://www.uvi.net/shade) and [ZL Audio](https://zl-audio.github.io/plugins). The table above is defined in `export/SubstitutionTable.lua`.

- **Pre gain and panning:** MUtility is placed before the effects of the track, using the +3 dB pan law of Renoise. It is only added to tracks using these settings.
- **Track delay:** By default the track delay shifts the MIDI notes in the exported clips, so it has no effect on group and send tracks. In the dialog you can select a delay inside of MUtility instead, which also works on these tracks. A negative delay is reported as latency there. Without the substitution of the pre mixer, the option `addTrackDelayToClips` decides about shifting the notes.
- **Gainer:** The phase inversion of the channels is also exported.
- **EQ 5 and EQ 10:** The first and the last band are exported as shelves, the others as peak filters. The ear guard limiter of Shade is disabled. The conversion of the bandwidth is an approximation, so each of both EQs has a Q factor in the dialog from x 0.25 to x 4, which makes the filters narrower or wider.
- **Compressor and Bus Compressor:** ZL Compressor uses its Classic style.
- **Automation:** The automation of the substitutions assumes how Renoise scales its normalized values. This is not measured for every parameter yet.

The plugins are named like the devices in Renoise, with their position on the track, e.g. `EQ 5 pos 2`.

## DAW compatibility

Some DAWs need a special export. The options are in the substitution dialog, below the substitutions, and they are saved like all the other choices.

#### VST3 migration

Some DAWs, like Cubase, don't load VST2 plugins at all. Many plugins have a VST3 version which can replace the VST2 version and takes over its settings. With this option, a VST2 plugin is exported as its VST3 version, if such a version is installed. Otherwise it stays VST2. The option is only listed if the song contains VST2 plugins, and it needs the VST2 helper tool for the id of the plugin.

#### Export for Cubase

The DAWs expect the channel of a group at different places. Cubase only routes the tracks of a group into it, if the group is a separate group channel. Bitwig and Studio only keep the plugins of a group, if its channel is inside of the group. So this option is only for Cubase, by default the export works for the other DAWs.

For Cubase also enable the VST3 migration, since Cubase ignores VST2 plugins. Before the import, set the default stereo panner of Cubase to "Stereo Balance Panner" under `Preferences > Mix`. The combined panner of Cubase only moves the left side by the pan value of the project, so all the tracks sound panned to the right.

## Disclaimer

The release packages of this Renoise tool **contain pre-built binaries of the VST info helper tools**. These are built from this source code by the GitHub workflow of this repository. If you are unsure you can build these yourself, or simply disable the usage in the tool's preferences. Building will require basic knowledge about how to setup a Rust dev environment. macOS should work best for that purpose.

So I am not responsible for any damage these binaries could do to your system and your data. Use at your own risk! However, the binaries appear to behave normally here.

## Download

[Automatic release builds](https://github.com/Jurek-Raben/DawProject-Tool/releases)

## DAW specific workarounds

Bitwig loads all the exports just fine, just like it should be. Fender Studio 8 / Studio One 7.2+ loads VST2 and VST3, but loses the automation of AudioUnits. Cubase 15/16 loads the exports with the options described in [DAW compatibility](#daw-compatibility).

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

These tools try to circumvent the current limitations of the Renoise API. The VST2/VST3 tool will give detailed infos for a given plugin path. The code they share, like the command line, the output and the health check, is located in `vst-tool-common`.

The tools require Rust / cargo to be installed on the system. The VST3 tool also requires the VST3 SDK under `vst3info-tool/vst3sdk`, see `.github/workflows/build.yml` for the used version. On macOS the script builds for all platforms, which also requires `cross` and Docker. On Windows and Linux it only builds for the current system.

For packing the tool itself, create a `build` directory and use `./build_for_mac_linux.sh`. Windows users can test the same script, which should work in Windows 11 at least. In contrast to the release builds, this package still contains the development-only code.

#### Adding a plugin substitution

1. Read the parameter ids and scales of the plugin with the VST3 tool, see [Testing a helper tool](#testing-a-helper-tool).
2. Save a preset in the plugin to learn the class id and the format of its state.
3. Add a class in `export/` which creates the preset data and maps the automation values. `EqParameters` and `CompressorParameters` read the Renoise devices, `MeldaPreset` and `JucePreset` create preset files.
4. Add the target to `export/SubstitutionTable.lua`, and its option to `lib/ToolConfig.lua` for a new device.

#### Unique preset file names

Bitwig caches the files of a project by their name. It would load the presets of a previous export with the same names, even after importing the new one. So all the preset file names contain a timestamp of the export.

#### Releases

Every push to `main` builds the helper tools for all platforms and packages the tool. The version comes from `manifest.xml`: a new version creates a new release, otherwise the package of the existing release is replaced. Code between `-- @build:skip-start` and `-- @build:skip-end` is removed from the package, and the placeholder `@build:version@` in `main.lua` is replaced with the version.

#### Suggestions for the API

> `renoise.DeviceParameter.plugin_parameter_id` - int, unique VST3 parameter id provided by the plugin, is a simple index for VST2 (should be available for AudioUnit, too)

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
(extended by an optional `_order` of the child tags, since some DAWs expect the tracks before the channels)

Also ProcessSlicer.

#### License

Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International - https://creativecommons.org/licenses/by-nc-sa/4.0/

Can be changed.
