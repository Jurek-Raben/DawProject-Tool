/*!
* ------------------------------------------------------------------------
* VST3 Info Extractor Tool
* heavily based on rust-vst3-host by Helge Sverre
* [https://github.com/HelgeSverre/rust-vst3-host](https://github.com/HelgeSverre/rust-vst3-host)
*
* by Jurek Raben
* ------------------------------------------------------------------------
*/

#![allow(deprecated)]
#![allow(non_upper_case_globals)]
#![allow(non_snake_case)]

use json::object;
use std::env;
use std::path::PathBuf;
use std::process::exit;
use std::ptr;
use std::sync::atomic::{AtomicU32, Ordering};
use vst3::Steinberg::FUnknown;
use vst3::Steinberg::IPluginFactoryTrait;
use vst3::Steinberg::TUID;
use vst3::Steinberg::Vst::String128;
use vst3::Steinberg::Vst::{
    BusDirections_::*, IAudioProcessor, IComponent, IComponentTrait, IConnectionPoint,
    IConnectionPointTrait, IEditController, IEditControllerTrait, MediaTypes_::*,
};
use vst3::Steinberg::{IPluginBaseTrait, IPluginFactory, kNoInterface, kResultOk, tresult};
use vst3::{ComPtr, Interface};

// Platform-specific imports
#[cfg(unix)]
use libloading::os::unix::{Library, Symbol};
#[cfg(windows)]
use libloading::{Library, Symbol};
#[cfg(windows)]
use std::ffi::OsStr;
#[cfg(windows)]
use std::iter::once;

// Custom error type for better error handling
#[derive(Debug)]
enum PluginError {
    LoadError(String),
    InitError(String),
    FactoryError(String),
    ComponentError(String),
    PathError(String),
}

impl std::fmt::Display for PluginError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            PluginError::LoadError(msg) => write!(f, "Load error: {}", msg),
            PluginError::InitError(msg) => write!(f, "Initialization error: {}", msg),
            PluginError::FactoryError(msg) => write!(f, "Factory error: {}", msg),
            PluginError::ComponentError(msg) => write!(f, "Component error: {}", msg),
            PluginError::PathError(msg) => write!(f, "Path error: {}", msg),
        }
    }
}

impl std::error::Error for PluginError {}

#[derive(Debug, Clone)]
struct PluginInfo {
    factory_info: FactoryInfo,
    classes: Vec<ClassInfo>,
    component_info: Option<ComponentInfo>,
    controller_info: Option<ControllerInfo>,
    name: String,
    version: String,
}

#[derive(Debug, Clone)]
struct FactoryInfo {
    vendor: String,
    url: String,
    email: String,
    flags: i32,
}

#[derive(Debug, Clone)]
struct ClassInfo {
    name: String,
    category: String,
    class_id: String,
    cardinality: i32,
}

#[derive(Debug, Clone)]
struct ComponentInfo {
    bus_count_inputs: i32,
    bus_count_outputs: i32,
    audio_inputs: Vec<BusInfo>,
    audio_outputs: Vec<BusInfo>,
    event_inputs: Vec<BusInfo>,
    event_outputs: Vec<BusInfo>,
    supports_processing: bool,
}

#[derive(Debug, Clone)]
struct BusInfo {
    name: String,
    bus_type: i32,
    flags: i32,
    channel_count: i32,
}

#[derive(Debug, Clone)]
struct ControllerInfo {
    parameter_count: i32,
    parameters: Vec<ParameterInfo>,
}

#[derive(Debug, Clone)]
struct ParameterInfo {
    id: u32,
    title: String,
    short_title: String,
    units: String,
    step_count: i32,
    default_normalized_value: f64,
    unit_id: i32,
    flags: i32,
    current_value: f64,
}

// Host Application implementation
struct HostApplication {
    vtbl: *const IHostApplicationVtbl,
    ref_count: AtomicU32,
}

#[repr(C)]
struct IHostApplicationVtbl {
    query_interface:
        unsafe extern "C" fn(*mut FUnknown, *const TUID, *mut *mut std::ffi::c_void) -> tresult,
    add_ref: unsafe extern "C" fn(*mut FUnknown) -> u32,
    release: unsafe extern "C" fn(*mut FUnknown) -> u32,
    get_name: unsafe extern "C" fn(*mut HostApplication, *mut String128) -> tresult,
    create_instance: unsafe extern "C" fn(
        *mut HostApplication,
        *mut TUID,
        *mut TUID,
        *mut *mut std::ffi::c_void,
    ) -> tresult,
}

