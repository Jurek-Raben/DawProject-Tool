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
        let library = unsafe { call_module_entry(library, binary_path)? };

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
unsafe fn call_module_entry(library: Library, _binary_path: &Path) -> Result<Library, String> {
    unsafe {
        if let Ok(init_dll) = library.get::<unsafe extern "system" fn() -> u8>(b"InitDll") {
            init_dll();
        }
    }
    Ok(library)
}

/// The Linux module entry of the VST3 specification, it needs the handle of the library.
#[cfg(target_os = "linux")]
unsafe fn call_module_entry(library: Library, _binary_path: &Path) -> Result<Library, String> {
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

/// The macOS module entry of the VST3 specification, it needs the bundle of the plugin.
/// Some plugins work without it, but others crash in GetPluginFactory, e.g. the ones made with DPF.
#[cfg(target_os = "macos")]
unsafe fn call_module_entry(library: Library, binary_path: &Path) -> Result<Library, String> {
    // the binary is located at <bundle>/Contents/MacOS/<binary>
    let Some(bundle_path) = binary_path.ancestors().nth(3) else {
        return Ok(library);
    };

    unsafe {
        if let Ok(bundle_entry) = library.get::<unsafe extern "C" fn(core_foundation::CFTypeRef) -> u8>(b"bundleEntry") {
            // The bundle is never released, just like the library
            let bundle = core_foundation::create_bundle(bundle_path)?;
            if bundle_entry(bundle) == 0 {
                return Err("bundleEntry returned false".to_string());
            }
        }
    }
    Ok(library)
}

#[cfg(target_os = "macos")]
mod core_foundation {
    use std::ffi::c_void;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr;

    pub type CFTypeRef = *const c_void;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFURLCreateFromFileSystemRepresentation(
            allocator: CFTypeRef,
            buffer: *const u8,
            length: isize,
            is_directory: u8,
        ) -> CFTypeRef;
        fn CFBundleCreate(allocator: CFTypeRef, bundle_url: CFTypeRef) -> CFTypeRef;
        fn CFRelease(object: CFTypeRef);
    }

    pub unsafe fn create_bundle(bundle_path: &Path) -> Result<CFTypeRef, String> {
        let path_bytes = bundle_path.as_os_str().as_bytes();
        unsafe {
            let url = CFURLCreateFromFileSystemRepresentation(
                ptr::null(),
                path_bytes.as_ptr(),
                path_bytes.len() as isize,
                1,
            );
            if url.is_null() {
                return Err(format!("Can't create the URL of {}", bundle_path.display()));
            }
            let bundle = CFBundleCreate(ptr::null(), url);
            CFRelease(url);
            if bundle.is_null() {
                return Err(format!("Can't open the bundle {}", bundle_path.display()));
            }
            Ok(bundle)
        }
    }
}
