//! The minimal host object some plugins require during their initialization.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};
use vst3::Steinberg::Vst::String128;
use vst3::Steinberg::{FUnknown, TUID, kNoInterface, kResultOk, tresult};

const HOST_NAME: &str = "RustHost";
const MAX_NAME_LENGTH: usize = 128;

#[repr(C)]
struct HostApplication {
    virtual_table: *const HostApplicationVirtualTable,
    reference_count: AtomicU32,
}

#[repr(C)]
struct HostApplicationVirtualTable {
    query_interface: unsafe extern "C" fn(*mut FUnknown, *const TUID, *mut *mut c_void) -> tresult,
    add_ref: unsafe extern "C" fn(*mut FUnknown) -> u32,
    release: unsafe extern "C" fn(*mut FUnknown) -> u32,
    get_name: unsafe extern "C" fn(*mut HostApplication, *mut String128) -> tresult,
    create_instance:
        unsafe extern "C" fn(*mut HostApplication, *mut TUID, *mut TUID, *mut *mut c_void) -> tresult,
}

static VIRTUAL_TABLE: HostApplicationVirtualTable = HostApplicationVirtualTable {
    query_interface,
    add_ref,
    release,
    get_name,
    create_instance,
};

/// Plugins may keep the host until they are terminated, and it lives as long as the short process.
pub fn create_host_application() -> *mut FUnknown {
    Box::into_raw(Box::new(HostApplication {
        virtual_table: &VIRTUAL_TABLE,
        reference_count: AtomicU32::new(1),
    })) as *mut FUnknown
}

unsafe extern "C" fn query_interface(
    _this: *mut FUnknown,
    _interface_id: *const TUID,
    _object: *mut *mut c_void,
) -> tresult {
    kNoInterface
}

unsafe extern "C" fn add_ref(this: *mut FUnknown) -> u32 {
    let host = this as *mut HostApplication;
    unsafe { (*host).reference_count.fetch_add(1, Ordering::SeqCst) + 1 }
}

unsafe extern "C" fn release(this: *mut FUnknown) -> u32 {
    let host = this as *mut HostApplication;
    let remaining_references =
        unsafe { (*host).reference_count.fetch_sub(1, Ordering::SeqCst) - 1 };
    if remaining_references == 0 {
        drop(unsafe { Box::from_raw(host) });
    }
    remaining_references
}

unsafe extern "C" fn get_name(_this: *mut HostApplication, name: *mut String128) -> tresult {
    let terminated_name = HOST_NAME.encode_utf16().chain(std::iter::once(0));
    for (index, character) in terminated_name.take(MAX_NAME_LENGTH).enumerate() {
        unsafe { (*name)[index] = character as _ };
    }
    kResultOk
}

unsafe extern "C" fn create_instance(
    _this: *mut HostApplication,
    _class_id: *mut TUID,
    _interface_id: *mut TUID,
    _object: *mut *mut c_void,
) -> tresult {
    kNoInterface
}
