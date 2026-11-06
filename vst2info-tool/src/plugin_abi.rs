//! The binary interface between a VST2 plugin and its host.

use std::ffi::c_void;

pub const VST_MAGIC: i32 = i32::from_be_bytes(*b"VstP");

/// Older plugins don't export the current entry point.
pub const ENTRY_POINT_NAMES: [&[u8]; 4] = [b"VSTPluginMain", b"main", b"MAIN", b"main_macho"];

/// Opcodes the host sends to the plugin.
pub mod plugin_opcode {
    pub const OPEN: i32 = 0;
    pub const CLOSE: i32 = 1;
    pub const GET_CATEGORY: i32 = 35;
    pub const GET_EFFECT_NAME: i32 = 45;
    pub const GET_VENDOR_STRING: i32 = 47;
    pub const GET_PRODUCT_STRING: i32 = 48;
    pub const SHELL_GET_NEXT_PLUGIN: i32 = 70;
}

/// Opcodes the plugin sends to the host.
pub mod host_opcode {
    pub const VERSION: i32 = 1;
    pub const CURRENT_ID: i32 = 2;
    pub const GET_SAMPLE_RATE: i32 = 16;
    pub const GET_BLOCK_SIZE: i32 = 17;
    pub const GET_VENDOR_STRING: i32 = 32;
    pub const GET_PRODUCT_STRING: i32 = 33;
    pub const GET_VENDOR_VERSION: i32 = 34;
    pub const CAN_DO: i32 = 37;
}

pub const CATEGORY_SHELL: isize = 10;

pub type DispatcherProc =
    unsafe extern "C" fn(*mut AEffect, i32, i32, isize, *mut c_void, f32) -> isize;
pub type HostCallbackProc =
    unsafe extern "C" fn(*mut AEffect, i32, i32, isize, *mut c_void, f32) -> isize;
pub type PluginMainProc = unsafe extern "C" fn(HostCallbackProc) -> *mut AEffect;

/// The beginning of the VST2 AEffect struct. It is only read through the pointer provided by the
/// plugin, so the following fields are not required.
#[allow(dead_code)]
#[repr(C)]
pub struct AEffect {
    pub magic: i32,
    pub dispatcher: Option<DispatcherProc>,
    pub process: *mut c_void,
    pub set_parameter: *mut c_void,
    pub get_parameter: *mut c_void,
    pub num_programs: i32,
    pub num_params: i32,
    pub num_inputs: i32,
    pub num_outputs: i32,
    pub flags: i32,
    pub reserved1: isize,
    pub reserved2: isize,
    pub initial_delay: i32,
    pub real_qualities: i32,
    pub off_qualities: i32,
    pub io_ratio: f32,
    pub object: *mut c_void,
    pub user: *mut c_void,
    pub unique_id: i32,
    pub version: i32,
}
