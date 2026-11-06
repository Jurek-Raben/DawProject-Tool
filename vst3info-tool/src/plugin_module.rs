//! A loaded VST3 module, which provides the factory for creating the classes of the plugin.

use libloading::Library;
use std::mem::ManuallyDrop;
use std::path::Path;
use vst3::ComPtr;
use vst3::Steinberg::IPluginFactory;
use vst_tool_common::library_loader;

pub struct PluginModule {
    // Never unloaded on purpose, since plugins may crash on unload and the process exits right after
    library: ManuallyDrop<Library>,
}

impl PluginModule {
    pub fn load(binary_path: &Path) -> Result<Self, String> {
        let library = library_loader::load_library(binary_path)?;
        let library = unsafe { call_module_entry(library)? };

        Ok(Self {
            library: ManuallyDrop::new(library),
        })
    }

    pub fn plugin_factory(&self) -> Result<ComPtr<IPluginFactory>, String> {
        unsafe {
            let get_plugin_factory = self
                .library
                .get::<unsafe extern "C" fn() -> *mut IPluginFactory>(b"GetPluginFactory")
                .map_err(|error| format!("GetPluginFactory not found: {}", error))?;

            ComPtr::from_raw(get_plugin_factory())
                .ok_or_else(|| "GetPluginFactory returned NULL".to_string())
        }
    }
}

/// The optional Windows module entry of the VST3 specification.
#[cfg(windows)]
unsafe fn call_module_entry(library: Library) -> Result<Library, String> {
    unsafe {
        if let Ok(init_dll) = library.get::<unsafe extern "system" fn() -> u8>(b"InitDll") {
            init_dll();
        }
    }
    Ok(library)
}

/// The Linux module entry of the VST3 specification, it needs the handle of the library.
#[cfg(target_os = "linux")]
unsafe fn call_module_entry(library: Library) -> Result<Library, String> {
    use libloading::os::unix::Library as UnixLibrary;
    use std::ffi::c_void;

    let handle = UnixLibrary::from(library).into_raw();
    let library = unsafe { UnixLibrary::from_raw(handle) };

    unsafe {
        if let Ok(module_entry) = library.get::<unsafe extern "C" fn(*mut c_void) -> u8>(b"ModuleEntry")
        {
            if module_entry(handle) == 0 {
                std::mem::forget(library);
                return Err("ModuleEntry returned false".to_string());
            }
        }
    }

    Ok(Library::from(library))
}

/// macOS plugins are initialized by the system while their bundle is loaded.
#[cfg(target_os = "macos")]
unsafe fn call_module_entry(library: Library) -> Result<Library, String> {
    Ok(library)
}
