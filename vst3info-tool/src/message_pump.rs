//! Lets a plugin process its queued messages. Plugins can finish loading a state asynchronously,
//! which needs the message loop a host usually provides.

#[cfg(target_os = "macos")]
pub fn process_pending_messages() {
    use std::ffi::c_void;

    const SECONDS_TO_PROCESS: f64 = 1.0;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFRunLoopDefaultMode: *const c_void;
        fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after_source_handled: u8) -> i32;
    }

    unsafe {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, SECONDS_TO_PROCESS, 0);
    }
}

#[cfg(not(target_os = "macos"))]
pub fn process_pending_messages() {}
