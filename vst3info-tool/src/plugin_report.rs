//! Creates the plugin infos the Renoise tool reads.

use crate::plugin_inspector::{ParameterInfos, PluginInfos};
use json::{JsonValue, array, object};
use std::env;

pub fn create_report(plugin: &PluginInfos) -> JsonValue {
    let mut report = object! {
        name: plugin.name.as_str(),
        vendor: plugin.vendor.as_str(),
        version: plugin.version.as_str(),
        countParameters: plugin.parameter_count,
        countInputs: plugin.input_bus_count,
        countOutputs: plugin.output_bus_count,
        parameters: array![],
        os: env::consts::OS
    };

    // The index is the position in the list of the plugin, so it has to stay stable while filtering
    for (index, parameter) in plugin.parameters.iter().enumerate() {
        if is_automatable_parameter(parameter) {
            let _ = report["parameters"].push(object! {
                id: parameter.id,
                index: index,
                title: parameter.title.as_str(),
                stepCount: parameter.step_count
            });
        }
    }

    report
}

/// Many plugins add a large number of parameters for receiving MIDI controllers.
fn is_automatable_parameter(parameter: &ParameterInfos) -> bool {
    let lowercase_title = parameter.title.to_lowercase();

    // "cc" has to be a separate word, so names like "Acc Level" are kept
    let is_midi_parameter = lowercase_title.contains("midi")
        || lowercase_title.split_whitespace().any(|word| word == "cc");

    !lowercase_title.is_empty() && !is_midi_parameter
}
