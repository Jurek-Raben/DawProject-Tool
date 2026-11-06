//! The command line of the VST info tools.

use std::ffi::OsString;
use std::path::PathBuf;

const HEALTHCHECK_SWITCH: &str = "--healthcheck";

pub enum Command {
    /// Reports that the tool is able to start and whether it can access the given plugins.
    Healthcheck { plugin_paths: Vec<PathBuf> },
    /// Loads a plugin and reports its infos.
    ReadPlugin {
        plugin_path: PathBuf,
        additional_arguments: Vec<OsString>,
    },
}

pub fn parse_command(arguments: impl Iterator<Item = OsString>) -> Result<Command, String> {
    let mut arguments = arguments;
    let first_argument = arguments
        .next()
        .ok_or("Plugin path required as first argument")?;

    if first_argument == HEALTHCHECK_SWITCH {
        return Ok(Command::Healthcheck {
            plugin_paths: arguments.map(PathBuf::from).collect(),
        });
    }

    Ok(Command::ReadPlugin {
        plugin_path: PathBuf::from(first_argument),
        additional_arguments: arguments.collect(),
    })
}
