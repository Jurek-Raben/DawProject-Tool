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
use std::panic;
use std::path::PathBuf;
use std::process::exit;
use std::sync::{Arc, Mutex};

use vst2::host::{Host, PluginLoader};
use vst2::plugin::Plugin;

use base64::prelude::*;

use json::object;

struct SampleHost;

impl Host for SampleHost {}

fn error_exit(error_message: String) {
    eprintln!("{}", json::stringify(object! { error: error_message }));
    exit(1);
}

fn main() {
    panic::set_hook(Box::new(|_info| {
        // do nothing
    }));

    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        error_exit(String::from("Plugin path required as first argument"));
    }

    let mut path = PathBuf::from(&args[1]);
    let path_string: String = path.display().to_string();

    if env::consts::OS == "macos" && path.is_dir() && path_string.ends_with(".vst") {
        let file_name = path.file_name().unwrap().to_str().unwrap_or("");
        if file_name != "" {
            path = PathBuf::from(
                path_string + "/Contents/MacOS/" + file_name.replace(".vst", "").as_str(),
            );
        }
    }

    if !path.exists() || path.is_dir() {
        error_exit(path.display().to_string() + " does not exist");
    }

    let host = Arc::new(Mutex::new(SampleHost));
    let mut loader =
        PluginLoader::load(&path, host.clone()).unwrap_or_else(|e| panic!("{}", e.description()));

    let mut instance = loader.instance().unwrap();
    let info = instance.get_info();

    let mut output = object! {
        name: info.name,
        vendor: info.vendor,
        countPresets: info.presets,
        countParameters: info.parameters,
        countInputs: info.inputs,
        countOutputs: info.outputs,
        id: info.unique_id,
        version: info.version,
        delay: info.initial_delay,
        os: env::consts::OS
    };

    if (args.len() > 2) && (&args[2].to_string()).len() > 0 {
        let preset_num = (&args[2].to_string()).parse().unwrap();
        instance.change_preset(preset_num);
        output.insert("presetName", instance.get_preset_name(preset_num));
        output.insert(
            "presetData",
            BASE64_STANDARD.encode(instance.get_preset_data()),
        );
    }

    println!("{}", json::stringify(output));
}
