/*!
* ------------------------------------------------------------------------
* VST3 Info Extractor Tool
* heavily based on rust-vst3-host by Helge Sverre
* by Jurek Raben
* ------------------------------------------------------------------------
*/

#![allow(deprecated)]
#![allow(non_upper_case_globals)]
#![allow(non_snake_case)]

use std::env;
use std::path::PathBuf;
use std::process::exit;
use std::ptr;
use vst3::Steinberg::IPluginFactoryTrait;
use vst3::Steinberg::Vst::{
    BusDirections_::*, IAudioProcessor, IComponent, IComponentTrait, IConnectionPoint,
    IConnectionPointTrait, IEditController, IEditControllerTrait, MediaTypes_::*,
};
use vst3::Steinberg::{IPluginBaseTrait, IPluginFactory};
use vst3::{ComPtr, Interface};

use json::object;

use libloading::os::unix::{Library, Symbol};

#[derive(Debug, Clone)]
struct PluginInfo {
    factory_info: FactoryInfo,
    classes: Vec<ClassInfo>,
    component_info: Option<ComponentInfo>,
    controller_info: Option<ControllerInfo>,
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
    version: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
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
#[allow(dead_code)]
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
#[allow(dead_code)]
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

fn error_exit(error_message: &str) {
    eprintln!("{}", json::stringify(object! { error: error_message }));
    exit(1);
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        error_exit("Plugin path required as first argument");
    }

    let path = PathBuf::from(&args[1]);
    let path_string: String = path.display().to_string();

    // Try to load the default plugin
    let binary_path = match get_vst3_binary_path(&path_string) {
        Ok(path) => path,
        Err(e) => {
            error_exit("path does not exist");
            exit(1);
        }
    };

    let info = match unsafe { inspect_vst3_plugin(&binary_path) } {
        Ok(info) => info,
        Err(e) => {
            error_exit("loading plugin failed");
            exit(1);
        }
    };

    let controller_info = match info.controller_info {
        Some(value) => value,
        None => {
            error_exit("controller not found");
            exit(1);
        }
    };

    let component_info = match info.component_info {
        Some(value) => value,
        None => {
            error_exit("component not found");
            exit(1);
        }
    };

    let audioModule = match info
        .classes
        .iter()
        .find(|c| c.category.contains("Audio Module"))//Component
    {
        Some(value) => value,
        None => {
            error_exit("audio module not found");
            exit(1);
        }
    };

    let mut output = object! {
        name: audioModule.name.to_string(),
        vendor: info.factory_info.vendor,
        version: audioModule.version.to_string(),
        countParameters: controller_info.parameter_count,
        countInputs: component_info.bus_count_inputs,
        countOutputs: component_info.bus_count_outputs,
        parameters: [],
        os: env::consts::OS
    };

