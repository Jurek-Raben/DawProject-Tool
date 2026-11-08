//! The command line of the VST info tools.

use std::ffi::OsString;
use std::path::PathBuf;

const HEALTHCHECK_SWITCH: &str = "--healthcheck";
const MIGRATION_INFO_SWITCH: &str = "--migration-info";
const REMAP_PARAMETERS_SWITCH: &str = "--remap-parameters";

pub enum Command {
    /// Reports that the tool is able to start and whether it can access the given plugins.
    Healthcheck { plugin_paths: Vec<PathBuf> },
    /// Reports which older plugins a plugin can replace, e.g. a VST3 replacing its VST2 version.
    MigrationInfo { plugin_path: PathBuf },
    /// Reports which parameters of a class replace the parameters of a replaced plugin.
    RemapParameters {
        plugin_path: PathBuf,
        class_id: String,
        replaced_class_id: String,
        old_parameter_ids: Vec<u32>,
    },
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

    if first_argument == MIGRATION_INFO_SWITCH {
        let plugin_path = arguments
            .next()
            .ok_or("The migration info switch needs the path of a plugin")?;
        return Ok(Command::MigrationInfo {
            plugin_path: PathBuf::from(plugin_path),
        });
    }

    // <plugin path> <class id> <class id of the replaced plugin> <old parameter ids...>
    if first_argument == REMAP_PARAMETERS_SWITCH {
        let usage = "The remap parameters switch needs the plugin path, the class id, the class id of the replaced \
                     plugin and the old parameter ids";
        let plugin_path = arguments.next().ok_or(usage)?;
        let class_id = arguments.next().and_then(|id| id.into_string().ok()).ok_or(usage)?;
        let replaced_class_id = arguments.next().and_then(|id| id.into_string().ok()).ok_or(usage)?;
        let old_parameter_ids = arguments
            .map(|id| {
                id.to_str()
                    .and_then(|id| id.parse().ok())
                    .ok_or_else(|| format!("Invalid parameter id: {}", id.to_string_lossy()))
            })
            .collect::<Result<Vec<u32>, String>>()?;
        return Ok(Command::RemapParameters {
            plugin_path: PathBuf::from(plugin_path),
            class_id,
            replaced_class_id,
            old_parameter_ids,
        });
    }

    Ok(Command::ReadPlugin {
        plugin_path: PathBuf::from(first_argument),
        additional_arguments: arguments.collect(),
    })
}
