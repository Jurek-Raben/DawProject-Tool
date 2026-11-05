/*!
 * ------------------------------------------------------------------------
 * VST2 Info Extractor Tool
 * by Jurek Raben
 *
 * Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
 * Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
 * ------------------------------------------------------------------------
 */

use json::object;
use libloading::Library;
use std::env;
use std::ffi::{CStr, c_char, c_void};
use std::path::{Path, PathBuf};
use std::process::exit;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

const VST_MAGIC: i32 = i32::from_be_bytes(*b"VstP");

// Plugins may print to the console by themselves, so the result is enclosed by unique markers
const OUTPUT_BEGIN: &str = "@@VSTINFO_BEGIN@@";
const OUTPUT_END: &str = "@@VSTINFO_END@@";

// Opcodes the host sends to the plugin
const PLUGIN_OPEN: i32 = 0;
const PLUGIN_CLOSE: i32 = 1;
const PLUGIN_GET_CATEGORY: i32 = 35;
const PLUGIN_GET_EFFECT_NAME: i32 = 45;
const PLUGIN_GET_VENDOR_STRING: i32 = 47;
const PLUGIN_GET_PRODUCT_STRING: i32 = 48;
const PLUGIN_SHELL_GET_NEXT: i32 = 70;

const CATEGORY_SHELL: isize = 10;

// Opcodes the plugin sends to the host
const HOST_VERSION: i32 = 1;
const HOST_CURRENT_ID: i32 = 2;
const HOST_GET_SAMPLE_RATE: i32 = 16;
const HOST_GET_BLOCK_SIZE: i32 = 17;
const HOST_GET_VENDOR_STRING: i32 = 32;
const HOST_GET_PRODUCT_STRING: i32 = 33;
const HOST_GET_VENDOR_VERSION: i32 = 34;
const HOST_CAN_DO: i32 = 37;

const HOST_NAME: &[u8] = b"DawProject Tool\0";

// Safety limit for broken shell plugins, which never report the end of their list
const MAX_SHELL_PLUGINS: usize = 4096;

// The id of the plugin a shell has to create, it asks for it while the entry point is running
static CURRENT_SHELL_ID: AtomicI32 = AtomicI32::new(0);

// Older plugins don't export the current entry point
const ENTRY_POINTS: [&[u8]; 4] = [b"VSTPluginMain", b"main", b"MAIN", b"main_macho"];

// Plugin strings are limited to 64 bytes, the rest is a safety margin for broken plugins
const STRING_BUFFER_SIZE: usize = 256;

type DispatcherProc =
    unsafe extern "C" fn(*mut AEffect, i32, i32, isize, *mut c_void, f32) -> isize;
type HostCallbackProc =
    unsafe extern "C" fn(*mut AEffect, i32, i32, isize, *mut c_void, f32) -> isize;
type PluginMainProc = unsafe extern "C" fn(HostCallbackProc) -> *mut AEffect;

// The beginning of the VST2 AEffect struct. It is only read through the pointer provided by the
// plugin, so the following fields are not required.
#[allow(dead_code)]
#[repr(C)]
struct AEffect {
    magic: i32,
    dispatcher: Option<DispatcherProc>,
    process: *mut c_void,
    set_parameter: *mut c_void,
    get_parameter: *mut c_void,
    num_programs: i32,
    num_params: i32,
    num_inputs: i32,
    num_outputs: i32,
    flags: i32,
    reserved1: isize,
    reserved2: isize,
    initial_delay: i32,
    real_qualities: i32,
    off_qualities: i32,
    io_ratio: f32,
    object: *mut c_void,
    user: *mut c_void,
    unique_id: i32,
    version: i32,
}

