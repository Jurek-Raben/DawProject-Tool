//! Converts the zero terminated strings of the VST3 interfaces.

pub fn string_from_utf8_buffer<T: Copy + Into<i32>>(buffer: &[T]) -> String {
    let bytes: Vec<u8> = buffer
        .iter()
        .map(|&character| character.into())
        .take_while(|&character| character != 0)
        .map(|character| character as u8)
        .collect();
    String::from_utf8_lossy(&bytes).to_string()
}

pub fn string_from_utf16_buffer<T: Copy + Into<i32>>(buffer: &[T]) -> String {
    let characters: Vec<u16> = buffer
        .iter()
        .map(|&character| character.into())
        .take_while(|&character| character != 0)
        .map(|character| character as u16)
        .collect();
    String::from_utf16_lossy(&characters)
}
