//! Christian Figueiredo's design system in egui: the family look the Mac apps have
//! (Aspect/Views/DesignSystem.swift), drawn by hand since egui has none of it built in.
//!
//! Dark only, as the window frame must be the app's own dark grey (#131314) and never the system
//! accent. Six colours exist; everything else is one of them at an opacity. The ground and the
//! panels are one colour: depth comes from light and shadow. Red is one signal per view. Brakwell
//! for titles and numbers (24 pt and up), Tessel for the rest; both ship as static weights cut from
//! the variable fonts (assets/fonts), since egui cannot pick a weight from a variable font.
//!
//! This file has no Aspect in it, so the other apps of the family can take it as it is.

use egui::epaint::{CornerRadius, Shadow, Stroke};
use egui::{Color32, FontData, FontDefinitions, FontFamily, FontId, Pos2, Rect, Response, Sense, Ui, Vec2, pos2, vec2};
use std::sync::Arc;

// MARK: colour

pub const EBONY: Color32 = Color32::from_rgb(0x04, 0x04, 0x04);
pub const SHARK: Color32 = Color32::from_rgb(0x13, 0x13, 0x14);
pub const SEASHELL: Color32 = Color32::from_rgb(0xF1, 0xF1, 0xF1);
pub const RUBY: Color32 = Color32::from_rgb(0xA0, 0x0A, 0x00);
pub const MILANO: Color32 = Color32::from_rgb(0xD4, 0x11, 0x01);

const fn alpha(c: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied_const(c.r(), c.g(), c.b(), (a * 255.0) as u8)
}

/// The window's ground and its panels, one colour.
pub const GROUND: Color32 = SHARK;
/// Sunken wells, fields and pressed keys.
pub const SUNKEN: Color32 = alpha(EBONY, 0.42);
/// Decoration only: rules.
pub const LINE: Color32 = alpha(SEASHELL, 0.12);
/// Printed outlines.
pub const LINE_PRINT: Color32 = alpha(SEASHELL, 0.30);
pub const INK: Color32 = SEASHELL;
/// Labels printed on the body.
pub const INK_PRINT: Color32 = alpha(SEASHELL, 0.78);
pub const INK_MUTED: Color32 = alpha(SEASHELL, 0.62);
/// The one red: Milano on the dark ground. What sits on it is always light.
pub const ACCENT: Color32 = MILANO;
/// A selected row: Ruby Red as a tint, the text staying ink.
pub const SELECTION_RED: Color32 = alpha(RUBY, 0.45);
/// A row that needs attention: the same red, much quieter.
pub const ALERT: Color32 = alpha(RUBY, 0.16);
/// Hover: ink, faint.
pub const HOVER: Color32 = alpha(SEASHELL, 0.08);
/// The light from the top left that raises keys and panels.
const LIGHT: Color32 = alpha(Color32::WHITE, 0.06);
const SHADE: Color32 = alpha(Color32::BLACK, 0.55);
const RIM: Color32 = alpha(Color32::WHITE, 0.20);

// MARK: spacing

pub const S1: f32 = 4.0;
pub const S2: f32 = 8.0;
pub const S3: f32 = 12.0;
pub const S4: f32 = 16.0;
pub const S6: f32 = 24.0;
pub const S8: f32 = 32.0;
pub const S12: f32 = 48.0;
pub const RADIUS_SM: f32 = 12.0;
pub const RADIUS_LG: f32 = 24.0;

// MARK: type

const FONTS: [(&str, &[u8]); 5] = [
    ("tessel-400", include_bytes!("../assets/fonts/Tessel-400.ttf")),
    ("tessel-500", include_bytes!("../assets/fonts/Tessel-500.ttf")),
    ("tessel-600", include_bytes!("../assets/fonts/Tessel-600.ttf")),
    ("brakwell-600", include_bytes!("../assets/fonts/Brakwell-600.ttf")),
    ("brakwell-700", include_bytes!("../assets/fonts/Brakwell-700.ttf")),
];

/// Tessel at 400, 500 or 600; Brakwell at 600 or 700.
pub fn text(size: f32, weight: u16) -> FontId {
    let name = match weight {
        0..=449 => "tessel-400",
        450..=549 => "tessel-500",
        _ => "tessel-600",
    };
    FontId::new(size, FontFamily::Name(name.into()))
}

