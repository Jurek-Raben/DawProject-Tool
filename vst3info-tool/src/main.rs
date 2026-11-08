/*!
 * ------------------------------------------------------------------------
 * VST3 Info Extractor Tool
 * heavily based on rust-vst3-host by Helge Sverre
 * [https://github.com/HelgeSverre/rust-vst3-host](https://github.com/HelgeSverre/rust-vst3-host)
 *
 * by Jurek Raben
 *
 * Usage:
 *   vst3info-tool <plugin path> [--parameter-values] [--preset <preset path>]
 *   vst3info-tool --healthcheck [plugin paths...]
 *   vst3info-tool --migration-info <plugin path>
 * ------------------------------------------------------------------------
 */

mod console_silencer;
mod host_application;
mod memory_stream;
mod message_pump;
mod migration_info;
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

fn main() {
    let command = cli::parse_command(env::args_os().skip(1))
        .unwrap_or_else(|error| output::exit_with_error(&error));

    match command {
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

            let preset_path = find_preset_path(&additional_arguments)
                .unwrap_or_else(|error| output::exit_with_error(&error));

            read_plugin(&plugin_path, displayed_values, preset_path.as_deref())
                .unwrap_or_else(|error| output::exit_with_error(&error));
        }
    }
}

fn find_preset_path(additional_arguments: &[OsString]) -> Result<Option<PathBuf>, String> {
    let Some(switch_index) = additional_arguments
        .iter()
        .position(|argument| argument == PRESET_SWITCH)
    else {
        return Ok(None);
    };

    additional_arguments
        .get(switch_index + 1)
        .map(|path| Some(PathBuf::from(path)))
        .ok_or_else(|| "The preset switch needs the path of a preset".to_string())
}

fn read_plugin(
    plugin_path: &Path,
    displayed_values: DisplayedValues,
    preset_path: Option<&Path>,
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
        plugin_inspector::inspect_plugin(&module.plugin_factory()?, displayed_values, preset_states)
    })
    .map_err(|error| format!("Failed to load or inspect plugin: {}", error))?;

    output::print_result(plugin_report::create_report(&plugin_infos));
    Ok(())
}