unsafe extern "C" fn host_query_interface(
    _this: *mut FUnknown,
    _iid: *const TUID,
    _obj: *mut *mut std::ffi::c_void,
) -> tresult {
    kNoInterface
}

unsafe extern "C" fn host_add_ref(this: *mut FUnknown) -> u32 {
    let host = this as *mut HostApplication;
    (*host).ref_count.fetch_add(1, Ordering::SeqCst) + 1
}

unsafe extern "C" fn host_release(this: *mut FUnknown) -> u32 {
    let host = this as *mut HostApplication;
    let count = (*host).ref_count.fetch_sub(1, Ordering::SeqCst) - 1;
    if count == 0 {
        drop(Box::from_raw(host));
    }
    count
}

unsafe extern "C" fn host_get_name(_this: *mut HostApplication, name: *mut String128) -> tresult {
    let host_name: Vec<u16> = "RustHost"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let len = std::cmp::min(host_name.len(), 128);
    for i in 0..len {
        (*name)[i] = host_name[i] as i16;
    }
    kResultOk
}

unsafe extern "C" fn host_create_instance(
    _this: *mut HostApplication,
    _cid: *mut TUID,
    _iid: *mut TUID,
    _obj: *mut *mut std::ffi::c_void,
) -> tresult {
    kNoInterface
}

static HOST_VTBL: IHostApplicationVtbl = IHostApplicationVtbl {
    query_interface: host_query_interface,
    add_ref: host_add_ref,
    release: host_release,
    get_name: host_get_name,
    create_instance: host_create_instance,
};

impl HostApplication {
    fn new() -> *mut FUnknown {
        let host = Box::new(HostApplication {
            vtbl: &HOST_VTBL,
            ref_count: AtomicU32::new(1),
        });
        Box::into_raw(host) as *mut FUnknown
    }
}

// Platform-specific stdout suppression
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::io;

#[cfg(unix)]
unsafe fn suppress_stdout<F: FnOnce() -> R, R>(f: F) -> R {
    use std::os::unix::io::AsRawFd;
    let stdout_fd = io::stdout().as_raw_fd();
    let stderr_fd = io::stderr().as_raw_fd();

    let dev_null = match File::create("/dev/null") {
        Ok(file) => file,
        Err(_) => return f(), // Fallback if can't create /dev/null
    };
    let null_fd = dev_null.as_raw_fd();

    let saved_stdout = libc::dup(stdout_fd);
    let saved_stderr = libc::dup(stderr_fd);

    if saved_stdout == -1 || saved_stderr == -1 {
        return f(); // Fallback if dup fails
    }

    libc::dup2(null_fd, stdout_fd);
    libc::dup2(null_fd, stderr_fd);

    let result = f();

    libc::dup2(saved_stdout, stdout_fd);
    libc::dup2(saved_stderr, stderr_fd);
    libc::close(saved_stdout);
    libc::close(saved_stderr);

    result
}

