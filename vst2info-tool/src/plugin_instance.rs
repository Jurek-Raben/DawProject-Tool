//! A created VST2 plugin and the calls the tool makes to it.

use crate::host_callback::{self, host_callback};
use crate::plugin_abi::{
    AEffect, CATEGORY_SHELL, DispatcherProc, ENTRY_POINT_NAMES, PluginMainProc, VST_MAGIC,
    plugin_opcode,
};
use libloading::Library;
use std::ffi::{CStr, c_void};
use std::mem::ManuallyDrop;
use std::path::Path;
use std::ptr;
use vst_tool_common::library_loader;

// Plugin strings are limited to 64 bytes, the rest is a safety margin for broken plugins
const STRING_BUFFER_SIZE: usize = 256;

// Safety limit for broken shell plugins, which never report the end of their list
const MAX_SHELL_PLUGINS: usize = 4096;

pub struct ShellPlugin {
    pub id: i32,
    pub name: String,
}

pub struct PluginInstance {
    effect: *mut AEffect,
    dispatcher: DispatcherProc,
    // Never unloaded on purpose, since plugins may crash on unload and the process exits right after
    _library: ManuallyDrop<Library>,
}

impl PluginInstance {
    pub fn create(binary_path: &Path, shell_plugin_id: Option<i32>) -> Result<Self, String> {
        host_callback::select_shell_plugin(shell_plugin_id);

        let library = ManuallyDrop::new(library_loader::load_library(binary_path)?);
        let plugin_main = find_entry_point(&library).ok_or("No VST2 entry point found")?;

        let effect = unsafe { plugin_main(host_callback) };
        if effect.is_null() {
            return Err("Plugin returned no instance".to_string());
        }

        let (magic, dispatcher) = unsafe { ((*effect).magic, (*effect).dispatcher) };
        if magic != VST_MAGIC {
            return Err("Plugin instance is not a VST2 effect".to_string());
        }

        Ok(Self {
            effect,
            dispatcher: dispatcher.ok_or("Plugin instance has no dispatcher")?,
            _library: library,
        })
    }

    pub fn open(&self) {
        self.dispatch(plugin_opcode::OPEN, ptr::null_mut());
    }

    pub fn close(&self) {
        self.dispatch(plugin_opcode::CLOSE, ptr::null_mut());
    }

    pub fn effect(&self) -> &AEffect {
        unsafe { &*self.effect }
    }

    pub fn name(&self) -> String {
        let product_name = self.read_string(plugin_opcode::GET_PRODUCT_STRING);
        if product_name.is_empty() {
            self.read_string(plugin_opcode::GET_EFFECT_NAME)
        } else {
            product_name
        }
    }

    pub fn vendor(&self) -> String {
        self.read_string(plugin_opcode::GET_VENDOR_STRING)
    }

    pub fn is_shell(&self) -> bool {
        self.dispatch(plugin_opcode::GET_CATEGORY, ptr::null_mut()) == CATEGORY_SHELL
    }

    pub fn read_shell_plugins(&self) -> Vec<ShellPlugin> {
        let mut shell_plugins = Vec::new();

        while shell_plugins.len() < MAX_SHELL_PLUGINS {
            let (result, name) = self.dispatch_with_string(plugin_opcode::SHELL_GET_NEXT_PLUGIN);
            let id = result as i32;
            if id == 0 {
                break;
            }
            shell_plugins.push(ShellPlugin { id, name });
        }

        shell_plugins
    }

    fn read_string(&self, opcode: i32) -> String {
        self.dispatch_with_string(opcode).1
    }

    fn dispatch_with_string(&self, opcode: i32) -> (isize, String) {
        let mut buffer = [0u8; STRING_BUFFER_SIZE];
        let result = self.dispatch(opcode, buffer.as_mut_ptr() as *mut c_void);
        (result, string_from_buffer(&mut buffer))
    }

    fn dispatch(&self, opcode: i32, pointer: *mut c_void) -> isize {
        unsafe { (self.dispatcher)(self.effect, opcode, 0, 0, pointer, 0.0) }
    }
}

fn find_entry_point(library: &Library) -> Option<PluginMainProc> {
    ENTRY_POINT_NAMES.iter().find_map(|name| {
        unsafe { library.get::<PluginMainProc>(name) }
            .ok()
            .map(|symbol| *symbol)
    })
}

fn string_from_buffer(buffer: &mut [u8; STRING_BUFFER_SIZE]) -> String {
    // A broken plugin may not terminate its string, so the end of the buffer is always kept
    buffer[STRING_BUFFER_SIZE - 1] = 0;

    CStr::from_bytes_until_nul(buffer)
        .map(|string| string.to_string_lossy().trim().to_string())
        .unwrap_or_default()
}
