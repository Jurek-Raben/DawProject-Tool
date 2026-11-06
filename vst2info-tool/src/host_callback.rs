//! Answers the questions a plugin asks its host.

use crate::plugin_abi::{AEffect, host_opcode};
use std::ffi::{CStr, c_char, c_void};
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

const HOST_NAME: &[u8] = b"DawProject Tool\0";
const HOST_VST_VERSION: isize = 2400;
const HOST_VENDOR_VERSION: isize = 1;
const HOST_SAMPLE_RATE: isize = 44100;
const HOST_BLOCK_SIZE: isize = 512;
const SHELL_CAPABILITY: &[u8] = b"shellCategory";

// The id of the plugin a shell has to create, it asks for it while the entry point is running
static SELECTED_SHELL_PLUGIN_ID: AtomicI32 = AtomicI32::new(0);

pub fn select_shell_plugin(id: Option<i32>) {
    SELECTED_SHELL_PLUGIN_ID.store(id.unwrap_or(0), Ordering::SeqCst);
}

pub unsafe extern "C" fn host_callback(
    _effect: *mut AEffect,
    opcode: i32,
    _index: i32,
    _value: isize,
    pointer: *mut c_void,
    _option: f32,
) -> isize {
    match opcode {
        host_opcode::VERSION => HOST_VST_VERSION,
        host_opcode::CURRENT_ID => SELECTED_SHELL_PLUGIN_ID.load(Ordering::SeqCst) as isize,
        host_opcode::CAN_DO => unsafe { supports_capability(pointer) },
        host_opcode::GET_SAMPLE_RATE => HOST_SAMPLE_RATE,
        host_opcode::GET_BLOCK_SIZE => HOST_BLOCK_SIZE,
        host_opcode::GET_VENDOR_VERSION => HOST_VENDOR_VERSION,
        host_opcode::GET_VENDOR_STRING | host_opcode::GET_PRODUCT_STRING => unsafe {
            write_host_name(pointer)
        },
        _ => 0,
    }
}

unsafe fn supports_capability(capability: *mut c_void) -> isize {
    if capability.is_null() {
        return 0;
    }
    let capability = unsafe { CStr::from_ptr(capability as *const c_char) };
    (capability.to_bytes() == SHELL_CAPABILITY) as isize
}

unsafe fn write_host_name(target: *mut c_void) -> isize {
    if target.is_null() {
        return 0;
    }
    unsafe {
        ptr::copy_nonoverlapping(HOST_NAME.as_ptr(), target as *mut u8, HOST_NAME.len());
    }
    1
}
