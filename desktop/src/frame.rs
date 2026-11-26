//! The window frame in the app's own ground, never the system accent: dark grey (#131314) in the
//! dark theme, Seashell (#F1F1F1) in the light. On Windows the title bar and border take the
//! user's accent colour unless told otherwise (his PC is blue). Linux window managers draw their
//! own frames; there the theme is asked for (`theme::set_theme`) and the rest is up to the system.

use raw_window_handle::HasWindowHandle;

#[cfg(windows)]
pub fn paint(window: &impl HasWindowHandle, dark: bool) {
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
    let ebony: u32 = 0x0004_0404;
    let (ground, ink) = if dark {
        (shark, seashell)
    } else {
        (seashell, ebony)
    };
    let dark = i32::from(dark);
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
            (&ground as *const u32).cast(),
            size(4),
        );
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR as u32,
            (&ground as *const u32).cast(),
            size(4),
        );
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_TEXT_COLOR as u32,
            (&ink as *const u32).cast(),
            size(4),
        );
    }
}

#[cfg(not(windows))]
pub fn paint(_window: &impl HasWindowHandle, _dark: bool) {}
