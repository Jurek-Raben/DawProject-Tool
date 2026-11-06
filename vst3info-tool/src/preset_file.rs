//! Reads the states stored in a .vstpreset file.

use std::fs;
use std::path::Path;

const HEADER_SIZE: usize = 48;
const LIST_OFFSET_POSITION: usize = 40;
const LIST_HEADER_SIZE: usize = 8;
const LIST_ENTRY_SIZE: usize = 20;

pub struct PresetStates {
    pub component_state: Vec<u8>,
    pub controller_state: Vec<u8>,
}

pub fn read_preset_states(preset_path: &Path) -> Result<PresetStates, String> {
    let data = fs::read(preset_path)
        .map_err(|error| format!("Can't read {}: {}", preset_path.display(), error))?;

    if data.len() < HEADER_SIZE || !data.starts_with(b"VST3") {
        return Err(format!("{} is no VST3 preset", preset_path.display()));
    }

    Ok(PresetStates {
        component_state: find_chunk(&data, b"Comp").ok_or("The preset has no component state")?,
        controller_state: find_chunk(&data, b"Cont").unwrap_or_default(),
    })
}

fn read_u64(data: &[u8], position: usize) -> Option<usize> {
    let bytes = data.get(position..position + 8)?.try_into().ok()?;
    usize::try_from(u64::from_le_bytes(bytes)).ok()
}

fn find_chunk(data: &[u8], chunk_id: &[u8; 4]) -> Option<Vec<u8>> {
    let list_offset = read_u64(data, LIST_OFFSET_POSITION)?;
    let entries_offset = list_offset + LIST_HEADER_SIZE;
    let entry_count = u32::from_le_bytes(data.get(list_offset + 4..entries_offset)?.try_into().ok()?);

    (0..entry_count as usize).find_map(|index| {
        let entry = entries_offset + index * LIST_ENTRY_SIZE;
        if data.get(entry..entry + 4)? != chunk_id {
            return None;
        }
        let offset = read_u64(data, entry + 4)?;
        let size = read_u64(data, entry + 12)?;
        data.get(offset..offset + size).map(<[u8]>::to_vec)
    })
}
