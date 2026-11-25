//! The window frame in the app's own dark grey (#131314), never the system accent: on Windows the
//! title bar and border take the user's accent colour unless told otherwise (his PC is blue).
//! Linux window managers draw their own frames; there the dark theme is asked for and the rest is
//! up to the system.

use raw_window_handle::HasWindowHandle;

#[cfg(windows)]
pub fn paint(window: &impl HasWindowHandle) {
    use raw_window_handle::RawWindowHandle;
    use windows_sys::Win32::Graphics::Dwm::{
        DWMWA_BORDER_COLOR, DWMWA_CAPTION_COLOR, DWMWA_TEXT_COLOR, DWMWA_USE_IMMERSIVE_DARK_MODE,
        DwmSetWindowAttribute,
    };
    let Ok(handle) = window.window_handle() else {
        return;
    };
    let RawWindowHandle::Win32(win) = handle.as_raw() else {
        return;
    };
    let hwnd = win.hwnd.get() as windows_sys::Win32::Foundation::HWND;
    // COLORREF is 0x00BBGGRR.
    let shark: u32 = 0x0014_1313;
    let seashell: u32 = 0x00F1_F1F1;
    let dark: i32 = 1;
    let size = |n: usize| n as u32;
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&dark as *const i32).cast(),
            size(4),
        );
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_CAPTION_COLOR as u32,
            (&shark as *const u32).cast(),
            size(4),
        );
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR as u32,
            (&shark as *const u32).cast(),
            size(4),
        );
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_TEXT_COLOR as u32,
            (&seashell as *const u32).cast(),
            size(4),
        );
    }
}

#[cfg(not(windows))]
pub fn paint(_window: &impl HasWindowHandle) {}
