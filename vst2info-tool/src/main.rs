/*!
 * ------------------------------------------------------------------------
 * VST2 Info Extractor Tool
 * by Jurek Raben
 *
 * Licensed under CC Attribution-NonCommercial-ShareAlike 4.0 International
 * Info here: https://creativecommons.org/licenses/by-nc-sa/4.0/
 * ------------------------------------------------------------------------
 */

extern crate vst2;

use std::env;
use std::error::Error;
use std::path::Path;
use std::sync::{Arc, Mutex};

use vst2::host::{Host, PluginLoader};
use vst2::plugin::Plugin;

use base64::prelude::*;

use json::object;

struct SampleHost;

impl Host for SampleHost {}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        println!("Error: Plugin path required.");
        return;
    }

    let path = Path::new(&args[1]);
    let host = Arc::new(Mutex::new(SampleHost));

    let mut loader =
        PluginLoader::load(path, host.clone()).unwrap_or_else(|e| panic!("{}", e.description()));

    let mut instance = loader.instance().unwrap();

    let info = instance.get_info();

    let preset_name;
    let preset_data;
    if (args.len() > 2) && (&args[2].to_string()).len() > 0 {
        let preset_num = (&args[2].to_string()).parse().unwrap();
        instance.change_preset(preset_num);
        preset_name = instance.get_preset_name(preset_num);
        preset_data = BASE64_STANDARD.encode(instance.get_preset_data());
    } else {
        preset_name = String::from("");
        preset_data = String::from("");
    }

    let output = json::stringify(object! {
        name: info.name,
        vendor: info.vendor,
        numPresets: info.presets,
        numParameters: info.parameters,
        numInputs: info.inputs,
        numOutputs: info.outputs,
        id: info.unique_id,
        version: info.version,
        delay: info.initial_delay,
        presetName: preset_name,
        presetData: preset_data,
    });

    println!("{}", output);
}
