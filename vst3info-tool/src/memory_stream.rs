//! A stream in memory, for handing a state over to a plugin or for receiving data from it.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::ptr;
use vst3::Class;
use vst3::Steinberg::{IBStream, IBStreamTrait, kInvalidArgument, kResultFalse, kResultOk, tresult};

const SEEK_FROM_START: i32 = 0;
const SEEK_FROM_CURRENT: i32 = 1;
const SEEK_FROM_END: i32 = 2;

pub struct MemoryStream {
    data: RefCell<Vec<u8>>,
    position: Cell<usize>,
}

impl MemoryStream {
    pub fn new(data: Vec<u8>) -> Self {
        Self {
            data: RefCell::new(data),
            position: Cell::new(0),
        }
    }

    /// The data written by the plugin
    pub fn data(&self) -> Vec<u8> {
        self.data.borrow().clone()
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
        let data = self.data.borrow();
        let position = self.position.get();
        let read_size = requested_size.min(data.len().saturating_sub(position));

        unsafe {
            ptr::copy_nonoverlapping(data.as_ptr().add(position), buffer as *mut u8, read_size);
            if !numBytesRead.is_null() {
                *numBytesRead = read_size as i32;
            }
        }
        self.position.set(position + read_size);
        kResultOk
    }

    /// Overwrites the data at the current position and extends it, if needed
    unsafe fn write(&self, buffer: *mut c_void, numBytes: i32, numBytesWritten: *mut i32) -> tresult {
        let Ok(write_size) = usize::try_from(numBytes) else {
            return kInvalidArgument;
        };
        if buffer.is_null() && write_size > 0 {
            return kInvalidArgument;
        }

        let mut data = self.data.borrow_mut();
        let position = self.position.get();
        if data.len() < position + write_size {
            data.resize(position + write_size, 0);
        }

        unsafe {
            ptr::copy_nonoverlapping(buffer as *const u8, data.as_mut_ptr().add(position), write_size);
            if !numBytesWritten.is_null() {
                *numBytesWritten = write_size as i32;
            }
        }
        self.position.set(position + write_size);
        kResultOk
    }

    unsafe fn seek(&self, pos: i64, mode: i32, result: *mut i64) -> tresult {
        let length = self.data.borrow().len() as i64;
        let base = match mode {
            SEEK_FROM_START => 0,
            SEEK_FROM_CURRENT => self.position.get() as i64,
            SEEK_FROM_END => length,
            _ => return kInvalidArgument,
        };
        let new_position = base + pos;
        if new_position < 0 || new_position > length {
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
