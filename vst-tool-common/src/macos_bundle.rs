//! Finds the binary inside of a macOS plugin bundle.

use std::fs;
use std::path::{Path, PathBuf};

/// The binary usually is named like the bundle, but it doesn't have to be.
pub fn find_bundle_binary(bundle_path: &Path) -> Result<PathBuf, String> {
    let binary_directory = bundle_path.join("Contents").join("MacOS");

    if let Some(bundle_name) = bundle_path.file_stem() {
        let expected_path = binary_directory.join(bundle_name);
        if expected_path.is_file() {
            return Ok(expected_path);
        }
    }

    let entries = fs::read_dir(&binary_directory)
        .map_err(|error| format!("Can't read {}: {}", binary_directory.display(), error))?;

    let mut binaries: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| is_binary_candidate(path))
        .collect();
    binaries.sort();

    binaries
        .into_iter()
        .next()
        .ok_or_else(|| format!("No binary found in bundle {}", bundle_path.display()))
}

fn is_binary_candidate(path: &Path) -> bool {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(".");

    path.is_file()
        && !file_name.starts_with('.')
        && !file_name.ends_with(".plist")
        && !file_name.ends_with(".txt")
}
