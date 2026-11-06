//! Finds the binary of a VST2 plugin.

use std::path::{Path, PathBuf};

pub fn locate_plugin_binary(plugin_path: &Path) -> Result<PathBuf, String> {
    #[cfg(target_os = "macos")]
    if plugin_path.is_dir() && plugin_path.extension().is_some_and(|ext| ext == "vst") {
        return vst_tool_common::macos_bundle::find_bundle_binary(plugin_path);
    }

    if plugin_path.is_file() {
        Ok(plugin_path.to_path_buf())
    } else {
        Err(format!("{} does not exist", plugin_path.display()))
    }
}