pub fn display(size: f32, weight: u16) -> FontId {
    let name = if weight >= 650 { "brakwell-700" } else { "brakwell-600" };
    FontId::new(size, FontFamily::Name(name.into()))
}

/// `title-2`: the page's one big number.
pub fn title2() -> FontId {
    display(32.0, 700)
}
/// `title-3`: the second-level numbers.
pub fn title3() -> FontId {
    display(24.0, 600)
}
/// `body-sm`: most of the window.
pub fn body() -> FontId {
    text(14.0, 400)
}
/// `label`: buttons, chips and the names of things.
pub fn label() -> FontId {
    text(14.0, 500)
}
/// A heading inside a panel.
pub fn heading() -> FontId {
    text(15.0, 600)
}
/// `caption`: metadata.
pub fn caption() -> FontId {
    text(12.0, 400)
}
/// `overline`: eyebrows, uppercase with wide tracking (see `overline`).
pub fn overline_font() -> FontId {
    text(12.0, 500)
}

/// Loads the fonts and sets egui's own widgets (scroll bars, text fields, menus) in the family's
/// colours, so nothing on screen falls back to egui's default blue or grey.
pub fn install(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();
    for (name, bytes) in FONTS {
        fonts
            .font_data
            .insert(name.into(), Arc::new(FontData::from_static(bytes)));
        let mut family = vec![name.to_string()];
        // Arrows, ÷ and ≈ that the family's fonts may lack come from egui's own.
        family.extend(fonts.families[&FontFamily::Proportional].iter().cloned());
        fonts.families.insert(FontFamily::Name(name.into()), family);
    }
    fonts
        .families
        .get_mut(&FontFamily::Proportional)
        .unwrap()
        .insert(0, "tessel-400".into());
    ctx.set_fonts(fonts);

    ctx.set_theme(egui::Theme::Dark);
    let mut style = (*ctx.global_style()).clone();
    style.text_styles.insert(egui::TextStyle::Body, body());
    style.text_styles.insert(egui::TextStyle::Button, label());
    style.text_styles.insert(egui::TextStyle::Small, caption());
    style.text_styles.insert(egui::TextStyle::Monospace, text(14.0, 500));
    style.spacing.item_spacing = vec2(S2, S2);
    style.spacing.button_padding = vec2(S3, S1);
    style.spacing.interact_size.y = 28.0;
    style.spacing.combo_height = 420.0;
    let v = &mut style.visuals;
    v.dark_mode = true;
    v.override_text_color = Some(INK);
    v.panel_fill = GROUND;
    v.window_fill = GROUND;
    v.extreme_bg_color = SUNKEN;
    v.faint_bg_color = HOVER;
    v.hyperlink_color = INK;
    v.selection.bg_fill = SELECTION_RED;
    v.selection.stroke = Stroke::new(1.0, INK);
    v.text_cursor.stroke = Stroke::new(1.5, INK);
    v.window_stroke = Stroke::new(1.0, LINE);
    v.window_shadow = Shadow {
        offset: [3, 4],
        blur: 16,
        spread: 0,
        color: SHADE,
    };
    v.popup_shadow = Shadow {
        offset: [2, 4],
        blur: 12,
        spread: 0,
        color: SHADE,
    };
    v.window_corner_radius = CornerRadius::same(RADIUS_SM as u8);
    v.menu_corner_radius = CornerRadius::same(RADIUS_SM as u8);
    for w in [
        &mut v.widgets.noninteractive,
        &mut v.widgets.inactive,
        &mut v.widgets.hovered,
        &mut v.widgets.active,
        &mut v.widgets.open,
    ] {
        w.corner_radius = CornerRadius::same(8);
        w.fg_stroke = Stroke::new(1.0, INK);
        w.bg_stroke = Stroke::new(1.0, LINE);
        w.bg_fill = GROUND;
        w.weak_bg_fill = GROUND;
        w.expansion = 0.0;
    }
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, LINE);
    v.widgets.noninteractive.fg_stroke = Stroke::new(1.0, INK_PRINT);
    v.widgets.hovered.weak_bg_fill = HOVER;
    v.widgets.hovered.bg_fill = HOVER;
    v.widgets.hovered.bg_stroke = Stroke::new(1.0, LINE_PRINT);
    v.widgets.active.weak_bg_fill = SUNKEN;
    v.widgets.active.bg_fill = SUNKEN;
    v.widgets.open.weak_bg_fill = SUNKEN;
    ctx.set_global_style(style);
}

