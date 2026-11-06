//! Finds the binary of a VST3 plugin, which is either a single file or a bundle directory.

use std::path::{Path, PathBuf};

pub fn locate_plugin_binary(plugin_path: &Path) -> Result<PathBuf, String> {
    if plugin_path.is_file() {
        return Ok(plugin_path.to_path_buf());
    }

    if plugin_path.extension().is_none_or(|ext| ext != "vst3") {
        return Err("Invalid VST3 path".to_string());
    }

    find_binary_in_bundle(plugin_path)
}

#[cfg(target_os = "macos")]
fn find_binary_in_bundle(bundle_path: &Path) -> Result<PathBuf, String> {
    vst_tool_common::macos_bundle::find_bundle_binary(bundle_path)
}

#[cfg(target_os = "windows")]
fn find_binary_in_bundle(bundle_path: &Path) -> Result<PathBuf, String> {
    let architecture_directory = if cfg!(target_arch = "x86_64") {
        "x86_64-win"
    } else {
        "x86-win"
    };
    find_file_with_extension(
        &bundle_path.join("Contents").join(architecture_directory),
        "vst3",
    )
}

#[cfg(target_os = "linux")]
fn find_binary_in_bundle(bundle_path: &Path) -> Result<PathBuf, String> {
    let architecture_directory = if cfg!(target_arch = "x86_64") {
        "x86_64-linux"
    } else {
        "x86-linux"
    };
    find_file_with_extension(
        &bundle_path.join("Contents").join(architecture_directory),
        "so",
    )
}

#[cfg(not(target_os = "macos"))]
fn find_file_with_extension(directory: &Path, extension: &str) -> Result<PathBuf, String> {
    let entries = std::fs::read_dir(directory)
        .map_err(|error| format!("Can't read {}: {}", directory.display(), error))?;

    entries
        .flatten()
        .map(|entry| entry.path())
        .find(|path| path.is_file() && path.extension().is_some_and(|ext| ext == extension))
        .ok_or_else(|| format!("No .{} binary found in {}", extension, directory.display()))
}
