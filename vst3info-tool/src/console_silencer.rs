//! Keeps plugins from writing into the console while they are running.

#[cfg(unix)]
pub fn run_silenced<ResultType>(action: impl FnOnce() -> ResultType) -> ResultType {
    use std::fs::File;
    use std::io;
    use std::os::unix::io::AsRawFd;

    let stdout_descriptor = io::stdout().as_raw_fd();
    let stderr_descriptor = io::stderr().as_raw_fd();

    let Ok(null_device) = File::create("/dev/null") else {
        return action();
    };

    unsafe {
        let saved_stdout = libc::dup(stdout_descriptor);
        let saved_stderr = libc::dup(stderr_descriptor);
        if saved_stdout == -1 || saved_stderr == -1 {
            return action();
        }

        libc::dup2(null_device.as_raw_fd(), stdout_descriptor);
        libc::dup2(null_device.as_raw_fd(), stderr_descriptor);

        let result = action();

        libc::dup2(saved_stdout, stdout_descriptor);
        libc::dup2(saved_stderr, stderr_descriptor);
        libc::close(saved_stdout);
        libc::close(saved_stderr);

        result
    }
}

#[cfg(windows)]
pub fn run_silenced<ResultType>(action: impl FnOnce() -> ResultType) -> ResultType {
    use std::ptr::null_mut;
    use winapi::um::fileapi::{CreateFileW, OPEN_EXISTING};
    use winapi::um::handleapi::{CloseHandle, INVALID_HANDLE_VALUE};
    use winapi::um::processenv::{GetStdHandle, SetStdHandle};
    use winapi::um::winbase::{STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
    use winapi::um::winnt::{FILE_ATTRIBUTE_NORMAL, FILE_SHARE_WRITE, GENERIC_WRITE};

    let null_device_name: Vec<u16> = "NUL".encode_utf16().chain(std::iter::once(0)).collect();

    unsafe {
        let stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
        let stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
        if stdout_handle == INVALID_HANDLE_VALUE || stderr_handle == INVALID_HANDLE_VALUE {
            return action();
        }

        let null_device = CreateFileW(
            null_device_name.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_WRITE,
            null_mut(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        );
        if null_device == INVALID_HANDLE_VALUE {
            return action();
        }

        SetStdHandle(STD_OUTPUT_HANDLE, null_device);
        SetStdHandle(STD_ERROR_HANDLE, null_device);

        let result = action();

        SetStdHandle(STD_OUTPUT_HANDLE, stdout_handle);
        SetStdHandle(STD_ERROR_HANDLE, stderr_handle);
        CloseHandle(null_device);

        result
    }
}
