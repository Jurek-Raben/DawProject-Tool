//! Reads which older plugins a VST3 plugin can replace, e.g. its own VST2 version.
//!
//! The plugin declares this as list of compatibilities, each with the class id of the new class and the
//! class ids of the old plugins. For VST2 plugins the old class id is derived from the VST2 id and name.
//! There are two sources, the first one available is used:
//!  - the moduleinfo.json inside of the bundle, the plugin isn't loaded for this
//!  - the "Plugin Compatibility Class" of the factory, which needs the plugin to be loaded
//!
//! The result is normalized, independent of its source:
//! { source, vendor, classes: [{ cid, name, vendor, category }], compatibility: [{ new, old: [] }] }

use crate::console_silencer;
use crate::memory_stream::MemoryStream;
use crate::plugin_binary;
use crate::plugin_module::PluginModule;
use crate::vst3_strings::string_from_utf8_buffer;
use json::{JsonValue, array, object};
use std::ffi::c_void;
use std::mem::zeroed;
use std::path::{Path, PathBuf};
use std::ptr;
use vst3::Steinberg::{
    IBStream, IPluginCompatibility, IPluginCompatibilityTrait, IPluginFactory, IPluginFactoryTrait,
    PClassInfo, TUID, kResultOk,
};
use vst3::{ComPtr, ComWrapper, Interface};

const MODULE_INFO_FILE_NAME: &str = "moduleinfo.json";
const PLUGIN_COMPATIBILITY_CATEGORY: &str = "Plugin Compatibility Class";

const SOURCE_MODULE_INFO: &str = "moduleinfo";
const SOURCE_FACTORY: &str = "factory";

pub fn read_migration_info(plugin_path: &Path) -> Result<JsonValue, String> {
    if let Some(module_info_path) = find_module_info(plugin_path) {
        let module_info = read_lenient_json_file(&module_info_path)?;
        return Ok(normalize_module_info(&module_info));
    }

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
        read_factory(&module.plugin_factory()?)
    })
    .map_err(|error| format!("Failed to load or inspect plugin: {}", error))
}

/// The moduleinfo.json belongs into the resources of the bundle, but some vendors place it next to them
fn find_module_info(plugin_path: &Path) -> Option<PathBuf> {
    if !plugin_path.is_dir() {
        return None;
    }
    let contents_path = plugin_path.join("Contents");
    [
        contents_path.join("Resources").join(MODULE_INFO_FILE_NAME),
        contents_path.join(MODULE_INFO_FILE_NAME),
    ]
    .into_iter()
    .find(|path| path.is_file())
}

fn read_lenient_json_file(path: &Path) -> Result<JsonValue, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| format!("Can't read {}: {}", path.display(), error))?;
    parse_lenient_json(&text).map_err(|error| format!("Invalid JSON in {}: {}", path.display(), error))
}

/// The VST3 SDK writes JSON5, at least with commas in front of closing brackets
fn parse_lenient_json(text: &str) -> Result<JsonValue, String> {
    json::parse(&remove_trailing_commas(text)).map_err(|error| error.to_string())
}

fn remove_trailing_commas(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut is_in_string = false;
    let mut is_escaped = false;

    for (index, &character) in characters.iter().enumerate() {
        if is_in_string {
            result.push(character);
            if is_escaped {
                is_escaped = false;
            } else if character == '\\' {
                is_escaped = true;
            } else if character == '"' {
                is_in_string = false;
            }
            continue;
        }

        if character == '"' {
            is_in_string = true;
        } else if character == ',' {
            let next_character = characters[index + 1..].iter().find(|c| !c.is_whitespace());
            if matches!(next_character, Some('}') | Some(']')) {
                continue;
            }
        }
        result.push(character);
    }
    result
}

fn normalize_module_info(module_info: &JsonValue) -> JsonValue {
    let mut classes = array![];
    for class in module_info["Classes"].members() {
        let _ = classes.push(object! {
            cid: normalize_class_id(class["CID"].as_str().unwrap_or("")),
            name: class["Name"].as_str().unwrap_or(""),
            vendor: class["Vendor"].as_str().unwrap_or(""),
            category: class["Category"].as_str().unwrap_or(""),
        });
    }

    object! {
        source: SOURCE_MODULE_INFO,
        vendor: module_info["Factory Info"]["Vendor"].as_str().unwrap_or(""),
        classes: classes,
        compatibility: normalize_compatibility(&module_info["Compatibility"]),
    }
}

fn normalize_compatibility(compatibility: &JsonValue) -> JsonValue {
    let mut entries = array![];
    for entry in compatibility.members() {
        let mut old_class_ids = array![];
        for old_class_id in entry["Old"].members() {
            let _ = old_class_ids.push(normalize_class_id(old_class_id.as_str().unwrap_or("")));
        }
        let _ = entries.push(object! {
            new: normalize_class_id(entry["New"].as_str().unwrap_or("")),
            old: old_class_ids,
        });
    }
    entries
}