unsafe extern "C" fn host_callback(
    _effect: *mut AEffect,
    opcode: i32,
    _index: i32,
    _value: isize,
    ptr: *mut c_void,
    _opt: f32,
) -> isize {
    match opcode {
        HOST_VERSION => 2400,
        HOST_CURRENT_ID => CURRENT_SHELL_ID.load(Ordering::SeqCst) as isize,
        HOST_CAN_DO => {
            if ptr.is_null() {
                return 0;
            }
            let capability = unsafe { CStr::from_ptr(ptr as *const c_char) };
            (capability.to_bytes() == b"shellCategory") as isize
        }
        HOST_GET_SAMPLE_RATE => 44100,
        HOST_GET_BLOCK_SIZE => 512,
        HOST_GET_VENDOR_VERSION => 1,
        HOST_GET_VENDOR_STRING | HOST_GET_PRODUCT_STRING => {
            if ptr.is_null() {
                return 0;
            }
            unsafe {
                ptr::copy_nonoverlapping(HOST_NAME.as_ptr(), ptr as *mut u8, HOST_NAME.len());
            }
            1
        }
        _ => 0,
    }
}

fn format_output(output: json::JsonValue) -> String {
    format!("{}{}{}", OUTPUT_BEGIN, json::stringify(output), OUTPUT_END)
}

fn error_exit(error_message: &str) -> ! {
    eprintln!("{}", format_output(object! { error: error_message }));
    exit(1);
}

// The binary of a macOS bundle usually is named like the bundle, but it doesn't have to be
#[cfg(target_os = "macos")]
fn find_bundle_binary(bundle_path: &Path) -> Option<PathBuf> {
    let binary_directory = bundle_path.join("Contents").join("MacOS");

    if let Some(bundle_name) = bundle_path.file_stem() {
        let expected_path = binary_directory.join(bundle_name);
        if expected_path.is_file() {
            return Some(expected_path);
        }
    }

    let mut binaries: Vec<PathBuf> = std::fs::read_dir(&binary_directory)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            let name = path.file_name().and_then(|name| name.to_str()).unwrap_or(".");
            path.is_file()
                && !name.starts_with('.')
                && !name.ends_with(".plist")
                && !name.ends_with(".txt")
        })
        .collect();
    binaries.sort();
    binaries.into_iter().next()
}

fn get_binary_path(plugin_path: PathBuf) -> Result<PathBuf, String> {
    #[cfg(target_os = "macos")]
    if plugin_path.is_dir() && plugin_path.extension().is_some_and(|ext| ext == "vst") {
        return find_bundle_binary(&plugin_path)
            .ok_or_else(|| format!("No binary found in bundle {}", plugin_path.display()));
    }

    if plugin_path.is_file() {
        Ok(plugin_path)
    } else {
        Err(format!("{} does not exist", plugin_path.display()))
    }
}

#[cfg(unix)]
fn load_library(path: &Path) -> Result<Library, String> {
    unsafe { Library::new(path) }.map_err(|e| format!("Failed to load library: {}", e))
}

// Plugins may ship DLLs next to their binary, these are only found with the altered search path
#[cfg(windows)]
fn load_library(path: &Path) -> Result<Library, String> {
    use libloading::os::windows::{LOAD_WITH_ALTERED_SEARCH_PATH, Library as WindowsLibrary};

    unsafe { WindowsLibrary::load_with_flags(path, LOAD_WITH_ALTERED_SEARCH_PATH) }
        .map(Library::from)
        .map_err(|e| format!("Failed to load library: {}", e))
}

fn find_entry_point(library: &Library) -> Option<PluginMainProc> {
    ENTRY_POINTS.iter().find_map(|name| {
        unsafe { library.get::<PluginMainProc>(name) }
            .ok()
            .map(|symbol| *symbol)
    })
}

unsafe fn read_plugin_string(
    effect: *mut AEffect,
    dispatcher: DispatcherProc,
    opcode: i32,
) -> String {
    let mut buffer = [0u8; STRING_BUFFER_SIZE];
    unsafe {
        dispatcher(effect, opcode, 0, 0, buffer.as_mut_ptr() as *mut c_void, 0.0);
    }

    // A broken plugin may not terminate its string, so the end of the buffer is always kept
    buffer[STRING_BUFFER_SIZE - 1] = 0;
    CStr::from_bytes_until_nul(&buffer)
        .map(|string| string.to_string_lossy().trim().to_string())
        .unwrap_or_default()
}

