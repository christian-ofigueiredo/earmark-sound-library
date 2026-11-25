//! Earmark's own pieces on top of the family theme (theme.rs, shared as it is with Aspect and the
//! other apps): the segmented switches (Sound Effects | Music, List | Map), keys of a set width,
//! text cut to one line, and small-capital titles.

use crate::theme::{self, Key};
use egui::epaint::CornerRadius;
use egui::{Align2, Color32, FontId, Rect, Response, Sense, Ui, pos2, vec2};
use std::sync::Arc;

/// Notes and counts: quieter than `INK_MUTED` (the web window's `--ink-note`).
pub const INK_NOTE: Color32 = Color32::from_rgba_unmultiplied_const(0xf1, 0xf1, 0xf1, 117);
pub const KEY_HEIGHT: f32 = 30.0;

/// Raised in a given fill (the theme's `raised` is in the ground's colour): red for what's chosen.
pub fn raise(ui: &Ui, rect: Rect, radius: f32, fill: Color32) {
    theme::raised(ui, rect, radius, 0.6);
    if fill != theme::GROUND {
        let r = CornerRadius::same(radius.min(255.0) as u8);
        ui.painter().rect_filled(rect, r, fill);
        theme::rim(ui, rect, radius);
    }
}

/// A key as the theme's `button`, of a set width (None: as wide as its words). Disabled keys
/// print their words quietly and don't answer clicks.
pub fn key(ui: &mut Ui, kind: Key, title: &str, enabled: bool, width: Option<f32>) -> Response {
    if width.is_none() && enabled {
        return theme::button(ui, kind, title, false);
    }
    let font = theme::label();
    let w = width.unwrap_or(theme::text_width(ui, title, &font) + 2.0 * theme::S4);
    let sense = if enabled { Sense::click() } else { Sense::hover() };
    let (rect, response) = ui.allocate_exact_size(vec2(w, KEY_HEIGHT), sense);
    if ui.is_rect_visible(rect) {
        let r = KEY_HEIGHT / 2.0;
        let pressed = enabled && response.is_pointer_button_down_on();
        match kind {
            Key::Primary => raise(ui, rect, r, theme::ACCENT),
            _ if pressed => theme::sunken(ui, rect, r),
            _ => theme::raised(ui, rect, r, 0.6),
        }
        let color = if !enabled {
            INK_NOTE
        } else if kind == Key::Primary {
            theme::SEASHELL
        } else {
            theme::INK
        };
        let g = elided(ui, title, font, color, w - 2.0 * theme::S2);
        ui.painter().galley(rect.center() - g.size() / 2.0, g, color);
    }
    if enabled {
        response.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        response
    }
}

/// Segments in a sunken pill; the chosen one raised in red. Answers the one pressed.
pub fn segments(ui: &mut Ui, labels: &[&str], chosen: usize, height: f32, pad: f32) -> Option<usize> {
    let font = theme::label();
    let widths: Vec<f32> = labels
        .iter()
        .map(|l| theme::text_width(ui, l, &font) + 2.0 * pad)
        .collect();
    let total: f32 = widths.iter().sum();
    let (rect, _) = ui.allocate_exact_size(vec2(total, height), Sense::hover());
    theme::sunken(ui, rect, height / 2.0);
    let mut x = rect.min.x;
    let mut pressed = None;
    for (i, (label, w)) in labels.iter().zip(&widths).enumerate() {
        let seg = Rect::from_min_size(pos2(x, rect.min.y), vec2(*w, height));
        let response = ui
            .interact(seg, ui.scope_id().with(("segment", label)), Sense::click())
            .on_hover_cursor(egui::CursorIcon::PointingHand);
        if i == chosen {
            raise(ui, seg, height / 2.0, theme::RUBY);
        } else if response.hovered() {
            ui.painter().rect_filled(seg, CornerRadius::same(255), theme::HOVER);
        }
        let color = if i == chosen { theme::SEASHELL } else { theme::INK_MUTED };
        ui.painter()
            .text(seg.center(), Align2::CENTER_CENTER, *label, font.clone(), color);
        if response.clicked() && i != chosen {
            pressed = Some(i);
        }
        x += w;
    }
    pressed
}

/// Text cut to one line of `width`, ending in "…" when it doesn't fit.
pub fn elided(ui: &Ui, text: &str, font: FontId, color: Color32, width: f32) -> Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::simple_singleline(text.to_string(), font, color);
    job.wrap = egui::text::TextWrapping {
        max_width: width.max(1.0),
        max_rows: 1,
        break_anywhere: true,
        overflow_character: Some('…'),
    };
    ui.painter().layout_job(job)
}

/// Small-capital titles: upper case with a hair space between letters (egui has no tracking).
pub fn spaced(text: &str) -> String {
    let mut out = String::new();
    for (i, c) in text.to_uppercase().chars().enumerate() {
        if i > 0 {
            out.push('\u{200A}');
        }
        out.push(c);
    }
    out
}
