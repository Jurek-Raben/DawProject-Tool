/*!
 * ------------------------------------------------------------------------
 * VST3 Info Extractor Tool
 * heavily based on rust-vst3-host by Helge Sverre
 * [https://github.com/HelgeSverre/rust-vst3-host](https://github.com/HelgeSverre/rust-vst3-host)
 *
 * by Jurek Raben
 *
 * Usage:
 *   vst3info-tool <plugin path>
 *   vst3info-tool --healthcheck [plugin paths...]
 * ------------------------------------------------------------------------
 */

mod console_silencer;
mod host_application;
mod plugin_binary;
mod plugin_inspector;
mod plugin_module;
mod plugin_report;
mod vst3_strings;

use plugin_module::PluginModule;
use std::env;
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
        Command::ReadPlugin { plugin_path, .. } => {
            read_plugin(&plugin_path).unwrap_or_else(|error| output::exit_with_error(&error));
        }
    }
}

fn read_plugin(plugin_path: &Path) -> Result<(), String> {
    let binary_path = plugin_binary::locate_plugin_binary(plugin_path).map_err(|error| {
        format!(
            "Path does not exist or is invalid ({}): {}",
            plugin_path.display(),
            error
        )
    })?;

    // The plugin must not write into the output of the tool
    let plugin_infos = console_silencer::run_silenced(|| {
        let module = PluginModule::load(&binary_path)?;
        plugin_inspector::inspect_plugin(&module.plugin_factory()?)
    })
    .map_err(|error| format!("Failed to load or inspect plugin: {}", error))?;

    output::print_result(plugin_report::create_report(&plugin_infos));
    Ok(())
}