// MARK: material

/// Raised like a key on a flat surface: a soft light from the top left, a shadow below, a rim
/// light on the top edge.
pub fn raised(ui: &Ui, rect: Rect, radius: f32, strength: f32) {
    let p = ui.painter();
    let r = CornerRadius::same(radius.min(255.0) as u8);
    let s = |o: f32| (o * strength).round() as i8;
    p.add(
        Shadow {
            offset: [s(-2.0), s(-2.0)],
            blur: (6.0 * strength) as u8,
            spread: 0,
            color: LIGHT,
        }
        .as_shape(rect, r),
    );
    p.add(
        Shadow {
            offset: [s(3.0), s(4.0)],
            blur: (8.0 * strength) as u8,
            spread: 0,
            color: SHADE,
        }
        .as_shape(rect, r),
    );
    p.rect_filled(rect, r, GROUND);
    rim(ui, rect, radius);
}

/// Rim light: strongest on the top edge.
pub fn rim(ui: &Ui, rect: Rect, radius: f32) {
    let r = CornerRadius::same(radius.min(255.0) as u8);
    ui.painter().rect_stroke(
        rect,
        r,
        Stroke::new(1.0, alpha(Color32::WHITE, 0.03)),
        egui::StrokeKind::Inside,
    );
    let top = Rect::from_min_max(
        rect.min + vec2(radius * 0.6, 0.0),
        pos2(rect.max.x - radius * 0.6, rect.min.y + 1.0),
    );
    ui.painter().rect_filled(top, 0.0, RIM);
}

/// Pressed into the body: sunken fill and a soft inner shadow on the top edge.
pub fn sunken(ui: &Ui, rect: Rect, radius: f32) {
    let r = CornerRadius::same(radius.min(255.0) as u8);
    ui.painter().rect_filled(rect, r, SUNKEN);
    let top = Rect::from_min_max(
        rect.min + vec2(radius * 0.5, 0.5),
        pos2(rect.max.x - radius * 0.5, rect.min.y + 1.5),
    );
    ui.painter().rect_filled(top, 0.0, alpha(Color32::BLACK, 0.35));
}

/// A panel: the ground's own colour, lifted by light and a soft shadow, radius 24.
pub fn panel<R>(ui: &mut Ui, padding: f32, add: impl FnOnce(&mut Ui) -> R) -> R {
    let width = ui.available_width();
    let where_ = ui.painter().add(egui::Shape::Noop);
    let inner = ui.allocate_ui_with_layout(vec2(width, 0.0), egui::Layout::top_down(egui::Align::Min), |ui| {
        egui::Frame::NONE.inner_margin(padding).show(ui, |ui| {
            ui.set_width(width - 2.0 * padding);
            add(ui)
        })
    });
    let rect = inner.response.rect;
    // Drawn behind the content after it is laid out, since its height is known only then.
    let mut shapes = Vec::new();
    let r = CornerRadius::same(RADIUS_LG as u8);
    shapes.push(egui::Shape::from(
        Shadow {
            offset: [2, 3],
            blur: 6,
            spread: 0,
            color: SHADE,
        }
        .as_shape(rect, r),
    ));
    shapes.push(egui::Shape::rect_filled(rect, r, GROUND));
    shapes.push(egui::Shape::rect_stroke(
        rect,
        r,
        Stroke::new(1.0, alpha(Color32::WHITE, 0.05)),
        egui::StrokeKind::Inside,
    ));
    ui.painter().set(where_, egui::Shape::Vec(shapes));
    inner.inner.inner
}

// MARK: text

/// Text in a given font and colour, laid out without wrapping.
pub fn paint_text(ui: &Ui, pos: Pos2, anchor: egui::Align2, text: &str, font: FontId, color: Color32) -> Rect {
    ui.painter().text(pos, anchor, text, font, color)
}

