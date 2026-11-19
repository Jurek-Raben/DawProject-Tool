//! The output of the VST info tools.
//!
//! By default the result is printed as readable text. The Renoise tools use the inline mode: plugins may print
//! to the console by themselves, so the JSON of the result is enclosed by unique markers.

use json::{JsonValue, object};
use std::process::exit;
use std::sync::OnceLock;

const OUTPUT_BEGIN: &str = "@@VSTINFO_BEGIN@@";
const OUTPUT_END: &str = "@@VSTINFO_END@@";
const INDENT: &str = "  ";

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum OutputMode {
    /// Readable console output
    Text,
    /// Formatted JSON
    Json,
    /// JSON in a single line, enclosed by markers
    Inline,
}

impl OutputMode {
    pub fn parse(name: &str) -> Result<Self, String> {
        match name {
            "text" => Ok(Self::Text),
            "json" => Ok(Self::Json),
            "inline" => Ok(Self::Inline),
            _ => Err(format!("Unknown output mode '{}', use text, json or inline", name)),
        }
    }
}

static OUTPUT_MODE: OnceLock<OutputMode> = OnceLock::new();

/// Only the first call has an effect, the mode can't change while the tool is running.
pub fn set_mode(mode: OutputMode) {
    let _ = OUTPUT_MODE.set(mode);
}

fn mode() -> OutputMode {
    OUTPUT_MODE.get().copied().unwrap_or(OutputMode::Text)
}

fn format_result(result: &JsonValue) -> String {
    match mode() {
        OutputMode::Text => format_as_text(result),
        OutputMode::Json => json::stringify_pretty(result.clone(), 2),
        OutputMode::Inline => format!("{}{}{}", OUTPUT_BEGIN, json::stringify(result.clone()), OUTPUT_END),
    }
}

pub fn print_result(result: JsonValue) {
    println!("{}", format_result(&result));
}

pub fn exit_with_error(error_message: &str) -> ! {
    match mode() {
        OutputMode::Text => eprintln!("error: {}", error_message),
        _ => eprintln!("{}", format_result(&object! { error: error_message })),
    }
    exit(1);
}

/// Formats the result as an indented list of keys and values.
fn format_as_text(result: &JsonValue) -> String {
    let lines = if is_scalar(result) {
        vec![format_scalar(result)]
    } else {
        format_lines(result, 0)
    };
    lines.join("\n")
}

fn format_lines(value: &JsonValue, depth: usize) -> Vec<String> {
    let indent = INDENT.repeat(depth);
    let mut lines = Vec::new();

    if value.is_object() {
        for (key, member) in value.entries() {
            if is_scalar(member) || is_empty(member) || is_scalar_list(member) {
                lines.push(format!("{}{}: {}", indent, key, format_inline(member)));
            } else {
                lines.push(format!("{}{}:", indent, key));
                lines.extend(format_lines(member, depth + 1));
            }
        }
    } else if value.is_array() {
        for member in value.members() {
            if is_scalar(member) || is_empty(member) || is_scalar_list(member) {
                lines.push(format!("{}- {}", indent, format_inline(member)));
                continue;
            }
            // the first line of the member starts with the dash, like in YAML
            let mut member_lines = format_lines(member, depth + 1);
            if let Some(first_line) = member_lines.first_mut() {
                *first_line = format!("{}- {}", indent, first_line.trim_start());
            }
            lines.extend(member_lines);
        }
    }
    lines
}

fn format_inline(value: &JsonValue) -> String {
    if value.is_array() {
        if value.is_empty() {
            return "(none)".to_string();
        }
        return value.members().map(format_scalar).collect::<Vec<_>>().join(", ");
    }
    if value.is_object() {
        return "(none)".to_string();
    }
    format_scalar(value)
}

fn format_scalar(value: &JsonValue) -> String {
    match value.as_str() {
        Some(text) => text.to_string(),
        None if value.is_null() => "-".to_string(),
        None => value.dump(),
    }
}

fn is_scalar(value: &JsonValue) -> bool {
    !value.is_object() && !value.is_array()
}

fn is_empty(value: &JsonValue) -> bool {
    (value.is_object() || value.is_array()) && value.is_empty()
}

fn is_scalar_list(value: &JsonValue) -> bool {
    value.is_array() && value.members().all(is_scalar)
}

#[cfg(test)]
mod tests {
    use super::*;
    use json::array;

    #[test]
    fn formats_nested_values_as_text() {
        let result = object! {
            healthy: true,
            tool: "vst3info-tool",
            ids: array![1, 2, 3],
            empty: array![],
            plugins: array![
                object! { path: "/a.vst3", accessible: true },
                object! { path: "/b.vst3", accessible: false, error: "missing" }
            ]
        };

        assert_eq!(
            format_as_text(&result),
            "healthy: true\n\
             tool: vst3info-tool\n\
             ids: 1, 2, 3\n\
             empty: (none)\n\
             plugins:\n\
             \x20 - path: /a.vst3\n\
             \x20   accessible: true\n\
             \x20 - path: /b.vst3\n\
             \x20   accessible: false\n\
             \x20   error: missing"
        );
    }

    #[test]
    fn parses_output_modes() {
        assert_eq!(OutputMode::parse("inline"), Ok(OutputMode::Inline));
        assert!(OutputMode::parse("xml").is_err());
    }
}
