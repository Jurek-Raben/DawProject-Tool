//! A read only stream for handing a state over to a plugin.

use std::cell::Cell;
use std::ffi::c_void;
use std::ptr;
use vst3::Class;
use vst3::Steinberg::{IBStream, IBStreamTrait, kInvalidArgument, kResultFalse, kResultOk, tresult};

const SEEK_FROM_START: i32 = 0;
const SEEK_FROM_CURRENT: i32 = 1;
const SEEK_FROM_END: i32 = 2;

pub struct MemoryStream {
    data: Vec<u8>,
    position: Cell<usize>,
}

impl MemoryStream {
    pub fn new(data: Vec<u8>) -> Self {
        Self {
            data,
            position: Cell::new(0),
        }
    }
}

impl Class for MemoryStream {
    type Interfaces = (IBStream,);
}

#[allow(non_snake_case)]
impl IBStreamTrait for MemoryStream {
    unsafe fn read(&self, buffer: *mut c_void, numBytes: i32, numBytesRead: *mut i32) -> tresult {
        let Ok(requested_size) = usize::try_from(numBytes) else {
            return kInvalidArgument;
        };
        let position = self.position.get();
        let read_size = requested_size.min(self.data.len().saturating_sub(position));

        unsafe {
            ptr::copy_nonoverlapping(self.data.as_ptr().add(position), buffer as *mut u8, read_size);
            if !numBytesRead.is_null() {
                *numBytesRead = read_size as i32;
            }
        }
        self.position.set(position + read_size);
        kResultOk
    }

    unsafe fn write(&self, _buffer: *mut c_void, _numBytes: i32, _numBytesWritten: *mut i32) -> tresult {
        kResultFalse
    }

    unsafe fn seek(&self, pos: i64, mode: i32, result: *mut i64) -> tresult {
        let base = match mode {
            SEEK_FROM_START => 0,
            SEEK_FROM_CURRENT => self.position.get() as i64,
            SEEK_FROM_END => self.data.len() as i64,
            _ => return kInvalidArgument,
        };
        let new_position = base + pos;
        if new_position < 0 || new_position > self.data.len() as i64 {
            return kResultFalse;
        }

        self.position.set(new_position as usize);
        if !result.is_null() {
            unsafe { *result = new_position };
        }
        kResultOk
    }

    unsafe fn tell(&self, pos: *mut i64) -> tresult {
        if pos.is_null() {
            return kInvalidArgument;
        }
        unsafe { *pos = self.position.get() as i64 };
        kResultOk
    }
}
