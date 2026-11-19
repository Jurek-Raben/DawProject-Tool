/*!
 * ------------------------------------------------------------------------
 * VST3 Info Extractor Tool
 * heavily based on rust-vst3-host by Helge Sverre
 * [https://github.com/HelgeSverre/rust-vst3-host](https://github.com/HelgeSverre/rust-vst3-host)
 *
 * by Jurek Raben
 *
 * Usage:
 *   vst3info-tool <plugin path> [--parameter-values] [--preset <preset path>] [--class-id <class id>]
 *   vst3info-tool --healthcheck [plugin paths...]
 *   vst3info-tool --migration-info <plugin path>
 *   vst3info-tool --remap-parameters <plugin path> <class id> <replaced class id> [old parameter ids...]
 *   vst3info-tool --help
 *   All commands accept --output=text|json|inline, see the help page.
 * ------------------------------------------------------------------------
 */

mod console_silencer;
mod host_application;
mod memory_stream;
mod message_pump;
mod migration_info;
mod param_remap;
mod plugin_binary;
mod plugin_inspector;
mod plugin_module;
mod plugin_report;
mod preset_file;
mod vst3_strings;

use plugin_inspector::DisplayedValues;
use plugin_module::PluginModule;
use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use vst_tool_common::cli::{self, Command};
use vst_tool_common::healthcheck::{self, ToolIdentity};
use vst_tool_common::output;

const PARAMETER_VALUES_SWITCH: &str = "--parameter-values";
const PRESET_SWITCH: &str = "--preset";
const CLASS_ID_SWITCH: &str = "--class-id";

fn main() {
    let command = cli::parse_command(env::args_os().skip(1))
        .unwrap_or_else(|error| output::exit_with_error(&error));

    match command {
        Command::Help => print!("{}", help_page()),
        Command::Healthcheck { plugin_paths } => healthcheck::run(
            ToolIdentity {
                name: env!("CARGO_PKG_NAME"),
                version: env!("CARGO_PKG_VERSION"),
            },
            &plugin_paths,
            plugin_binary::locate_plugin_binary,
        ),
        Command::MigrationInfo { plugin_path } => {
            let migration_info = migration_info::read_migration_info(&plugin_path)
                .unwrap_or_else(|error| output::exit_with_error(&error));
            output::print_result(migration_info);
        }
        Command::RemapParameters {
            plugin_path,
            class_id,
            replaced_class_id,
            old_parameter_ids,
        } => {
            let remapped = param_remap::remap_parameters(&plugin_path, &class_id, &replaced_class_id, &old_parameter_ids)
                .unwrap_or_else(|error| output::exit_with_error(&error));
            output::print_result(remapped);
        }
        Command::ReadPlugin {
            plugin_path,
            additional_arguments,
        } => {
            let displayed_values = if additional_arguments
                .iter()
                .any(|argument| argument == PARAMETER_VALUES_SWITCH)
            {
                DisplayedValues::Read
            } else {
                DisplayedValues::Skip
            };

            let preset_path = find_switch_value(&additional_arguments, PRESET_SWITCH)
                .unwrap_or_else(|error| output::exit_with_error(&error))
                .map(PathBuf::from);
            let class_id = find_switch_value(&additional_arguments, CLASS_ID_SWITCH)
                .unwrap_or_else(|error| output::exit_with_error(&error))
                .and_then(|class_id| class_id.into_string().ok());

            read_plugin(&plugin_path, displayed_values, preset_path.as_deref(), class_id.as_deref())
                .unwrap_or_else(|error| output::exit_with_error(&error));
        }
    }
}

fn help_page() -> String {
    format!(
        "\
{name} {version}
Reads the infos of VST3 plugins, as used by the DAW Project Tool and the Plugin Migrator for Renoise.

Usage:
  {name} <plugin path> [--parameter-values] [--preset <preset path>] [--class-id <class id>]
  {name} --migration-info <plugin path>
  {name} --remap-parameters <plugin path> <class id> <replaced class id> [old parameter ids...]
  {name} --healthcheck [plugin paths...]
  {name} --help

Commands:
  <plugin path>
      Loads the plugin and prints its name, vendor, buses and automatable parameters.
      --parameter-values      also lists the displayed values of each parameter
      --preset <preset path>  loads a .vstpreset first, for plugins whose parameters depend on their state
      --class-id <class id>   reads this class of a module with several plugins
  --migration-info <plugin path>
      Lists the older plugins (e.g. VST2) the plugin can replace. Reads the moduleinfo.json of the plugin
      and only loads the plugin if there is none.
  --remap-parameters <plugin path> <class id> <replaced class id> [old parameter ids...]
      Asks the plugin which of its parameters replace the given parameters of the replaced plugin.
  --healthcheck [plugin paths...]
      Checks that the tool starts and can access the given plugins, without loading them.
  --help, -h
      Prints this help page.

Output:
  --output=text    readable console output (default)
  --output=json    formatted JSON
  --output=inline  JSON in a single line between @@VSTINFO_BEGIN@@ and @@VSTINFO_END@@, used by the Renoise tools
  Errors are printed to stderr and end the tool with exit code 1.
",
        name = env!("CARGO_PKG_NAME"),
        version = env!("CARGO_PKG_VERSION")
    )
}

/// The argument following a switch
fn find_switch_value(additional_arguments: &[OsString], switch: &str) -> Result<Option<OsString>, String> {
    let Some(switch_index) = additional_arguments
        .iter()
        .position(|argument| argument == switch)
    else {
        return Ok(None);
    };

    additional_arguments
        .get(switch_index + 1)
        .map(|value| Some(value.clone()))
        .ok_or_else(|| format!("The switch {} needs a value", switch))
}

fn read_plugin(
    plugin_path: &Path,
    displayed_values: DisplayedValues,
    preset_path: Option<&Path>,
    class_id: Option<&str>,
) -> Result<(), String> {
    let binary_path = plugin_binary::locate_plugin_binary(plugin_path).map_err(|error| {
        format!(
            "Path does not exist or is invalid ({}): {}",
            plugin_path.display(),
            error
        )
    })?;

    let preset_states = preset_path
        .map(preset_file::read_preset_states)
        .transpose()?;

    // The plugin must not write into the output of the tool
    let plugin_infos = console_silencer::run_silenced(|| {
        let module = PluginModule::load(&binary_path)?;
        plugin_inspector::inspect_plugin(&module.plugin_factory()?, displayed_values, preset_states, class_id)
    })
    .map_err(|error| format!("Failed to load or inspect plugin: {}", error))?;

    output::print_result(plugin_report::create_report(&plugin_infos));
    Ok(())
}
