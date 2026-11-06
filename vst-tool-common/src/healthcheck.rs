//! The health check of the VST info tools.
//!
//! Reaching this code already proves that the operating system lets the tool start. The plugins
//! are only opened as files and never loaded, so a broken plugin can't crash the health check.

use crate::output;
use json::{JsonValue, object};
use std::env;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::exit;

/// How a tool finds the binary of a plugin, which differs between the plugin formats.
pub type PluginBinaryLocator = fn(&Path) -> Result<PathBuf, String>;

pub struct ToolIdentity {
    pub name: &'static str,
    pub version: &'static str,
}

/// Prints the report and exits, with a failing exit code if a plugin can't be accessed.
pub fn run(
    tool: ToolIdentity,
    plugin_paths: &[PathBuf],
    locate_plugin_binary: PluginBinaryLocator,
) -> ! {
    let mut plugin_reports = JsonValue::new_array();
    let mut all_plugins_accessible = true;

    for plugin_path in plugin_paths {
        let access_result = check_plugin_access(plugin_path, locate_plugin_binary);
        all_plugins_accessible &= access_result.is_ok();
        let _ = plugin_reports.push(create_plugin_report(plugin_path, access_result));
    }

    output::print_result(object! {
        healthy: all_plugins_accessible,
        tool: tool.name,
        version: tool.version,
        os: env::consts::OS,
        arch: env::consts::ARCH,
        plugins: plugin_reports
    });

    exit(if all_plugins_accessible { 0 } else { 1 });
}

fn check_plugin_access(
    plugin_path: &Path,
    locate_plugin_binary: PluginBinaryLocator,
) -> Result<(), String> {
    fs::metadata(plugin_path).map_err(|error| error.to_string())?;
    let binary_path = locate_plugin_binary(plugin_path)?;
    File::open(&binary_path)
        .map_err(|error| format!("Can't read {}: {}", binary_path.display(), error))?;
    Ok(())
}

fn create_plugin_report(plugin_path: &Path, access_result: Result<(), String>) -> JsonValue {
    let mut report = object! {
        path: plugin_path.to_string_lossy().to_string(),
        accessible: access_result.is_ok()
    };
    if let Err(error) = access_result {
        report["error"] = error.into();
    }
    report
}