    for (i, param) in controller_info.parameters.iter().enumerate() {
        if param.title != "" && !param.title.to_lowercase().contains("midi") {
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

// Helper function to find the correct binary path in VST3 bundle
fn get_vst3_binary_path(bundle_path: &str) -> Result<String, String> {
    let path = std::path::Path::new(bundle_path);

    // If it's already pointing to the binary, use it
    if path.is_file() {
        return Ok(bundle_path.to_string());
    }

    // Platform-specific VST3 bundle handling
    #[cfg(target_os = "macos")]
    {
        // macOS: .vst3 bundle structure
        if bundle_path.ends_with(".vst3") {
            let contents_path = path.join("Contents").join("MacOS");
            if let Ok(entries) = std::fs::read_dir(&contents_path) {
                for entry in entries {
                    if let Ok(entry) = entry {
                        let file_path = entry.path();
                        if file_path.is_file() {
                            if let Some(name) = file_path.file_name() {
                                if let Some(name_str) = name.to_str() {
                                    // Skip hidden files and common non-binary files
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
                }
            }
            return Err(format!("No binary found in VST3 bundle: {}", bundle_path));
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Windows: .vst3 bundle structure
        if bundle_path.ends_with(".vst3") {
            let contents_path = path.join("Contents");
            let arch_path = if cfg!(target_arch = "x86_64") {
                contents_path.join("x86_64-win")
            } else {
                contents_path.join("x86-win")
            };

            if let Ok(entries) = std::fs::read_dir(&arch_path) {
                for entry in entries {
                    if let Ok(entry) = entry {
                        let file_path = entry.path();
                        if file_path.is_file()
                            && file_path.extension() == Some(std::ffi::OsStr::new("vst3"))
                        {
                            return Ok(file_path.to_string_lossy().to_string());
                        }
                    }
                }
            }
            return Err(format!("No binary found in VST3 bundle: {}", bundle_path));
        }
    }

    Err(format!("Invalid VST3 path: {}", bundle_path))
}

// Platform-specific library loading
#[cfg(target_os = "macos")]
unsafe fn load_vst3_library(path: &str) -> Result<Library, String> {
    Library::new(path).map_err(|e| format!("❌ Failed to load VST3 bundle: {}", e))
}

#[cfg(target_os = "windows")]
unsafe fn load_vst3_library(path: &str) -> Result<libloading::Library, String> {
    libloading::Library::new(path).map_err(|e| format!("❌ Failed to load VST3 bundle: {}", e))
}

unsafe fn inspect_vst3_plugin(path: &str) -> Result<PluginInfo, String> {
    #[cfg(target_os = "macos")]
    let lib = load_vst3_library(path)?;
    #[cfg(target_os = "windows")]
    let lib = load_vst3_library(path)?;

    #[cfg(target_os = "macos")]
    let get_factory: Symbol<unsafe extern "C" fn() -> *mut IPluginFactory> = lib
        .get(b"GetPluginFactory")
        .map_err(|e| format!("❌ Failed to load `GetPluginFactory`: {}", e))?;

    #[cfg(target_os = "windows")]
    let get_factory: libloading::Symbol<unsafe extern "C" fn() -> *mut IPluginFactory> = lib
        .get(b"GetPluginFactory")
        .map_err(|e| format!("❌ Failed to load `GetPluginFactory`: {}", e))?;
    let factory_ptr = get_factory();
    if factory_ptr.is_null() {
        return Err("❌ `GetPluginFactory` returned NULL".into());
    }

    let factory = ComPtr::<IPluginFactory>::from_raw(factory_ptr)
        .ok_or("❌ Failed to wrap IPluginFactory")?;

    // Keep the library alive by leaking it (for proof of concept)
    // In a real application, you'd want to manage this properly
    std::mem::forget(lib);

    // 1. Get factory information
    let factory_info = get_factory_info(&factory)?;

    // 2. Get all class information
    let classes = get_all_classes(&factory)?;

    // 3. Find the Audio Module class
    let audio_class = classes
        .iter()
        .find(|c| c.category.contains("Audio Module"))
        .ok_or("No Audio Module class found")?;

    // 4. Create and properly initialize the plugin using the official SDK pattern
    let (component_info, controller_info) =
        properly_initialize_plugin(&factory, &audio_class.class_id)?;

    Ok(PluginInfo {
        factory_info,
        classes,
        component_info,
        controller_info,
    })
}

unsafe fn properly_initialize_plugin(
    factory: &ComPtr<IPluginFactory>,
    _class_id_str: &str,
) -> Result<(Option<ComponentInfo>, Option<ControllerInfo>), String> {
    // Find the Audio Module class (same as in our detection logic)
    let class_count = factory.countClasses();
    let mut audio_class_id = None;

    for i in 0..class_count {
        let mut class_info = std::mem::zeroed();
        if factory.getClassInfo(i, &mut class_info) == vst3::Steinberg::kResultOk {
            let category = c_str_to_string(&class_info.category);
            if category.contains("Audio Module") {
                audio_class_id = Some(class_info.cid);
                break;
            }
        }
    }

    let audio_class_id = audio_class_id.ok_or("No Audio Module class found")?;

    // Create component first
    let mut component_ptr: *mut IComponent = ptr::null_mut();
    let result = factory.createInstance(
        audio_class_id.as_ptr(),
        IComponent::IID.as_ptr() as *const i8,
        &mut component_ptr as *mut _ as *mut _,
    );

    if result != vst3::Steinberg::kResultOk || component_ptr.is_null() {
        return Err("Failed to create component".to_string());
    }

    let component =
        ComPtr::<IComponent>::from_raw(component_ptr).ok_or("Failed to wrap component")?;

    let init_result = component.initialize(ptr::null_mut());

    if init_result != vst3::Steinberg::kResultOk {
        return Err("Failed to initialize component".to_string());
    }

    // Get controller (same logic as in our working detection)
    let controller = match get_or_create_controller(&component, &factory, &audio_class_id)? {
        Some(ctrl) => ctrl,
        None => {
            component.terminate();
            return Err("No controller available".to_string());
        }
    };

    // Step 3: Get Component Info
    let component_info = get_component_info(&component)?;

    // Step 4: Connect components if they are separate
    connect_component_and_controller(&component, &controller);

    component.setActive(1);

    let controller_info = get_controller_info(&controller)?;

    // Cleanup
    component.terminate();
    controller.terminate();

    Ok((Some(component_info), Some(controller_info)))
}

unsafe fn get_or_create_controller(
    component: &ComPtr<IComponent>,
    factory: &ComPtr<IPluginFactory>,
    _class_id: &vst3::Steinberg::TUID,
) -> Result<Option<ComPtr<IEditController>>, String> {
    // First, try to cast component to IEditController (single component)
    if let Some(controller) = component.cast::<IEditController>() {
        return Ok(Some(controller));
    }

    // If not single component, try to get separate controller
    let mut controller_cid = [0i8; 16];
    let result = component.getControllerClassId(&mut controller_cid);

    if result != vst3::Steinberg::kResultOk {
        return Ok(None);
    }

    let mut controller_ptr: *mut IEditController = ptr::null_mut();
    let create_result = factory.createInstance(
        controller_cid.as_ptr(),
        IEditController::IID.as_ptr() as *const i8,
        &mut controller_ptr as *mut _ as *mut _,
    );

    if create_result != vst3::Steinberg::kResultOk || controller_ptr.is_null() {
        return Ok(None);
    }

    let controller =
        ComPtr::<IEditController>::from_raw(controller_ptr).ok_or("Failed to wrap controller")?;

    // Initialize controller
    let init_result = controller.initialize(ptr::null_mut());
    if init_result != vst3::Steinberg::kResultOk {
        return Ok(None);
    }

    Ok(Some(controller))
}

unsafe fn connect_component_and_controller(
    component: &ComPtr<IComponent>,
    controller: &ComPtr<IEditController>,
) -> Result<(), String> {
    // Try to get connection points
    let comp_cp = component.cast::<IConnectionPoint>();
    let ctrl_cp = controller.cast::<IConnectionPoint>();

    if let (Some(comp_cp), Some(ctrl_cp)) = (comp_cp, ctrl_cp) {
        // Connect component to controller
        let result1 = comp_cp.connect(ctrl_cp.as_ptr());
        let result2 = ctrl_cp.connect(comp_cp.as_ptr());

        if result1 == vst3::Steinberg::kResultOk && result2 == vst3::Steinberg::kResultOk {
            Ok(())
        } else {
            Err(format!(
                "Connection failed: comp->ctrl={:#x}, ctrl->comp={:#x}",
                result1, result2
            ))
        }
    } else {
        Err("No connection points available".to_string())
    }
}

unsafe fn get_component_info(component: &ComPtr<IComponent>) -> Result<ComponentInfo, String> {
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
        if let Ok(bus_info) = get_bus_info(&component, kAudio as i32, kInput as i32, i) {
            audio_inputs.push(bus_info);
        }
    }

    // Get audio output buses
    for i in 0..audio_output_count {
        if let Ok(bus_info) = get_bus_info(&component, kAudio as i32, kOutput as i32, i) {
            audio_outputs.push(bus_info);
        }
    }

    // Get event input buses
    for i in 0..event_input_count {
        if let Ok(bus_info) = get_bus_info(&component, kEvent as i32, kInput as i32, i) {
            event_inputs.push(bus_info);
        }
    }

    // Get event output buses
    for i in 0..event_output_count {
        if let Ok(bus_info) = get_bus_info(&component, kEvent as i32, kOutput as i32, i) {
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
) -> Result<ControllerInfo, String> {
    let parameter_count = controller.getParameterCount();
    let mut parameters = Vec::new();

    // Get all parameter information
    for i in 0..parameter_count {
        let mut param_info = std::mem::zeroed();
        if controller.getParameterInfo(i, &mut param_info) == vst3::Steinberg::kResultOk {
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

unsafe fn get_factory_info(factory: &ComPtr<IPluginFactory>) -> Result<FactoryInfo, String> {
    let mut factory_info = std::mem::zeroed();
    let result = factory.getFactoryInfo(&mut factory_info);

    if result != vst3::Steinberg::kResultOk {
        return Err(format!("Failed to get factory info: {}", result));
    }

    Ok(FactoryInfo {
        vendor: c_str_to_string(&factory_info.vendor),
        url: c_str_to_string(&factory_info.url),
        email: c_str_to_string(&factory_info.email),
        flags: factory_info.flags,
    })
}

unsafe fn get_all_classes(factory: &ComPtr<IPluginFactory>) -> Result<Vec<ClassInfo>, String> {
    let class_count = factory.countClasses();
    let mut classes = Vec::new();

    for i in 0..class_count {
        let mut class_info = std::mem::zeroed();
        if factory.getClassInfo(i, &mut class_info) == vst3::Steinberg::kResultOk {
            classes.push(ClassInfo {
                name: c_str_to_string(&class_info.name),
                category: c_str_to_string(&class_info.category),
                class_id: format!("{:?}", class_info.cid),
                cardinality: class_info.cardinality,
                version: String::new(), // Version not available in factory info
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
) -> Result<BusInfo, String> {
    let mut bus_info = std::mem::zeroed();
    let result = component.getBusInfo(media_type, direction, index, &mut bus_info);

    if result != vst3::Steinberg::kResultOk {
        return Err(format!("Failed to get bus info: {}", result));
    }

    Ok(BusInfo {
        name: utf16_to_string_i16(&bus_info.name),
        bus_type: bus_info.busType,
        flags: bus_info.flags as i32, // Convert u32 to i32
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
    // Convert i16 to u16 for UTF-16 processing
    let u16_slice: Vec<u16> = ptr
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u16)
        .collect();
    String::from_utf16_lossy(&u16_slice)
}

// Windows-specific helper functions
#[cfg(target_os = "windows")]
fn win32_string(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(once(0)).collect()
}
