//! Creates the classes of a VST3 plugin and reads the infos of them.

use crate::host_application;
use crate::memory_stream::MemoryStream;
use crate::migration_info::class_id_to_string;
use crate::message_pump;
use crate::preset_file::PresetStates;
use crate::vst3_strings::{string_from_utf8_buffer, string_from_utf16_buffer};
use std::ffi::c_void;
use std::mem::zeroed;
use std::ptr;
use vst3::Steinberg::Vst::{
    BusDirections_::{kInput, kOutput},
    IComponent, IComponentTrait, IConnectionPoint, IConnectionPointTrait, IEditController,
    IEditControllerTrait,
    MediaTypes_::{kAudio, kEvent},
};
use vst3::Steinberg::{
    FUnknown, IBStream, IPluginBaseTrait, IPluginFactory, IPluginFactoryTrait, PClassInfo, kResultOk,
};
use vst3::{ComPtr, ComWrapper, Interface};

const AUDIO_MODULE_CATEGORY: &str = "Audio Module Class";

// The version of a class is only available through a newer factory interface
const PLUGIN_VERSION: &str = "1.0.0";

const CONTINUOUS_VALUE_INTERVALS: i32 = 40;

pub struct PluginInfos {
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub input_bus_count: i32,
    pub output_bus_count: i32,
    pub parameter_count: i32,
    pub parameters: Vec<ParameterInfos>,
}

pub struct ParameterInfos {
    pub id: u32,
    pub title: String,
    pub step_count: i32,
    pub displayed_values: Vec<DisplayedValue>,
}

/// How the plugin displays a normalized value, this reveals the scale of a parameter.
pub struct DisplayedValue {
    pub normalized_value: f64,
    pub text: String,
}

#[derive(Clone, Copy, PartialEq)]
pub enum DisplayedValues {
    Skip,
    Read,
}

struct AudioComponent {
    name: String,
    component: ComPtr<IComponent>,
}

/// Without a class id, the first class of the module that can be created is inspected
pub fn inspect_plugin(
    factory: &ComPtr<IPluginFactory>,
    displayed_values: DisplayedValues,
    preset_states: Option<PresetStates>,
    class_id: Option<&str>,
) -> Result<PluginInfos, String> {
    unsafe {
        let vendor = read_factory_vendor(factory)?;
        let AudioComponent { name, component } = create_audio_component(factory, class_id)?;

        let host = host_application::create_host_application();
        let initialize_result = component.initialize(host);
        if initialize_result != kResultOk {
            return Err(format!(
                "Failed to initialize component: {:#x}",
                initialize_result
            ));
        }

        // Component and controller are the same object for single component plugins
        let has_separate_controller = component.cast::<IEditController>().is_none();

        let Some(controller) = open_controller(&component, factory, host) else {
            component.terminate();
            return Err("No controller available".to_string());
        };

        let input_bus_count = count_buses(&component, kInput as i32);
        let output_bus_count = count_buses(&component, kOutput as i32);

        if has_separate_controller {
            connect_component_and_controller(&component, &controller);
        }
        if let Some(preset_states) = preset_states {
            load_preset_states(&component, &controller, preset_states)?;
            message_pump::process_pending_messages();
        }
        component.setActive(1);

        let parameter_count = controller.getParameterCount();
        let parameters = read_parameters(&controller, parameter_count, displayed_values);

        // Cleanup in reverse order of the setup
        component.setActive(0);
        if has_separate_controller {
            disconnect_component_and_controller(&component, &controller);
            controller.terminate();
        }
        component.terminate();

        Ok(PluginInfos {
            name,
            vendor,
            version: PLUGIN_VERSION.to_string(),
            input_bus_count,
            output_bus_count,
            parameter_count,
            parameters,
        })
    }
}

/// Some plugins only create parts of their parameters with a loaded state.
unsafe fn load_preset_states(
    component: &ComPtr<IComponent>,
    controller: &ComPtr<IEditController>,
    preset_states: PresetStates,
) -> Result<(), String> {
    let create_stream = |data: Vec<u8>| {
        ComWrapper::new(MemoryStream::new(data))
            .to_com_ptr::<IBStream>()
            .ok_or("Failed to create a stream".to_string())
    };

    unsafe {
        let component_stream = create_stream(preset_states.component_state.clone())?;
        let result = component.setState(component_stream.as_ptr());
        if result != kResultOk {
            return Err(format!("The plugin rejected the preset: {:#x}", result));
        }

        let controller_view_stream = create_stream(preset_states.component_state)?;
        controller.setComponentState(controller_view_stream.as_ptr());

        if !preset_states.controller_state.is_empty() {
            let controller_stream = create_stream(preset_states.controller_state)?;
            controller.setState(controller_stream.as_ptr());
        }
    }
    Ok(())
}

unsafe fn read_factory_vendor(factory: &ComPtr<IPluginFactory>) -> Result<String, String> {
    unsafe {
        let mut factory_info = zeroed();
        let result = factory.getFactoryInfo(&mut factory_info);
        if result != kResultOk {
            return Err(format!("Failed to get factory info: {}", result));
        }
        Ok(string_from_utf8_buffer(&factory_info.vendor))
    }
}

