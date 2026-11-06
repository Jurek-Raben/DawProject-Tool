//! The output of the VST info tools.
//!
//! Plugins may print to the console by themselves, so the result is enclosed by unique markers.

use json::{JsonValue, object};
use std::process::exit;

const OUTPUT_BEGIN: &str = "@@VSTINFO_BEGIN@@";
const OUTPUT_END: &str = "@@VSTINFO_END@@";

fn enclose_in_markers(result: JsonValue) -> String {
    format!("{}{}{}", OUTPUT_BEGIN, json::stringify(result), OUTPUT_END)
}

pub fn print_result(result: JsonValue) {
    println!("{}", enclose_in_markers(result));
}

pub fn exit_with_error(error_message: &str) -> ! {
    eprintln!(
        "{}",
        enclose_in_markers(object! { error: error_message })
    );
    exit(1);
}
