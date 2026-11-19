//! Finds the binary inside of a macOS plugin bundle.

use std::fs;
use std::path::{Path, PathBuf};

/// The binary is defined by CFBundleExecutable in the Info.plist. It usually is named like the bundle,
/// but it doesn't have to be.
pub fn find_bundle_binary(bundle_path: &Path) -> Result<PathBuf, String> {
    if let Some(executable_path) = core_foundation::bundle_executable(bundle_path) {
        if executable_path.is_file() {
            return Ok(executable_path);
        }
    }

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
        && !file_name.ends_with(".dylib")
}

/// Reads the executable of a bundle via CoreFoundation, which handles both XML and binary Info.plist files.
mod core_foundation {
    use std::ffi::{OsStr, c_void};
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Path, PathBuf};
    use std::ptr;

    type CFTypeRef = *const c_void;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFURLCreateFromFileSystemRepresentation(
            allocator: CFTypeRef,
            buffer: *const u8,
            length: isize,
            is_directory: u8,
        ) -> CFTypeRef;
        fn CFURLGetFileSystemRepresentation(
            url: CFTypeRef,
            resolve_against_base: u8,
            buffer: *mut u8,
            max_length: isize,
        ) -> u8;
        fn CFBundleCreate(allocator: CFTypeRef, bundle_url: CFTypeRef) -> CFTypeRef;
        fn CFBundleCopyExecutableURL(bundle: CFTypeRef) -> CFTypeRef;
        fn CFRelease(object: CFTypeRef);
    }

    pub fn bundle_executable(bundle_path: &Path) -> Option<PathBuf> {
        let path_bytes = bundle_path.as_os_str().as_bytes();
        unsafe {
            let bundle_url = CFURLCreateFromFileSystemRepresentation(
                ptr::null(),
                path_bytes.as_ptr(),
                path_bytes.len() as isize,
                1,
            );
            if bundle_url.is_null() {
                return None;
            }
            let bundle = CFBundleCreate(ptr::null(), bundle_url);
            CFRelease(bundle_url);
            if bundle.is_null() {
                return None;
            }
            let executable_url = CFBundleCopyExecutableURL(bundle);
            CFRelease(bundle);
            if executable_url.is_null() {
                return None;
            }

            let mut buffer = vec![0u8; 4096];
            let success = CFURLGetFileSystemRepresentation(
                executable_url,
                1,
                buffer.as_mut_ptr(),
                buffer.len() as isize,
            );
            CFRelease(executable_url);
            if success == 0 {
                return None;
            }

            let length = buffer.iter().position(|&byte| byte == 0)?;
            Some(PathBuf::from(OsStr::from_bytes(&buffer[..length])))
        }
    }
}