/// A module can contain multiple classes, the first one that can be created is used, or the given one.
unsafe fn create_audio_component(
    factory: &ComPtr<IPluginFactory>,
    class_id: Option<&str>,
) -> Result<AudioComponent, String> {
    unsafe {
        let mut has_audio_class = false;

        for class_index in 0..factory.countClasses() {
            let mut class_info: PClassInfo = zeroed();
            if factory.getClassInfo(class_index, &mut class_info) != kResultOk
                || !string_from_utf8_buffer(&class_info.category).contains(AUDIO_MODULE_CATEGORY)
                || class_id.is_some_and(|id| !class_id_to_string(&class_info.cid).eq_ignore_ascii_case(id))
            {
                continue;
            }
            has_audio_class = true;

            let mut component_pointer: *mut IComponent = ptr::null_mut();
            let result = factory.createInstance(
                class_info.cid.as_ptr(),
                IComponent::IID.as_ptr() as *const _,
                &mut component_pointer as *mut _ as *mut *mut c_void,
            );

            if result == kResultOk {
                if let Some(component) = ComPtr::from_raw(component_pointer) {
                    return Ok(AudioComponent {
                        name: string_from_utf8_buffer(&class_info.name),
                        component,
                    });
                }
            }
        }

        Err(if has_audio_class {
            "Failed to create component".to_string()
        } else {
            "No Audio Module class found".to_string()
        })
    }
}

/// The controller is either the component itself, or a separate class of the module.
pub(crate) unsafe fn open_controller(
    component: &ComPtr<IComponent>,
    factory: &ComPtr<IPluginFactory>,
    host: *mut FUnknown,
) -> Option<ComPtr<IEditController>> {
    if let Some(controller) = component.cast::<IEditController>() {
        return Some(controller);
    }

    unsafe {
        let mut controller_class_id = zeroed();
        if component.getControllerClassId(&mut controller_class_id) != kResultOk {
            return None;
        }

        let mut controller_pointer: *mut IEditController = ptr::null_mut();
        let result = factory.createInstance(
            controller_class_id.as_ptr(),
            IEditController::IID.as_ptr() as *const _,
            &mut controller_pointer as *mut _ as *mut *mut c_void,
        );
        if result != kResultOk {
            return None;
        }

        let controller = ComPtr::<IEditController>::from_raw(controller_pointer)?;
        (controller.initialize(host) == kResultOk).then_some(controller)
    }
}

unsafe fn count_buses(component: &ComPtr<IComponent>, direction: i32) -> i32 {
    unsafe {
        component.getBusCount(kAudio as i32, direction)
            + component.getBusCount(kEvent as i32, direction)
    }
}

/// Parameters of the component and the controller are synchronized over the connection. Plugins
/// that don't support it still report their parameters, so a failing connection is ignored.
pub(crate) unsafe fn connect_component_and_controller(
    component: &ComPtr<IComponent>,
    controller: &ComPtr<IEditController>,
) {
    if let (Some(component_point), Some(controller_point)) = (
        component.cast::<IConnectionPoint>(),
        controller.cast::<IConnectionPoint>(),
    ) {
        unsafe {
            component_point.connect(controller_point.as_ptr());
            controller_point.connect(component_point.as_ptr());
        }
    }
}

pub(crate) unsafe fn disconnect_component_and_controller(
    component: &ComPtr<IComponent>,
    controller: &ComPtr<IEditController>,
) {
    if let (Some(component_point), Some(controller_point)) = (
        component.cast::<IConnectionPoint>(),
        controller.cast::<IConnectionPoint>(),
    ) {
        unsafe {
            component_point.disconnect(controller_point.as_ptr());
            controller_point.disconnect(component_point.as_ptr());
        }
    }
}

unsafe fn read_parameters(
    controller: &ComPtr<IEditController>,
    parameter_count: i32,
    displayed_values: DisplayedValues,
) -> Vec<ParameterInfos> {
    let mut parameters = Vec::new();

    for parameter_index in 0..parameter_count {
        unsafe {
            let mut parameter_info = zeroed();
            if controller.getParameterInfo(parameter_index, &mut parameter_info) == kResultOk {
                parameters.push(ParameterInfos {
                    id: parameter_info.id,
                    title: string_from_utf16_buffer(&parameter_info.title),
                    step_count: parameter_info.stepCount,
                    displayed_values: if displayed_values == DisplayedValues::Read {
                        read_displayed_values(controller, parameter_info.id, parameter_info.stepCount)
                    } else {
                        Vec::new()
                    },
                });
            }
        }
    }

    parameters
}

/// A stepped parameter is read at each of its steps, a continuous one at evenly spaced values.
unsafe fn read_displayed_values(
    controller: &ComPtr<IEditController>,
    parameter_id: u32,
    step_count: i32,
) -> Vec<DisplayedValue> {
    let interval_count = if step_count > 0 {
        step_count
    } else {
        CONTINUOUS_VALUE_INTERVALS
    };

    (0..=interval_count)
        .filter_map(|interval| {
            let normalized_value = f64::from(interval) / f64::from(interval_count);
            unsafe {
                let mut text = zeroed();
                let result = controller.getParamStringByValue(parameter_id, normalized_value, &mut text);
                (result == kResultOk).then(|| DisplayedValue {
                    normalized_value,
                    text: string_from_utf16_buffer(&text),
                })
            }
        })
        .collect()
}