pub fn label_in(ui: &mut Ui, text: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(egui::Label::new(egui::RichText::new(text.into()).font(font).color(color)).selectable(false))
}

/// Wrapping text, for notes and verdicts.
pub fn wrapped(ui: &mut Ui, text: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(
        egui::Label::new(egui::RichText::new(text.into()).font(font).color(color))
            .wrap()
            .selectable(false),
    )
}

/// A printed label: uppercase, tracked wide (0.16 em).
pub fn overline(ui: &mut Ui, text: &str, color: Color32) -> Response {
    let mut job = egui::text::LayoutJob::default();
    job.append(
        &text.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: overline_font(),
            color,
            extra_letter_spacing: 1.9,
            ..Default::default()
        },
    );
    ui.add(egui::Label::new(job).selectable(false))
}

/// Column titles in tables: uppercase, 11 pt semibold, tracked.
pub fn column_title(ui: &mut Ui, text: &str) -> Response {
    let mut job = egui::text::LayoutJob::default();
    job.append(
        &text.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: text_font(11.0, 600),
            color: INK_MUTED,
            extra_letter_spacing: 1.2,
            ..Default::default()
        },
    );
    // Never cut short: a title wider than its column runs on, as the Mac table's do.
    ui.add(egui::Label::new(job).selectable(false).extend())
}

fn text_font(size: f32, weight: u16) -> FontId {
    text(size, weight)
}

/// A cell exactly `width` wide (and at least `height` tall): table columns and form columns stay
/// aligned whatever their content.
pub fn cell<R>(ui: &mut Ui, width: f32, height: f32, layout: egui::Layout, add: impl FnOnce(&mut Ui) -> R) -> R {
    // Allocated like any widget, so a horizontal row centres it vertically with its neighbours.
    let (rect, _) = ui.allocate_exact_size(vec2(width, height), Sense::hover());
    // A child that doesn't move the parent's cursor again: the allocation above already did.
    let mut child = ui.new_child(egui::UiBuilder::new().max_rect(rect).layout(layout));
    add(&mut child)
}

// MARK: controls

pub fn text_width(ui: &Ui, text: &str, font: &FontId) -> f32 {
    ui.fonts_mut(|f| f.layout_no_wrap(text.to_string(), font.clone(), INK).size().x)
}

/// The chip's lamp: red when lit, a dim dot when not.
pub fn led(ui: &Ui, center: Pos2, lit: bool, size: f32) {
    let p = ui.painter();
    if lit {
        p.circle_filled(center, size * 1.1, alpha(ACCENT, 0.25));
        p.circle_filled(center, size / 2.0, ACCENT);
    } else {
        p.circle_filled(center, size / 2.0, alpha(INK, 0.16));
    }
}

/// A chip: a small key for one-of-many choices; the chosen one sinks in and lights its LED.
/// `content` is a text, or `None` with an icon painted by `icon`.
pub fn chip(ui: &mut Ui, title: &str, chosen: bool, enabled: bool) -> Response {
    chip_with(ui, title, chosen, enabled, None)
}

pub fn chip_icon(ui: &mut Ui, chosen: bool, enabled: bool, icon: fn(&Ui, Rect, Color32)) -> Response {
    chip_with(ui, "", chosen, enabled, Some(icon))
}

