//! Creates the plugin infos the Renoise tool reads.

use crate::plugin_instance::PluginInstance;
use json::{JsonValue, object};
use std::env;

pub fn create_report(plugin: &PluginInstance, shell_plugin_id: Option<i32>) -> JsonValue {
    let name = plugin.name();
    let vendor = plugin.vendor();
    let effect = plugin.effect();

    let mut report = object! {
        name: name,
        vendor: vendor,
        countPresets: effect.num_programs,
        countParameters: effect.num_params,
        countInputs: effect.num_inputs,
        countOutputs: effect.num_outputs,
        id: effect.unique_id,
        version: effect.version,
        delay: effect.initial_delay,
        os: env::consts::OS
    };

    if let Some(id) = shell_plugin_id.filter(|_| effect.unique_id == 0) {
        report["id"] = id.into();
    }

    // Without a selected plugin, a shell only reports the plugins it contains
    if shell_plugin_id.is_none() && plugin.is_shell() {
        report["shellPlugins"] = create_shell_plugin_list(plugin);
    }

    report
}

fn create_shell_plugin_list(plugin: &PluginInstance) -> JsonValue {
    let mut shell_plugin_list = JsonValue::new_array();
    for shell_plugin in plugin.read_shell_plugins() {
        let _ = shell_plugin_list.push(object! {
            id: shell_plugin.id,
            name: shell_plugin.name
        });
    }
    shell_plugin_list
}