/// Upper case hex, like Renoise lists the class ids
fn normalize_class_id(class_id: &str) -> String {
    class_id.trim().to_uppercase()
}

unsafe fn read_class_info(factory: &ComPtr<IPluginFactory>, class_index: i32) -> Option<PClassInfo> {
    unsafe {
        let mut class_info: PClassInfo = zeroed();
        (factory.getClassInfo(class_index, &mut class_info) == kResultOk).then_some(class_info)
    }
}

fn read_factory(factory: &ComPtr<IPluginFactory>) -> Result<JsonValue, String> {
    unsafe {
        let mut factory_info = zeroed();
        let vendor = if factory.getFactoryInfo(&mut factory_info) == kResultOk {
            string_from_utf8_buffer(&factory_info.vendor)
        } else {
            String::new()
        };

        let mut classes = array![];
        let mut compatibility = array![];

        for class_index in 0..factory.countClasses() {
            let Some(class_info) = read_class_info(factory, class_index) else {
                continue;
            };
            let category = string_from_utf8_buffer(&class_info.category);

            if category == PLUGIN_COMPATIBILITY_CATEGORY {
                compatibility = read_compatibility_class(factory, &class_info.cid)?;
                continue;
            }

            let _ = classes.push(object! {
                cid: class_id_to_string(&class_info.cid),
                name: string_from_utf8_buffer(&class_info.name),
                vendor: vendor.as_str(),
                category: category,
            });
        }

        Ok(object! {
            source: SOURCE_FACTORY,
            vendor: vendor.as_str(),
            classes: classes,
            compatibility: compatibility,
        })
    }
}

/// The class writes the same JSON as the "Compatibility" of the moduleinfo.json into a stream
unsafe fn read_compatibility_class(factory: &ComPtr<IPluginFactory>, class_id: &TUID) -> Result<JsonValue, String> {
    unsafe {
        let mut compatibility_pointer: *mut IPluginCompatibility = ptr::null_mut();
        let result = factory.createInstance(
            class_id.as_ptr(),
            IPluginCompatibility::IID.as_ptr() as *const _,
            &mut compatibility_pointer as *mut _ as *mut *mut c_void,
        );
        let Some(compatibility) = ComPtr::from_raw(compatibility_pointer).filter(|_| result == kResultOk) else {
            return Err(format!("Failed to create the compatibility class: {:#x}", result));
        };

        let stream = ComWrapper::new(MemoryStream::new(Vec::new()));
        let stream_pointer = stream
            .to_com_ptr::<IBStream>()
            .ok_or("Failed to create a stream")?;
        // Some plugins have the class, but nothing to declare
        let result = compatibility.getCompatibilityJSON(stream_pointer.as_ptr());
        if result != kResultOk || stream.data().is_empty() {
            return Ok(array![]);
        }

        let text = String::from_utf8_lossy(&stream.data()).to_string();
        let compatibility_json = parse_lenient_json(&text)
            .map_err(|error| format!("Invalid compatibility JSON of the plugin: {}", error))?;
        Ok(normalize_compatibility(&compatibility_json))
    }
}

/// The string form of a class id, as FUID::toString of the VST3 SDK writes it.
/// On Windows the class ids are COM compatible, the first three parts are stored little endian there.
pub(crate) fn class_id_to_string(class_id: &TUID) -> String {
    let bytes: Vec<u8> = class_id.iter().map(|&byte| byte as u8).collect();
    let ordered: Vec<u8> = if cfg!(windows) {
        [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
            .iter()
            .map(|&index| bytes[index])
            .collect()
    } else {
        bytes
    };
    ordered.iter().map(|byte| format!("{:02X}", byte)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_trailing_commas_outside_of_strings() {
        let text = r#"{ "a": [1, 2, ], "b": "x, }", "c": { "d": 1, }, }"#;
        let parsed = parse_lenient_json(text).unwrap();
        assert_eq!(parsed["a"].len(), 2);
        assert_eq!(parsed["b"], "x, }");
        assert_eq!(parsed["c"]["d"], 1);
    }

    #[test]
    fn normalizes_the_compatibility_of_a_module_info() {
        let module_info = parse_lenient_json(
            r#"{ "Factory Info": { "Vendor": "u-he", },
                 "Compatibility": [ { "New": "d39d5b69d6af42fa1234567844695661",
                                      "Old": [ "56535444695661646976610000000000", ], }, ],
                 "Classes": [ { "CID": "D39D5B69D6AF42FA1234567844695661", "Name": "Diva",
                                "Vendor": "u-he", "Category": "Audio Module Class", }, ], }"#,
        )
        .unwrap();
        let info = normalize_module_info(&module_info);
        assert_eq!(info["source"], "moduleinfo");
        assert_eq!(info["vendor"], "u-he");
        assert_eq!(info["classes"][0]["cid"], "D39D5B69D6AF42FA1234567844695661");
        assert_eq!(info["compatibility"][0]["new"], "D39D5B69D6AF42FA1234567844695661");
        assert_eq!(info["compatibility"][0]["old"][0], "56535444695661646976610000000000");
    }
}