fn chip_with(ui: &mut Ui, title: &str, chosen: bool, enabled: bool, icon: Option<fn(&Ui, Rect, Color32)>) -> Response {
    let font = label();
    let content = if icon.is_some() {
        14.0
    } else {
        text_width(ui, title, &font)
    };
    let size = vec2(S3 + 6.0 + S2 + content + S3, 28.0);
    let sense = if enabled { Sense::click() } else { Sense::hover() };
    let (rect, response) = ui.allocate_exact_size(size, sense);
    if ui.is_rect_visible(rect) {
        let fade = if enabled { 1.0 } else { 0.4 };
        if chosen {
            sunken(ui, rect, 14.0);
        } else {
            raised(ui, rect, 14.0, 0.45);
        }
        led(ui, pos2(rect.min.x + S3 + 3.0, rect.center().y), chosen, 6.0);
        let color = (if chosen { INK } else { INK_MUTED }).gamma_multiply(fade);
        let left = rect.min.x + S3 + 6.0 + S2;
        match icon {
            Some(draw) => draw(
                ui,
                Rect::from_min_size(pos2(left, rect.center().y - 7.0), vec2(14.0, 14.0)),
                color,
            ),
            None => {
                paint_text(
                    ui,
                    pos2(left, rect.center().y),
                    egui::Align2::LEFT_CENTER,
                    title,
                    font,
                    color,
                );
            }
        }
    }
    if enabled {
        response.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        response
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Key {
    /// The one red key per view: a soft, almost flat red, what's on it light.
    Primary,
    /// The design system's `key`: strong but not red, the body's own material, raised.
    Raised,
    /// A printed outline.
    Ghost,
}

/// The system's keys, 30 tall (24 for `small` ghost keys in table rows).
pub fn button(ui: &mut Ui, kind: Key, title: &str, small: bool) -> Response {
    button_with(ui, kind, title, small, false)
}

/// A key with a trailing arrow ("Check →", "Open Deliver Check →").
pub fn button_arrow(ui: &mut Ui, kind: Key, title: &str, small: bool) -> Response {
    button_with(ui, kind, title, small, true)
}

fn button_with(ui: &mut Ui, kind: Key, title: &str, small: bool, arrow: bool) -> Response {
    let font = label();
    let height = if small { 24.0 } else { 30.0 };
    let pad = if small { S3 } else { S4 };
    let arrow_w = if arrow { S1 + 10.0 } else { 0.0 };
    let size = vec2(pad * 2.0 + text_width(ui, title, &font) + arrow_w, height);
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    if ui.is_rect_visible(rect) {
        let pressed = response.is_pointer_button_down_on();
        let r = height / 2.0;
        let color = match kind {
            Key::Primary => {
                let p = ui.painter();
                let cr = CornerRadius::same(r as u8);
                p.add(
                    Shadow {
                        offset: [3, 4],
                        blur: 8,
                        spread: 0,
                        color: alpha(Color32::BLACK, 0.3),
                    }
                    .as_shape(rect, cr),
                );
                p.rect_filled(rect, cr, if pressed { ACCENT.gamma_multiply(0.7) } else { ACCENT });
                p.rect_filled(
                    Rect::from_min_max(
                        rect.min + vec2(r * 0.6, 0.0),
                        pos2(rect.max.x - r * 0.6, rect.min.y + 1.0),
                    ),
                    0.0,
                    alpha(Color32::WHITE, 0.22),
                );
                SEASHELL
            }
            Key::Raised => {
                if pressed {
                    sunken(ui, rect, r)
                } else {
                    raised(ui, rect, r, 0.6)
                }
                INK
            }
            Key::Ghost => {
                let cr = CornerRadius::same(r as u8);
                if response.hovered() {
                    ui.painter().rect_filled(rect, cr, HOVER);
                }
                ui.painter()
                    .rect_stroke(rect, cr, Stroke::new(1.0, LINE_PRINT), egui::StrokeKind::Inside);
                if pressed {
                    INK_PRINT.gamma_multiply(0.7)
                } else {
                    INK_PRINT
                }
            }
        };
        let text_rect = paint_text(
            ui,
            pos2(rect.min.x + pad, rect.center().y),
            egui::Align2::LEFT_CENTER,
            title,
            font,
            color,
        );
        if arrow {
            arrow_right(ui, pos2(text_rect.max.x + S1 + 5.0, rect.center().y), 10.0, color);
        }
    }
    response.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Switch: the knob fits inside the track; lit means on.
pub fn switch(ui: &mut Ui, on: bool) -> Response {
    let (rect, response) = ui.allocate_exact_size(vec2(40.0, 24.0), Sense::click());
    let t = ui.ctx().animate_bool_with_time(response.id, on, 0.25);
    let p = ui.painter();
    let track = CornerRadius::same(12);
    p.rect_filled(rect, track, lerp_color(SUNKEN, alpha(INK, 0.9), t));
    if t < 1.0 {
        p.rect_stroke(
            rect,
            track,
            Stroke::new(1.0, LINE_PRINT.gamma_multiply(1.0 - t)),
            egui::StrokeKind::Inside,
        );
    }
    let x = egui::lerp(rect.min.x + 12.0..=rect.max.x - 12.0, t);
    let knob = pos2(x, rect.center().y);
    p.circle_filled(knob + vec2(1.0, 2.0), 9.0, alpha(Color32::BLACK, 0.4));
    p.circle_filled(knob, 9.0, lerp_color(alpha(INK, 0.85), GROUND, t));
    response.on_hover_cursor(egui::CursorIcon::PointingHand)
}

fn lerp_color(a: Color32, b: Color32, t: f32) -> Color32 {
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgba_premultiplied(l(a.r(), b.r()), l(a.g(), b.g()), l(a.b(), b.b()), l(a.a(), b.a()))
}

#[derive(Clone, Copy, PartialEq)]
pub enum TagKind {
    /// Solid ink with the ground's colour on it.
    Ink,
    /// Sunken, muted type.
    Quiet,
    /// The red one.
    Accent,
}

impl TagKind {
    pub fn from_name(name: &str) -> TagKind {
        match name {
            "ink" => TagKind::Ink,
            "accent" => TagKind::Accent,
            _ => TagKind::Quiet,
        }
    }
}

/// A small printed tag: a rounded trapezoid, wider at the top (the design system's own outline,
/// traced as TagShape in the Mac app). The slant side gets twice the straight side's room.
pub fn tag(ui: &mut Ui, title: &str, kind: TagKind) -> Response {
    let mut job = egui::text::LayoutJob::default();
    let (fill, color) = match kind {
        TagKind::Ink => (INK, GROUND),
        TagKind::Quiet => (SUNKEN, INK_PRINT),
        TagKind::Accent => (ACCENT, SEASHELL),
    };
    job.append(
        &title.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: text(11.0, 600),
            color,
            extra_letter_spacing: 1.0,
            ..Default::default()
        },
    );
    let galley = ui.fonts_mut(|f| f.layout_job(job));
    let size = vec2(S2 + galley.size().x + S4, 20.0);
    let (rect, response) = ui.allocate_exact_size(size, Sense::hover());
    if ui.is_rect_visible(rect) {
        ui.painter()
            .add(egui::Shape::convex_polygon(tag_outline(rect), fill, Stroke::NONE));
        ui.painter().galley(
            pos2(rect.min.x + S2, rect.center().y - galley.size().y / 2.0),
            galley,
            color,
        );
    }
    response
}

/// The tag outline: rounded on the left, the right side slanting in towards the bottom.
fn tag_outline(r: Rect) -> Vec<Pos2> {
    let s = r.height() / 30.0;
    let left = 8.0 * s;
    let mut points = Vec::new();
    let arc = |points: &mut Vec<Pos2>, c: Pos2, radius: f32, from: f32, to: f32| {
        for i in 0..=6 {
            let a = from + (to - from) * i as f32 / 6.0;
            points.push(c + radius * Vec2::angled(a));
        }
    };
    use std::f32::consts::PI;
    // Top left corner, top edge, the slanted right side, bottom edge, bottom left corner.
    arc(&mut points, pos2(r.min.x + left, r.min.y + left), left, PI, 1.5 * PI);
    let top_right = r.max.x - 7.0 * s;
    arc(
        &mut points,
        pos2(top_right - 2.0 * s, r.min.y + 7.0 * s),
        7.0 * s,
        1.5 * PI,
        1.88 * PI,
    );
    let bottom_right = r.max.x - 12.0 * s;
    arc(
        &mut points,
        pos2(bottom_right - 4.0 * s, r.max.y - 6.0 * s),
        6.0 * s,
        0.38 * PI,
        0.5 * PI,
    );
    arc(&mut points, pos2(r.min.x + left, r.max.y - left), left, 0.5 * PI, PI);
    points
}

/// A sunken text field, 28 tall, in tabular figures.
pub fn field(ui: &mut Ui, value: &mut String, width: f32, hint: &str, invalid: bool) -> Response {
    let (rect, _) = ui.allocate_exact_size(vec2(width, 28.0), Sense::hover());
    sunken(ui, rect, 14.0);
    let edit = egui::TextEdit::singleline(value)
        .font(text(14.0, 500))
        .text_color(INK)
        .hint_text(egui::RichText::new(hint).color(INK_MUTED))
        .frame(egui::Frame::NONE)
        .margin(vec2(S3, 0.0))
        .align(egui::Align2::LEFT_CENTER)
        .desired_width(width);
    let response = ui.put(rect, edit);
    let stroke = if invalid {
        Stroke::new(1.5, ACCENT)
    } else if response.has_focus() {
        Stroke::new(1.0, LINE_PRINT)
    } else {
        Stroke::new(1.0, LINE)
    };
    ui.painter()
        .rect_stroke(rect, CornerRadius::same(14), stroke, egui::StrokeKind::Inside);
    response
}

/// A horizontal rule.
pub fn rule(ui: &mut Ui, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().rect_filled(rect, 0.0, color);
}

// MARK: icons, drawn so no icon font is needed

pub fn arrow_right(ui: &Ui, center: Pos2, size: f32, color: Color32) {
    let s = size / 2.0;
    let stroke = Stroke::new(1.6, color);
    let p = ui.painter();
    p.line_segment([center - vec2(s * 0.85, 0.0), center + vec2(s * 0.85, 0.0)], stroke);
    p.line_segment(
        [center + vec2(s * 0.85, 0.0), center + vec2(s * 0.15, -s * 0.7)],
        stroke,
    );
    p.line_segment([center + vec2(s * 0.85, 0.0), center + vec2(s * 0.15, s * 0.7)], stroke);
}

pub fn chevron(ui: &Ui, center: Pos2, open: f32, color: Color32) {
    // Rotates from pointing right (0) to pointing down (1).
    let angle = open * std::f32::consts::FRAC_PI_2;
    let rot = |v: Vec2| {
        Vec2::new(
            v.x * angle.cos() - v.y * angle.sin(),
            v.x * angle.sin() + v.y * angle.cos(),
        )
    };
    let stroke = Stroke::new(1.8, color);
    let a = center + rot(vec2(-1.5, -3.5));
    let b = center + rot(vec2(2.0, 0.0));
    let c = center + rot(vec2(-1.5, 3.5));
    ui.painter().line(vec![a, b, c], stroke);
}

pub fn copy_icon(ui: &Ui, rect: Rect, color: Color32) {
    let s = rect.width() / 16.0;
    let stroke = Stroke::new(1.3, color);
    let front = Rect::from_min_size(rect.min + vec2(5.0, 5.0) * s, vec2(8.5, 8.5) * s);
    ui.painter()
        .rect_stroke(front, CornerRadius::same(2), stroke, egui::StrokeKind::Middle);
    ui.painter().line(
        vec![
            rect.min + vec2(3.0, 10.5) * s,
            rect.min + vec2(3.0, 4.0) * s,
            rect.min + vec2(4.5, 2.5) * s,
            rect.min + vec2(11.0, 2.5) * s,
        ],
        stroke,
    );
}

pub fn landscape_icon(ui: &Ui, rect: Rect, color: Color32) {
    let r = Rect::from_center_size(rect.center(), vec2(13.0, 8.0));
    ui.painter().rect_stroke(
        r,
        CornerRadius::same(2),
        Stroke::new(1.4, color),
        egui::StrokeKind::Middle,
    );
}

pub fn portrait_icon(ui: &Ui, rect: Rect, color: Color32) {
    let r = Rect::from_center_size(rect.center(), vec2(8.0, 13.0));
    ui.painter().rect_stroke(
        r,
        CornerRadius::same(2),
        Stroke::new(1.4, color),
        egui::StrokeKind::Middle,
    );
}

/// A dashed outline, for the platform's shape behind the current one.
pub fn dashed_rect(ui: &Ui, rect: Rect, color: Color32, dash: f32, gap: f32) {
    let corners = [
        rect.left_top(),
        rect.right_top(),
        rect.right_bottom(),
        rect.left_bottom(),
        rect.left_top(),
    ];
    let stroke = Stroke::new(1.5, color);
    for pair in corners.windows(2) {
        ui.painter()
            .extend(egui::Shape::dashed_line(&[pair[0], pair[1]], stroke, dash, gap));
    }
}