// Reads the plugins contained in a shell, as a list of their ids and names
unsafe fn read_shell_plugins(effect: *mut AEffect, dispatcher: DispatcherProc) -> Vec<(i32, String)> {
    let mut shell_plugins = Vec::new();

    while shell_plugins.len() < MAX_SHELL_PLUGINS {
        let mut buffer = [0u8; STRING_BUFFER_SIZE];
        let id = unsafe {
            dispatcher(
                effect,
                PLUGIN_SHELL_GET_NEXT,
                0,
                0,
                buffer.as_mut_ptr() as *mut c_void,
                0.0,
            )
        } as i32;
        if id == 0 {
            break;
        }

        buffer[STRING_BUFFER_SIZE - 1] = 0;
        let name = CStr::from_bytes_until_nul(&buffer)
            .map(|string| string.to_string_lossy().trim().to_string())
            .unwrap_or_default();
        shell_plugins.push((id, name));
    }

    shell_plugins
}

// Usage: vst2info-tool <plugin path> [id of a plugin inside of a shell]
fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        error_exit("Plugin path required as first argument");
    }

    let shell_plugin_id = args.get(2).map(|id| match id.parse::<i32>() {
        Ok(id) => id,
        Err(_) => error_exit("The shell plugin id has to be a number"),
    });
    CURRENT_SHELL_ID.store(shell_plugin_id.unwrap_or(0), Ordering::SeqCst);

    let binary_path = match get_binary_path(PathBuf::from(&args[1])) {
        Ok(path) => path,
        Err(error) => error_exit(&error),
    };

    let library = match load_library(&binary_path) {
        Ok(library) => library,
        Err(error) => error_exit(&error),
    };

    let plugin_main = match find_entry_point(&library) {
        Some(entry_point) => entry_point,
        None => error_exit("No VST2 entry point found"),
    };

    let effect = unsafe { plugin_main(host_callback) };
    if effect.is_null() {
        error_exit("Plugin returned no instance");
    }

    let (magic, dispatcher) = unsafe { ((*effect).magic, (*effect).dispatcher) };
    if magic != VST_MAGIC {
        error_exit("Plugin instance is not a VST2 effect");
    }
    let dispatcher = match dispatcher {
        Some(dispatcher) => dispatcher,
        None => error_exit("Plugin instance has no dispatcher"),
    };

    unsafe {
        dispatcher(effect, PLUGIN_OPEN, 0, 0, ptr::null_mut(), 0.0);
    }

    let (name, vendor, info) = unsafe {
        let mut name = read_plugin_string(effect, dispatcher, PLUGIN_GET_PRODUCT_STRING);
        if name.is_empty() {
            name = read_plugin_string(effect, dispatcher, PLUGIN_GET_EFFECT_NAME);
        }
        let vendor = read_plugin_string(effect, dispatcher, PLUGIN_GET_VENDOR_STRING);
        (name, vendor, &*effect)
    };

    let mut output = object! {
        name: name,
        vendor: vendor,
        countPresets: info.num_programs,
        countParameters: info.num_params,
        countInputs: info.num_inputs,
        countOutputs: info.num_outputs,
        id: info.unique_id,
        version: info.version,
        delay: info.initial_delay,
        os: env::consts::OS
    };

    if let Some(id) = shell_plugin_id.filter(|_| info.unique_id == 0) {
        output["id"] = id.into();
    }

    // Without a selected plugin, a shell only reports the plugins it contains
    let category =
        unsafe { dispatcher(effect, PLUGIN_GET_CATEGORY, 0, 0, ptr::null_mut(), 0.0) };
    if shell_plugin_id.is_none() && category == CATEGORY_SHELL {
        let mut shell_plugins = json::JsonValue::new_array();
        for (id, name) in unsafe { read_shell_plugins(effect, dispatcher) } {
            let _ = shell_plugins.push(object! { id: id, name: name });
        }
        output["shellPlugins"] = shell_plugins;
    }

    // Print before closing the plugin, so a plugin crashing on shutdown can't lose the result
    println!("{}", format_output(output));

    unsafe {
        dispatcher(effect, PLUGIN_CLOSE, 0, 0, ptr::null_mut(), 0.0);
    }

    // The library is never unloaded on purpose, since plugins may crash on unload
    // and the process exits right after.
    std::mem::forget(library);
}