#[cfg(windows)]
unsafe fn suppress_stdout<F: FnOnce() -> R, R>(f: F) -> R {
    use std::os::windows::io::AsRawHandle;
    use winapi::um::fileapi::CreateFileW;
    use winapi::um::fileapi::OPEN_EXISTING; // <- HIER ist die Korrektur
    use winapi::um::handleapi::{CloseHandle, INVALID_HANDLE_VALUE};
    use winapi::um::processenv::{GetStdHandle, SetStdHandle};
    use winapi::um::winbase::{STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
    use winapi::um::winnt::{FILE_ATTRIBUTE_NORMAL, FILE_SHARE_WRITE, GENERIC_WRITE};

    let wide_nul: Vec<u16> = "NUL".encode_utf16().chain(std::iter::once(0)).collect();

    let stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    let stderr_handle = GetStdHandle(STD_ERROR_HANDLE);

    if stdout_handle == INVALID_HANDLE_VALUE || stderr_handle == INVALID_HANDLE_VALUE {
        return f();
    }

    let nul_handle = CreateFileW(
        wide_nul.as_ptr(),
        GENERIC_WRITE,
        FILE_SHARE_WRITE,
        std::ptr::null_mut(),
        OPEN_EXISTING, // <- Jetzt korrekt importiert
        FILE_ATTRIBUTE_NORMAL,
        std::ptr::null_mut(),
    );

    if nul_handle == INVALID_HANDLE_VALUE {
        return f();
    }

    SetStdHandle(STD_OUTPUT_HANDLE, nul_handle);
    SetStdHandle(STD_ERROR_HANDLE, nul_handle);

    let result = f();

    SetStdHandle(STD_OUTPUT_HANDLE, stdout_handle);
    SetStdHandle(STD_ERROR_HANDLE, stderr_handle);
    CloseHandle(nul_handle);

    result
}

// Improved error handling
fn error_exit(error_message: &str) -> ! {
    eprintln!("{}", json::stringify(object! { error: error_message }));
    exit(1);
}

// RAII guard for library lifetime management
struct LibraryGuard {
    _lib: Library,
}

impl LibraryGuard {
    fn new(lib: Library) -> Self {
        Self { _lib: lib }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        error_exit("Plugin path required as first argument");
    }

    let path = PathBuf::from(&args[1]);
    let path_string = path.display().to_string();

    // Get the VST3 binary path
    let binary_path = match get_vst3_binary_path(&path_string) {
        Ok(path) => path,
        Err(_) => error_exit("Path does not exist or is invalid"),
    };

    // Load and inspect the plugin
    let info = match unsafe { suppress_stdout(|| inspect_vst3_plugin(&binary_path)) } {
        Ok(info) => info,
        Err(_) => error_exit("Failed to load or inspect plugin"),
    };

    let controller_info = match info.controller_info {
        Some(value) => value,
        None => error_exit("Controller not found"),
    };

    let component_info = match info.component_info {
        Some(value) => value,
        None => error_exit("Component not found"),
    };

    // Build output JSON
    let mut output = object! {
        name: info.name,
        vendor: info.factory_info.vendor,
        version: info.version,
        countParameters: controller_info.parameter_count,
        countInputs: component_info.bus_count_inputs,
        countOutputs: component_info.bus_count_outputs,
        parameters: [],
        os: env::consts::OS
    };

    // Filter and add parameters
    for (i, param) in controller_info.parameters.iter().enumerate() {
        let title_lower = param.title.to_lowercase();
        let forbidden = ["midi", "cc "];

        if !title_lower.is_empty() && !forbidden.iter().any(|f| title_lower.contains(f)) {
            output["parameters"].push(object! {
                id: param.id,
                index: i,
                title: param.title.clone(),
                stepCount: param.step_count
            });
        }
    }

    println!("{}", json::stringify(output));
}

// Improved path handling
fn get_vst3_binary_path(bundle_path: &str) -> Result<String, PluginError> {
    let path = std::path::Path::new(bundle_path);

    if path.is_file() {
        return Ok(bundle_path.to_string());
    }

    if !bundle_path.ends_with(".vst3") {
        return Err(PluginError::PathError("Invalid VST3 path".to_string()));
    }

    #[cfg(target_os = "macos")]
    {
        let contents_path = path.join("Contents").join("MacOS");
        return find_binary_in_directory(&contents_path);
    }

    #[cfg(target_os = "windows")]
    {
        let contents_path = path.join("Contents");
        let arch_path = if cfg!(target_arch = "x86_64") {
            contents_path.join("x86_64-win")
        } else {
            contents_path.join("x86-win")
        };
        return find_vst3_binary_in_directory(&arch_path);
    }

    #[cfg(target_os = "linux")]
    {
        let contents_path = path.join("Contents");
        let arch_path = if cfg!(target_arch = "x86_64") {
            contents_path.join("x86_64-linux")
        } else {
            contents_path.join("x86-linux")
        };
        return find_so_binary_in_directory(&arch_path);
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        Err(PluginError::PathError("Unsupported platform".to_string()))
    }
}

#[cfg(target_os = "macos")]
fn find_binary_in_directory(dir: &std::path::Path) -> Result<String, PluginError> {
    let entries = std::fs::read_dir(dir)
        .map_err(|_| PluginError::PathError("Directory not found".to_string()))?;

    for entry in entries.flatten() {
        let file_path = entry.path();
        if file_path.is_file() {
            if let Some(name) = file_path.file_name() {
                if let Some(name_str) = name.to_str() {
                    if !name_str.starts_with('.')
                        && !name_str.ends_with(".plist")
                        && !name_str.ends_with(".txt")
                    {
                        return Ok(file_path.to_string_lossy().to_string());
                    }
                }
            }
        }
    }
    Err(PluginError::PathError("No binary found".to_string()))
}

#[cfg(target_os = "windows")]
fn find_vst3_binary_in_directory(dir: &std::path::Path) -> Result<String, PluginError> {
    let entries = std::fs::read_dir(dir)
        .map_err(|_| PluginError::PathError("Directory not found".to_string()))?;

    for entry in entries.flatten() {
        let file_path = entry.path();
        if file_path.is_file() && file_path.extension() == Some(std::ffi::OsStr::new("vst3")) {
            return Ok(file_path.to_string_lossy().to_string());
        }
    }
    Err(PluginError::PathError("No VST3 binary found".to_string()))
}

#[cfg(target_os = "linux")]
fn find_so_binary_in_directory(dir: &std::path::Path) -> Result<String, PluginError> {
    let entries = std::fs::read_dir(dir)
        .map_err(|_| PluginError::PathError("Directory not found".to_string()))?;

    for entry in entries.flatten() {
        let file_path = entry.path();
        if file_path.is_file() && file_path.extension() == Some(std::ffi::OsStr::new("so")) {
            return Ok(file_path.to_string_lossy().to_string());
        }
    }
    Err(PluginError::PathError("No SO binary found".to_string()))
}

// Unified library loading
unsafe fn load_vst3_library(path: &str) -> Result<Library, PluginError> {
    Library::new(path).map_err(|e| PluginError::LoadError(format!("Failed to load library: {}", e)))
}

// Improved main inspection function with proper library management
unsafe fn inspect_vst3_plugin(path: &str) -> Result<PluginInfo, PluginError> {
    let lib = load_vst3_library(path)?;

    let get_factory: Symbol<unsafe extern "C" fn() -> *mut IPluginFactory> = lib
        .get(b"GetPluginFactory")
        .map_err(|e| PluginError::LoadError(format!("GetPluginFactory not found: {}", e)))?;

    let factory_ptr = get_factory();
    if factory_ptr.is_null() {
        return Err(PluginError::FactoryError(
            "GetPluginFactory returned NULL".to_string(),
        ));
    }

    let factory = ComPtr::<IPluginFactory>::from_raw(factory_ptr)
        .ok_or_else(|| PluginError::FactoryError("Failed to wrap IPluginFactory".to_string()))?;

    // Keep library alive for plugin lifetime
    let _lib_guard = LibraryGuard::new(lib);

    extract_plugin_info(&factory)
}

// Refactored plugin info extraction
unsafe fn extract_plugin_info(factory: &ComPtr<IPluginFactory>) -> Result<PluginInfo, PluginError> {
    let factory_info = get_factory_info(factory)?;
    let classes = get_all_classes(factory)?;

    let audio_class = classes
        .iter()
        .find(|c| c.category.contains("Audio Module Class"))
        .ok_or_else(|| PluginError::ComponentError("No Audio Module class found".to_string()))?;

    let (component_info, controller_info, name, version) = initialize_and_inspect_plugin(factory)?;

    Ok(PluginInfo {
        factory_info,
        classes,
        component_info,
        controller_info,
        name,
        version,
    })
}

unsafe fn initialize_and_inspect_plugin(
    factory: &ComPtr<IPluginFactory>,
) -> Result<
    (
        Option<ComponentInfo>,
        Option<ControllerInfo>,
        String,
        String,
    ),
    PluginError,
> {
    let num_classes = factory.countClasses();
    let mut component_ptr: *mut IComponent = ptr::null_mut();
    let mut plugin_name = String::new();
    let plugin_version = "1.0.0".to_string(); // Default version
    let mut audio_class_id = None;

    // Find and create the Audio Module component
    for i in 0..num_classes {
        let mut class_info = std::mem::zeroed();
        if factory.getClassInfo(i, &mut class_info) == kResultOk {
            let category = c_str_to_string(&class_info.category);

            if category.contains("Audio Module Class") {
                plugin_name = c_str_to_string(&class_info.name);
                audio_class_id = Some(class_info.cid);

                let result = factory.createInstance(
                    class_info.cid.as_ptr() as *const i8,
                    IComponent::IID.as_ptr() as *const i8,
                    &mut component_ptr as *mut _ as *mut _,
                );

                if result == kResultOk && !component_ptr.is_null() {
                    break;
                }
            }
        }
    }

    let audio_class_id = audio_class_id
        .ok_or_else(|| PluginError::ComponentError("No Audio Module class found".to_string()))?;

    if component_ptr.is_null() {
        return Err(PluginError::ComponentError(
            "Failed to create component".to_string(),
        ));
    }

    let component = ComPtr::<IComponent>::from_raw(component_ptr)
        .ok_or_else(|| PluginError::ComponentError("Failed to wrap component".to_string()))?;

    // Initialize component
    let host_ptr = HostApplication::new();
    let init_result = component.initialize(host_ptr);
    if init_result != kResultOk {
        return Err(PluginError::InitError(format!(
            "Failed to initialize component: {:#x}",
            init_result
        )));
    }

    // Get or create controller
    let controller = match get_or_create_controller(&component, factory, &audio_class_id)? {
        Some(ctrl) => ctrl,
        None => {
            component.terminate();
            return Err(PluginError::ComponentError(
                "No controller available".to_string(),
            ));
        }
    };

    // Get component info
    let component_info = get_component_info(&component)?;

    // Connect components if they are separate
    let _ = connect_component_and_controller(&component, &controller);

    // Activate component
    component.setActive(1);

    // Get controller info
    let controller_info = get_controller_info(&controller)?;

    // Cleanup
    component.terminate();
    controller.terminate();

    Ok((
        Some(component_info),
        Some(controller_info),
        plugin_name,
        plugin_version,
    ))
}

unsafe fn get_or_create_controller(
    component: &ComPtr<IComponent>,
    factory: &ComPtr<IPluginFactory>,
    _class_id: &TUID,
) -> Result<Option<ComPtr<IEditController>>, PluginError> {
    // First, try to cast component to IEditController (single component)
    if let Some(controller) = component.cast::<IEditController>() {
        return Ok(Some(controller));
    }

    // If not single component, try to get separate controller
    let mut controller_cid = [0i8; 16];
    let result = component.getControllerClassId(&mut controller_cid);

    if result != kResultOk {
        return Ok(None);
    }

    let mut controller_ptr: *mut IEditController = ptr::null_mut();
    let create_result = factory.createInstance(
        controller_cid.as_ptr(),
        IEditController::IID.as_ptr() as *const i8,
        &mut controller_ptr as *mut _ as *mut _,
    );

    if create_result != kResultOk || controller_ptr.is_null() {
        return Ok(None);
    }

    let controller = ComPtr::<IEditController>::from_raw(controller_ptr)
        .ok_or_else(|| PluginError::ComponentError("Failed to wrap controller".to_string()))?;

    // Initialize controller
    let init_result = controller.initialize(ptr::null_mut());
    if init_result != kResultOk {
        return Ok(None);
    }

    Ok(Some(controller))
}

unsafe fn connect_component_and_controller(
    component: &ComPtr<IComponent>,
    controller: &ComPtr<IEditController>,
) -> Result<(), PluginError> {
    // Try to get connection points
    let comp_cp = component.cast::<IConnectionPoint>();
    let ctrl_cp = controller.cast::<IConnectionPoint>();

    if let (Some(comp_cp), Some(ctrl_cp)) = (comp_cp, ctrl_cp) {
        // Connect component to controller
        let result1 = comp_cp.connect(ctrl_cp.as_ptr());
        let result2 = ctrl_cp.connect(comp_cp.as_ptr());

        if result1 == kResultOk && result2 == kResultOk {
            Ok(())
        } else {
            Err(PluginError::ComponentError(format!(
                "Connection failed: comp->ctrl={:#x}, ctrl->comp={:#x}",
                result1, result2
            )))
        }
    } else {
        Err(PluginError::ComponentError(
            "No connection points available".to_string(),
        ))
    }
}

unsafe fn get_component_info(component: &ComPtr<IComponent>) -> Result<ComponentInfo, PluginError> {
    // Get bus information using the imported constants (cast to i32)
    let audio_input_count = component.getBusCount(kAudio as i32, kInput as i32);
    let audio_output_count = component.getBusCount(kAudio as i32, kOutput as i32);
    let event_input_count = component.getBusCount(kEvent as i32, kInput as i32);
    let event_output_count = component.getBusCount(kEvent as i32, kOutput as i32);

    let mut audio_inputs = Vec::new();
    let mut audio_outputs = Vec::new();
    let mut event_inputs = Vec::new();
    let mut event_outputs = Vec::new();

    // Get audio input buses
    for i in 0..audio_input_count {
        if let Ok(bus_info) = get_bus_info(component, kAudio as i32, kInput as i32, i) {
            audio_inputs.push(bus_info);
        }
    }

    // Get audio output buses
    for i in 0..audio_output_count {
        if let Ok(bus_info) = get_bus_info(component, kAudio as i32, kOutput as i32, i) {
            audio_outputs.push(bus_info);
        }
    }

    // Get event input buses
    for i in 0..event_input_count {
        if let Ok(bus_info) = get_bus_info(component, kEvent as i32, kInput as i32, i) {
            event_inputs.push(bus_info);
        }
    }

    // Get event output buses
    for i in 0..event_output_count {
        if let Ok(bus_info) = get_bus_info(component, kEvent as i32, kOutput as i32, i) {
            event_outputs.push(bus_info);
        }
    }

    // Check if component supports audio processing
    let supports_processing = component.cast::<IAudioProcessor>().is_some();

    Ok(ComponentInfo {
        bus_count_inputs: audio_input_count + event_input_count,
        bus_count_outputs: audio_output_count + event_output_count,
        audio_inputs,
        audio_outputs,
        event_inputs,
        event_outputs,
        supports_processing,
    })
}

unsafe fn get_controller_info(
    controller: &ComPtr<IEditController>,
) -> Result<ControllerInfo, PluginError> {
    let parameter_count = controller.getParameterCount();
    let mut parameters = Vec::new();

    // Get all parameter information
    for i in 0..parameter_count {
        let mut param_info = std::mem::zeroed();
        if controller.getParameterInfo(i, &mut param_info) == kResultOk {
            let current_value = controller.getParamNormalized(param_info.id);
            let title = utf16_to_string_i16(&param_info.title);

            parameters.push(ParameterInfo {
                id: param_info.id,
                title,
                short_title: utf16_to_string_i16(&param_info.shortTitle),
                units: utf16_to_string_i16(&param_info.units),
                step_count: param_info.stepCount,
                default_normalized_value: param_info.defaultNormalizedValue,
                unit_id: param_info.unitId,
                flags: param_info.flags,
                current_value,
            });
        }
    }

    Ok(ControllerInfo {
        parameter_count,
        parameters,
    })
}

unsafe fn get_factory_info(factory: &ComPtr<IPluginFactory>) -> Result<FactoryInfo, PluginError> {
    let mut factory_info = std::mem::zeroed();
    let result = factory.getFactoryInfo(&mut factory_info);

    if result != kResultOk {
        return Err(PluginError::FactoryError(format!(
            "Failed to get factory info: {}",
            result
        )));
    }

    Ok(FactoryInfo {
        vendor: c_str_to_string(&factory_info.vendor),
        url: c_str_to_string(&factory_info.url),
        email: c_str_to_string(&factory_info.email),
        flags: factory_info.flags,
    })
}

unsafe fn get_all_classes(factory: &ComPtr<IPluginFactory>) -> Result<Vec<ClassInfo>, PluginError> {
    let class_count = factory.countClasses();
    let mut classes = Vec::new();

    for i in 0..class_count {
        let mut class_info = std::mem::zeroed();
        if factory.getClassInfo(i, &mut class_info) == kResultOk {
            classes.push(ClassInfo {
                name: c_str_to_string(&class_info.name),
                category: c_str_to_string(&class_info.category),
                class_id: format!("{:?}", class_info.cid),
                cardinality: class_info.cardinality,
            });
        }
    }

    Ok(classes)
}

unsafe fn get_bus_info(
    component: &ComPtr<IComponent>,
    media_type: i32,
    direction: i32,
    index: i32,
) -> Result<BusInfo, PluginError> {
    let mut bus_info = std::mem::zeroed();
    let result = component.getBusInfo(media_type, direction, index, &mut bus_info);

    if result != kResultOk {
        return Err(PluginError::ComponentError(format!(
            "Failed to get bus info: {}",
            result
        )));
    }

    Ok(BusInfo {
        name: utf16_to_string_i16(&bus_info.name),
        bus_type: bus_info.busType,
        flags: bus_info.flags as i32,
        channel_count: bus_info.channelCount,
    })
}

// Helper functions
unsafe fn c_str_to_string(ptr: &[i8]) -> String {
    let bytes: Vec<u8> = ptr
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes)
        .trim_matches('\0')
        .to_string()
}

unsafe fn utf16_to_string_i16(ptr: &[i16]) -> String {
    let u16_slice: Vec<u16> = ptr
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u16)
        .collect();
    String::from_utf16_lossy(&u16_slice)
}
