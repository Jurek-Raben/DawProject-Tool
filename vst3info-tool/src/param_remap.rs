//! Asks a VST3 plugin, which of its parameters replace the parameters of an older plugin it replaces,
//! e.g. of its own VST2 version. For a VST2 plugin the old parameter id is the index of the parameter.
//!
//! The plugin answers through IRemapParamID of its controller, an optional interface of VST3 SDK 3.7.11.
//! The result is { supported, parameters: [{ old, new }], unmapped: [] }.

use crate::console_silencer;
use crate::host_application;
use crate::migration_info::class_id_to_string;
use crate::plugin_binary;
use crate::plugin_inspector::{
    connect_component_and_controller, disconnect_component_and_controller, open_controller,
};
use crate::plugin_module::PluginModule;
use json::{JsonValue, array, object};
use std::ffi::c_void;
use std::mem::zeroed;
use std::path::Path;
use std::ptr;
use vst3::Steinberg::Vst::{IComponent, IEditController, IRemapParamID, IRemapParamIDTrait, ParamID};
use vst3::Steinberg::{IPluginBaseTrait, IPluginFactory, IPluginFactoryTrait, PClassInfo, TUID, kResultOk};
use vst3::{ComPtr, Interface};

pub fn remap_parameters(
    plugin_path: &Path,
    class_id: &str,
    replaced_class_id: &str,
    old_parameter_ids: &[ParamID],
) -> Result<JsonValue, String> {
    let replaced_class_tuid = class_id_from_string(replaced_class_id)?;
    let binary_path = plugin_binary::locate_plugin_binary(plugin_path).map_err(|error| {
        format!(
            "Path does not exist or is invalid ({}): {}",
            plugin_path.display(),
            error
        )
    })?;

    // The plugin must not write into the output of the tool
    console_silencer::run_silenced(|| {
        let module = PluginModule::load(&binary_path)?;
        let factory = module.plugin_factory()?;
        unsafe { remap_with_factory(&factory, class_id, &replaced_class_tuid, old_parameter_ids) }
    })
    .map_err(|error| format!("Failed to load or inspect plugin: {}", error))
}

unsafe fn remap_with_factory(
    factory: &ComPtr<IPluginFactory>,
    class_id: &str,
    replaced_class_tuid: &TUID,
    old_parameter_ids: &[ParamID],
) -> Result<JsonValue, String> {
    unsafe {
        let component = create_component(factory, class_id)?;
        let host = host_application::create_host_application();
        let initialize_result = component.initialize(host);
        if initialize_result != kResultOk {
            return Err(format!("Failed to initialize component: {:#x}", initialize_result));
        }

        let has_separate_controller = component.cast::<IEditController>().is_none();
        let Some(controller) = open_controller(&component, factory, host) else {
            component.terminate();
            return Err("No controller available".to_string());
        };
        if has_separate_controller {
            connect_component_and_controller(&component, &controller);
        }

        let result = match controller.cast::<IRemapParamID>() {
            Some(remapper) => remap(&remapper, replaced_class_tuid, old_parameter_ids),
            None => object! {
                supported: false,
                parameters: array![],
                unmapped: old_parameter_ids.to_vec(),
            },
        };

        // Cleanup in reverse order of the setup
        if has_separate_controller {
            disconnect_component_and_controller(&component, &controller);
            controller.terminate();
        }
        component.terminate();
        Ok(result)
    }
}

unsafe fn remap(
    remapper: &ComPtr<IRemapParamID>,
    replaced_class_tuid: &TUID,
    old_parameter_ids: &[ParamID],
) -> JsonValue {
    let mut parameters = array![];
    let mut unmapped = array![];
    for &old_parameter_id in old_parameter_ids {
        let mut new_parameter_id: ParamID = 0;
        let result = unsafe {
            remapper.getCompatibleParamID(replaced_class_tuid, old_parameter_id, &mut new_parameter_id)
        };
        if result == kResultOk {
            let _ = parameters.push(object! { old: old_parameter_id, new: new_parameter_id });
        } else {
            let _ = unmapped.push(old_parameter_id);
        }
    }
    object! {
        supported: true,
        parameters: parameters,
        unmapped: unmapped,
    }
}

/// The component of the given class, a module can contain several of them
unsafe fn create_component(factory: &ComPtr<IPluginFactory>, class_id: &str) -> Result<ComPtr<IComponent>, String> {
    unsafe {
        for class_index in 0..factory.countClasses() {
            let mut class_info: PClassInfo = zeroed();
            if factory.getClassInfo(class_index, &mut class_info) != kResultOk
                || !class_id_to_string(&class_info.cid).eq_ignore_ascii_case(class_id)
            {
                continue;
            }

            let mut component_pointer: *mut IComponent = ptr::null_mut();
            let result = factory.createInstance(
                class_info.cid.as_ptr(),
                IComponent::IID.as_ptr() as *const _,
                &mut component_pointer as *mut _ as *mut *mut c_void,
            );
            return ComPtr::from_raw(component_pointer)
                .filter(|_| result == kResultOk)
                .ok_or_else(|| format!("Failed to create the component {}: {:#x}", class_id, result));
        }
        Err(format!("The plugin has no class {}", class_id))
    }
}

/// The reverse of class_id_to_string, the byte order of Windows is its own reverse
fn class_id_from_string(class_id: &str) -> Result<TUID, String> {
    let class_id = class_id.trim();
    if class_id.len() != 32 || !class_id.chars().all(|character| character.is_ascii_hexdigit()) {
        return Err(format!("Invalid class id: {}", class_id));
    }
    let bytes: Vec<u8> = (0..16)
        .map(|index| u8::from_str_radix(&class_id[index * 2..index * 2 + 2], 16).unwrap_or(0))
        .collect();
    let ordered: Vec<u8> = if cfg!(windows) {
        [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
            .iter()
            .map(|&index| bytes[index])
            .collect()
    } else {
        bytes
    };

    let mut tuid: TUID = [0; 16];
    for (target, byte) in tuid.iter_mut().zip(ordered) {
        *target = byte as _;
    }
    Ok(tuid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_class_ids_both_ways() {
        let class_id = "56535444695661646976610000000000";
        assert_eq!(class_id_to_string(&class_id_from_string(class_id).unwrap()), class_id);
        assert!(class_id_from_string("xyz").is_err());
    }
}
