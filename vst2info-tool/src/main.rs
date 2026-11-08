/*!
 * ------------------------------------------------------------------------
 * VST2 Info Extractor Tool
 * by Jurek Raben
 *
 * Usage:
 *   vst2info-tool <plugin path> [id of a plugin inside of a shell]
 *   vst2info-tool --healthcheck [plugin paths...]
 *
 * Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
 * Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
 * ------------------------------------------------------------------------
 */

mod host_callback;
mod plugin_abi;
mod plugin_binary;
mod plugin_instance;
mod plugin_report;

use plugin_instance::PluginInstance;
use std::env;
use std::ffi::OsString;
use std::path::Path;
use vst_tool_common::cli::{self, Command};
use vst_tool_common::healthcheck::{self, ToolIdentity};
use vst_tool_common::output;

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
        // only a newer plugin knows the older plugins it replaces
        Command::MigrationInfo { .. } => {
            output::exit_with_error("The migration info is only available for VST3 plugins")
        }
        Command::ReadPlugin {
            plugin_path,
            additional_arguments,
        } => {
            let shell_plugin_id = parse_shell_plugin_id(&additional_arguments)
                .unwrap_or_else(|error| output::exit_with_error(&error));

            read_plugin(&plugin_path, shell_plugin_id)
                .unwrap_or_else(|error| output::exit_with_error(&error));
        }
    }
}

fn parse_shell_plugin_id(additional_arguments: &[OsString]) -> Result<Option<i32>, String> {
    let Some(argument) = additional_arguments.first() else {
        return Ok(None);
    };

    argument
        .to_str()
        .and_then(|id| id.parse().ok())
        .map(Some)
        .ok_or_else(|| "The shell plugin id has to be a number".to_string())
}

fn read_plugin(plugin_path: &Path, shell_plugin_id: Option<i32>) -> Result<(), String> {
    let binary_path = plugin_binary::locate_plugin_binary(plugin_path)?;
    let plugin = PluginInstance::create(&binary_path, shell_plugin_id)?;

    plugin.open();

    // Print before closing the plugin, so a plugin crashing on shutdown can't lose the result
    output::print_result(plugin_report::create_report(&plugin, shell_plugin_id));

    plugin.close();
    Ok(())
}
