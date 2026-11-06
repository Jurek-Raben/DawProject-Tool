//! Loads the binary of a plugin.

use libloading::Library;
use std::path::Path;

#[cfg(unix)]
pub fn load_library(path: &Path) -> Result<Library, String> {
    unsafe { Library::new(path) }.map_err(|error| format!("Failed to load library: {}", error))
}

/// Plugins may ship DLLs next to their binary, these are only found with the altered search path.
#[cfg(windows)]
pub fn load_library(path: &Path) -> Result<Library, String> {
    use libloading::os::windows::{LOAD_WITH_ALTERED_SEARCH_PATH, Library as WindowsLibrary};

    unsafe { WindowsLibrary::load_with_flags(path, LOAD_WITH_ALTERED_SEARCH_PATH) }
        .map(Library::from)
        .map_err(|error| format!("Failed to load library: {}", error))
}
