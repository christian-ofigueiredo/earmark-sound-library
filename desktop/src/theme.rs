//! Christian Figueiredo's design system in egui: the family look the Mac apps have, drawn by hand
//! since egui has none of it built in. One file for every app of the family (Aspect, Earmark,
//! Graticule, Offload): copy it as it is; nothing here belongs to one app.
//!
//! Dark and light, as on the Mac (`DesignSystem.swift`): [`DARK`] and [`LIGHT`] are the two
//! palettes, [`set_theme`] picks one for the whole app and [`pal`] reads it. The window frame takes
//! the palette's ground (#131314 dark, #F1F1F1 light), never the system accent. Six colours exist;
//! everything else is one of them at an opacity. The ground and the
//! panels are one colour: depth comes from light and shadow. Red is one signal per view. Brakwell
//! for titles and numbers (24 pt and up), Inter for the rest (the Mac apps use the system font
//! there): variable fonts, each weight picked through the `wght` axis (`FontTweak::coords`).
//! Inter is under the SIL Open Font License: `assets/fonts/OFL.txt` goes wherever `Inter.ttf` goes.
//!
//! What is shared: colours, type, materials (`raised`, `sunken`, `rim`), the tag outline, icons.
//! What differs between the Mac apps (how tall a chip is, the colour of its lamp, the size of a
//! key, the shadow under it) is a [`Style`]: each app sets its own once with [`set_style`]; without
//! it, [`Style::ASPECT`] applies.

// Each app uses part of this shared file; the rest stays for the others.
#![allow(dead_code)]

use egui::epaint::{CornerRadius, Shadow, Stroke};
use egui::{
    Color32, FontData, FontDefinitions, FontFamily, FontId, Painter, Pos2, Rect, Response, Sense,
    Ui, Vec2, pos2, vec2,
};
use std::sync::Arc;

// MARK: colour

pub const EBONY: Color32 = Color32::from_rgb(0x04, 0x04, 0x04);
pub const SHARK: Color32 = Color32::from_rgb(0x13, 0x13, 0x14);
pub const SEASHELL: Color32 = Color32::from_rgb(0xF1, 0xF1, 0xF1);
pub const RUBY: Color32 = Color32::from_rgb(0xA0, 0x0A, 0x00);
pub const MILANO: Color32 = Color32::from_rgb(0xD4, 0x11, 0x01);

/// A colour at an opacity: the only way the family makes new colours.
pub const fn alpha(c: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied_const(c.r(), c.g(), c.b(), (a * 255.0) as u8)
}

/// The colours that change with the theme. Everything that sits on red stays [`SEASHELL`] in both.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Palette {
    pub dark: bool,
    /// The window's ground and its panels, one colour.
    pub ground: Color32,
    /// Sunken wells, fields and pressed keys.
    pub sunken: Color32,
    /// Decoration only: rules.
    pub line: Color32,
    /// Printed outlines.
    pub line_print: Color32,
    pub ink: Color32,
    /// Labels printed on the body.
    pub ink_print: Color32,
    pub ink_muted: Color32,
    /// Notes and counts: quieter than `ink_muted`.
    pub ink_note: Color32,
    /// The one red: Milano on the dark ground, Ruby on the light. What sits on it is always light.
    pub accent: Color32,
    /// A selected row: Ruby Red as a tint, the text staying ink.
    pub selection_red: Color32,
    /// A row that needs attention: the same red, much quieter.
    pub alert: Color32,
    /// Hover: ink, faint.
    pub hover: Color32,
    /// The light from the top left that raises keys and panels.
    pub light: Color32,
    /// Shadows of windows, menus and panels.
    pub shade: Color32,
    /// The rim light on a raised thing's top edge, and the faint ring all round it.
    pub rim: Color32,
    pub rim_ring: Color32,
    /// The inner shadow on a sunken thing's top edge.
    pub inset: Color32,
    /// A panel's hairline edge.
    pub edge: Color32,
    /// A switch's knob shadow.
    pub knob_shadow: Color32,
}

/// Dark: the family's look until 2026-11-26, unchanged.
pub const DARK: Palette = Palette {
    dark: true,
    ground: SHARK,
    sunken: alpha(EBONY, 0.42),
    line: alpha(SEASHELL, 0.12),
    line_print: alpha(SEASHELL, 0.30),
    ink: SEASHELL,
    ink_print: alpha(SEASHELL, 0.78),
    ink_muted: alpha(SEASHELL, 0.62),
    ink_note: alpha(SEASHELL, 0.46),
    accent: MILANO,
    selection_red: alpha(RUBY, 0.45),
    alert: alpha(RUBY, 0.16),
    hover: alpha(SEASHELL, 0.08),
    light: alpha(Color32::WHITE, 0.06),
    shade: alpha(Color32::BLACK, 0.55),
    rim: alpha(Color32::WHITE, 0.20),
    rim_ring: alpha(Color32::WHITE, 0.03),
    inset: alpha(Color32::BLACK, 0.35),
    edge: alpha(Color32::WHITE, 0.05),
    knob_shadow: alpha(Color32::BLACK, 0.4),
};

/// Light: the Mac apps' light tokens (Seashell ground, Ebony ink, Ruby accent); the key light from
/// the top left is near white and the shadows a quarter as strong, as `KeyShadow` there.
pub const LIGHT: Palette = Palette {
    dark: false,
    ground: SEASHELL,
    sunken: alpha(EBONY, 0.06),
    line: alpha(EBONY, 0.14),
    line_print: alpha(EBONY, 0.32),
    ink: EBONY,
    ink_print: alpha(EBONY, 0.78),
    ink_muted: alpha(EBONY, 0.62),
    ink_note: alpha(EBONY, 0.56),
    accent: RUBY,
    selection_red: alpha(RUBY, 0.16),
    alert: alpha(RUBY, 0.08),
    hover: alpha(EBONY, 0.06),
    light: alpha(Color32::WHITE, 0.90),
    shade: alpha(Color32::BLACK, 0.14),
    rim: alpha(Color32::WHITE, 0.90),
    rim_ring: alpha(EBONY, 0.04),
    inset: alpha(Color32::BLACK, 0.05),
    edge: alpha(EBONY, 0.05),
    knob_shadow: alpha(Color32::BLACK, 0.18),
};

static IS_LIGHT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The palette in use (one for the whole app).
pub fn pal() -> &'static Palette {
    if IS_LIGHT.load(std::sync::atomic::Ordering::Relaxed) {
        &LIGHT
    } else {
        &DARK
    }
}

// MARK: spacing

pub const S1: f32 = 4.0;
pub const S2: f32 = 8.0;
pub const S3: f32 = 12.0;
pub const S4: f32 = 16.0;
pub const S6: f32 = 24.0;
pub const S8: f32 = 32.0;
pub const S12: f32 = 48.0;
pub const RADIUS_SM: f32 = 12.0;
pub const RADIUS_MD: f32 = 20.0;
pub const RADIUS_LG: f32 = 24.0;

// MARK: each app's measures

/// A key's height, side padding and type.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct KeySize {
    pub height: f32,
    pub pad: f32,
    pub font_size: f32,
    pub font_weight: u16,
}

/// A shadow cast by a raised key, at strength 1.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct KeyShadow {
    pub light_offset: f32,
    pub light_blur: f32,
    pub dark_offset: [f32; 2],
    pub dark_blur: f32,
    /// The shadow's black opacity: [on the dark ground, on the light].
    pub dark: [f32; 2],
}

/// The colour of a chip's lamp when lit.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Lamp {
    Accent,
    Ink,
}

impl Lamp {
    /// The lamp and its glow in the current palette.
    pub fn colors(self) -> (Color32, Color32) {
        match self {
            Lamp::Accent => (pal().accent, alpha(pal().accent, 0.25)),
            Lamp::Ink => (pal().ink, alpha(pal().ink, 0.12)),
        }
    }
}

/// What differs between the Mac apps of the family: sizes, the chip's lamp, the key's shadow.
/// Everything else (colours, type, materials, outlines) is shared.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Style {
    pub chip_height: f32,
    pub chip_pad: f32,
    /// The chip's lamp when lit: red in Aspect, ink in Offload.
    pub led: Lamp,
    /// How strongly a chip that is not chosen stands up.
    pub chip_raise: f32,
    pub primary: KeySize,
    pub raised: KeySize,
    pub ghost: KeySize,
    /// `small` keys, for table rows.
    pub small: KeySize,
    /// How strongly a raised key stands up.
    pub key_raise: f32,
    pub primary_shadow: KeyShadow,
    pub shadow: KeyShadow,
    pub switch: Vec2,
    pub knob: f32,
    pub field_height: f32,
    pub field_font: (f32, u16),
    pub field_margin: f32,
    pub tag_height: f32,
    pub tag_font: (f32, u16),
    pub tag_tracking: f32,
    pub overline_weight: u16,
    pub overline_tracking: f32,
}

const ASPECT_SHADOW: KeyShadow = KeyShadow {
    light_offset: -2.0,
    light_blur: 6.0,
    dark_offset: [3.0, 4.0],
    dark_blur: 8.0,
    dark: [0.55, 0.14],
};

impl Style {
    /// Aspect's measures (Aspect/Views/DesignSystem.swift); Earmark uses the same.
    pub const ASPECT: Style = Style {
        chip_height: 28.0,
        chip_pad: S3,
        led: Lamp::Accent,
        chip_raise: 0.45,
        primary: KeySize {
            height: 30.0,
            pad: S4,
            font_size: 14.0,
            font_weight: 500,
        },
        raised: KeySize {
            height: 30.0,
            pad: S4,
            font_size: 14.0,
            font_weight: 500,
        },
        ghost: KeySize {
            height: 30.0,
            pad: S4,
            font_size: 14.0,
            font_weight: 500,
        },
        small: KeySize {
            height: 24.0,
            pad: S3,
            font_size: 14.0,
            font_weight: 500,
        },
        key_raise: 0.6,
        primary_shadow: KeyShadow {
            light_offset: 0.0,
            light_blur: 0.0,
            dark_offset: [3.0, 4.0],
            dark_blur: 8.0,
            dark: [0.3, 0.3],
        },
        shadow: ASPECT_SHADOW,
        switch: Vec2::new(40.0, 24.0),
        knob: 9.0,
        field_height: 28.0,
        field_font: (14.0, 500),
        field_margin: S3,
        tag_height: 20.0,
        tag_font: (11.0, 600),
        tag_tracking: 1.0,
        overline_weight: 500,
        overline_tracking: 1.9,
    };

    /// Earmark: Aspect's measures.
    pub const EARMARK: Style = Style::ASPECT;

    /// Offload's measures (Sources/Offload/Theme.swift): larger keys and chips, a white lamp.
    pub const OFFLOAD: Style = Style {
        chip_height: 36.0,
        chip_pad: S4,
        led: Lamp::Ink,
        chip_raise: 0.6,
        primary: KeySize {
            height: 48.0,
            pad: 28.0,
            font_size: 15.0,
            font_weight: 500,
        },
        raised: KeySize {
            height: 40.0,
            pad: 20.0,
            font_size: 14.0,
            font_weight: 500,
        },
        ghost: KeySize {
            height: 32.0,
            pad: S4,
            font_size: 14.0,
            font_weight: 500,
        },
        small: KeySize {
            height: 32.0,
            pad: S4,
            font_size: 14.0,
            font_weight: 500,
        },
        key_raise: 0.7,
        primary_shadow: KeyShadow {
            light_offset: 0.0,
            light_blur: 0.0,
            dark_offset: [4.0, 6.0],
            dark_blur: 10.0,
            dark: [0.3, 0.3],
        },
        shadow: KeyShadow {
            light_offset: -3.0,
            light_blur: 8.0,
            dark_offset: [4.0, 5.0],
            dark_blur: 12.0,
            dark: [0.6, 0.15],
        },
        switch: Vec2::new(44.0, 26.0),
        knob: 10.0,
        field_height: 48.0,
        field_font: (16.0, 400),
        field_margin: S6,
        tag_height: 19.0,
        tag_font: (9.0, 600),
        tag_tracking: 1.1,
        overline_weight: 600,
        overline_tracking: 1.44,
    };
}

fn style_id() -> egui::Id {
    egui::Id::unique("family-theme-style")
}

/// Sets the app's measures; call once, after [`install`].
pub fn set_style(ctx: &egui::Context, style: Style) {
    ctx.data_mut(|d| d.insert_temp(style_id(), style));
}

/// The app's measures ([`Style::ASPECT`] until [`set_style`] is called).
pub fn style(ui: &Ui) -> Style {
    ui.ctx()
        .data(|d| d.get_temp::<Style>(style_id()))
        .unwrap_or(Style::ASPECT)
}

// MARK: type

/// Inter 4.0, trimmed to weights 300 to 700 at optical size 14, with tabular digits as the default
/// (egui applies no OpenType features, so numbers in columns line up only this way).
const INTER: &[u8] = include_bytes!("../assets/fonts/Inter.ttf");
const BRAKWELL: &[u8] = include_bytes!("../assets/fonts/Brakwell.ttf");

/// The weights in use, each one the variable font at that `wght`, with its optical drop.
const FONTS: [(&str, &[u8], f32, f32); 7] = [
    ("inter-300", INTER, 300.0, TEXT_DROP),
    ("inter-400", INTER, 400.0, TEXT_DROP),
    ("inter-500", INTER, 500.0, TEXT_DROP),
    ("inter-600", INTER, 600.0, TEXT_DROP),
    ("inter-700", INTER, 700.0, TEXT_DROP),
    ("brakwell-600", BRAKWELL, 600.0, OPTICAL_DROP),
    ("brakwell-700", BRAKWELL, 700.0, OPTICAL_DROP),
];

/// Inter at 300 to 700.
pub fn text(size: f32, weight: u16) -> FontId {
    let name = match weight {
        0..=349 => "inter-300",
        350..=449 => "inter-400",
        450..=549 => "inter-500",
        550..=649 => "inter-600",
        _ => "inter-700",
    };
    FontId::new(size, FontFamily::Name(name.into()))
}

/// Brakwell at 600 or 700.
pub fn display(size: f32, weight: u16) -> FontId {
    let name = if weight >= 650 {
        "brakwell-700"
    } else {
        "brakwell-600"
    };
    FontId::new(size, FontFamily::Name(name.into()))
}

/// How far Brakwell sits lower than egui's line box would put it, as a fraction of the size: it
/// has an ascent of 0.80 and a descent of 0.20 with capitals 0.70 tall, so centred in a line box
/// the capitals' middle sits about 0.05 of the size high. The Mac apps lower it by 0.06; here the
/// font itself carries it (`FontTweak::y_offset_factor`), so every title is centred alike.
pub const OPTICAL_DROP: f32 = 0.06;

/// The same for Inter, the text font: its line box (ascent 0.97, descent 0.24, capitals 0.73)
/// puts the capitals' middle at the box's middle, but its ascenders rise above the capitals, so a
/// label's ink sat half a pixel high at 2x. 0.02 centres it (measured at 2x, light and dark) in
/// the theme's keys, chips, segments and fields, and in egui's own menus, rows and tooltips.
pub const TEXT_DROP: f32 = 0.02;

/// Kept so older callers compile: the fonts now carry the drop ([`OPTICAL_DROP`]), so this is 0.
/// Remove calls to it; adding it again would lower a label twice.
pub fn optical_drop(_size: f32) -> f32 {
    0.0
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
/// Helper text under an option: lighter than a caption, so the option's name leads.
pub fn note() -> FontId {
    text(12.0, 300)
}
/// `overline`: eyebrows, uppercase with wide tracking (see `overline`).
pub fn overline_font() -> FontId {
    text(12.0, 500)
}

/// Loads the fonts and sets egui's own widgets (scroll bars, text fields, menus) in the family's
/// colours, so nothing on screen falls back to egui's default blue or grey.
pub fn install(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();
    for (name, bytes, weight, drop) in FONTS {
        let tweak = egui::FontTweak {
            coords: egui::epaint::text::VariationCoords::new([(b"wght", weight)]),
            y_offset_factor: drop,
            ..Default::default()
        };
        fonts.font_data.insert(
            name.into(),
            Arc::new(FontData::from_static(bytes).tweak(tweak)),
        );
        let mut family = vec![name.to_string()];
        // Arrows, ÷ and ≈ that the family's fonts may lack come from egui's own.
        family.extend(fonts.families[&FontFamily::Proportional].iter().cloned());
        fonts.families.insert(FontFamily::Name(name.into()), family);
    }
    fonts
        .families
        .get_mut(&FontFamily::Proportional)
        .unwrap()
        .insert(0, "inter-400".into());
    ctx.set_fonts(fonts);
    apply(ctx);
}

/// Dark or light for the whole app: the palette, egui's own widgets, and the system's idea of the
/// window (Linux title bars follow it). The Windows frame is painted by the app (`frame::paint`).
pub fn set_theme(ctx: &egui::Context, dark: bool) {
    IS_LIGHT.store(!dark, std::sync::atomic::Ordering::Relaxed);
    apply(ctx);
    ctx.send_viewport_cmd(egui::ViewportCommand::SetTheme(if dark {
        egui::SystemTheme::Dark
    } else {
        egui::SystemTheme::Light
    }));
    ctx.request_repaint();
}

/// egui's own widgets in the current palette.
fn apply(ctx: &egui::Context) {
    let dark = pal().dark;
    ctx.set_theme(if dark {
        egui::Theme::Dark
    } else {
        egui::Theme::Light
    });
    let mut style = (*ctx.global_style()).clone();
    style.text_styles.insert(egui::TextStyle::Body, body());
    style.text_styles.insert(egui::TextStyle::Button, label());
    style.text_styles.insert(egui::TextStyle::Small, caption());
    style
        .text_styles
        .insert(egui::TextStyle::Monospace, text(14.0, 500));
    style.spacing.item_spacing = vec2(S2, S2);
    style.spacing.button_padding = vec2(S3, S1);
    style.spacing.interact_size.y = 28.0;
    style.spacing.combo_height = 420.0;
    // egui sizes a popup's first frame within default_area_size (400 high by default), so a
    // long menu scrolled at about nine items even when its max_height allowed more.
    style.spacing.default_area_size.y = 900.0;
    let v = &mut style.visuals;
    v.dark_mode = dark;
    v.override_text_color = Some(pal().ink);
    v.panel_fill = pal().ground;
    v.window_fill = pal().ground;
    v.extreme_bg_color = pal().sunken;
    v.faint_bg_color = pal().hover;
    v.hyperlink_color = pal().ink;
    v.selection.bg_fill = pal().selection_red;
    v.selection.stroke = Stroke::new(1.0, pal().ink);
    v.text_cursor.stroke = Stroke::new(1.5, pal().ink);
    v.window_stroke = Stroke::new(1.0, pal().line);
    v.window_shadow = Shadow {
        offset: [3, 4],
        blur: 16,
        spread: 0,
        color: pal().shade,
    };
    v.popup_shadow = Shadow {
        offset: [2, 4],
        blur: 12,
        spread: 0,
        color: pal().shade,
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
        w.fg_stroke = Stroke::new(1.0, pal().ink);
        w.bg_stroke = Stroke::new(1.0, pal().line);
        w.bg_fill = pal().ground;
        w.weak_bg_fill = pal().ground;
        w.expansion = 0.0;
    }
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, pal().line);
    v.widgets.noninteractive.fg_stroke = Stroke::new(1.0, pal().ink_print);
    v.widgets.hovered.weak_bg_fill = pal().hover;
    v.widgets.hovered.bg_fill = pal().hover;
    v.widgets.hovered.bg_stroke = Stroke::new(1.0, pal().line_print);
    v.widgets.active.weak_bg_fill = pal().sunken;
    v.widgets.active.bg_fill = pal().sunken;
    v.widgets.open.weak_bg_fill = pal().sunken;
    ctx.set_global_style(style);
}

// MARK: material

fn shadow_shapes(rect: Rect, r: CornerRadius, s: &KeyShadow, strength: f32) -> [egui::Shape; 2] {
    let o = |v: f32| (v * strength).round() as i8;
    [
        Shadow {
            offset: [o(s.light_offset), o(s.light_offset)],
            blur: (s.light_blur * strength) as u8,
            spread: 0,
            color: if s.light_blur > 0.0 {
                pal().light
            } else {
                Color32::TRANSPARENT
            },
        }
        .as_shape(rect, r)
        .into(),
        Shadow {
            offset: [o(s.dark_offset[0]), o(s.dark_offset[1])],
            blur: (s.dark_blur * strength) as u8,
            spread: 0,
            color: alpha(Color32::BLACK, s.dark[usize::from(!pal().dark)]),
        }
        .as_shape(rect, r)
        .into(),
    ]
}

/// Raised like a key on a flat surface: a soft light from the top left, a shadow below, a rim
/// light on the top edge. The shadow is the app's (`Style::shadow`).
pub fn raised(ui: &Ui, rect: Rect, radius: f32, strength: f32) {
    raise(ui, rect, radius, strength, pal().ground);
}

/// Raised in a given fill (red for what's chosen in a segmented switch).
pub fn raise(ui: &Ui, rect: Rect, radius: f32, strength: f32, fill: Color32) {
    let p = ui.painter();
    let r = CornerRadius::same(radius.min(255.0) as u8);
    for shape in shadow_shapes(rect, r, &style(ui).shadow, strength) {
        p.add(shape);
    }
    p.rect_filled(rect, r, fill);
    rim(ui, rect, radius);
}

/// Rim light: strongest on the top edge.
pub fn rim(ui: &Ui, rect: Rect, radius: f32) {
    let r = CornerRadius::same(radius.min(255.0) as u8);
    ui.painter().rect_stroke(
        rect,
        r,
        Stroke::new(1.0, pal().rim_ring),
        egui::StrokeKind::Inside,
    );
    let top = Rect::from_min_max(
        rect.min + vec2(radius * 0.6, 0.0),
        pos2(rect.max.x - radius * 0.6, rect.min.y + 1.0),
    );
    ui.painter().rect_filled(top, 0.0, pal().rim);
}

/// Pressed into the body: sunken fill and a soft inner shadow on the top edge.
pub fn sunken(ui: &Ui, rect: Rect, radius: f32) {
    let r = CornerRadius::same(radius.min(255.0) as u8);
    ui.painter().rect_filled(rect, r, pal().sunken);
    // Along the straight part of the top edge: a capsule (any radius past half the height) curves
    // away from the edge before that.
    let bend = radius.min(rect.height() / 2.0);
    let top = Rect::from_min_max(
        rect.min + vec2(bend, 0.5),
        pos2(rect.max.x - bend, rect.min.y + 1.5),
    );
    ui.painter().rect_filled(top, 0.0, pal().inset);
}

/// A panel: the ground's own colour, lifted by light and a soft shadow, radius 24.
pub fn panel<R>(ui: &mut Ui, padding: f32, add: impl FnOnce(&mut Ui) -> R) -> R {
    let width = ui.available_width();
    let where_ = ui.painter().add(egui::Shape::Noop);
    let inner = ui.allocate_ui_with_layout(
        vec2(width, 0.0),
        egui::Layout::top_down(egui::Align::Min),
        |ui| {
            egui::Frame::NONE.inner_margin(padding).show(ui, |ui| {
                ui.set_width(width - 2.0 * padding);
                add(ui)
            })
        },
    );
    let rect = inner.response.rect;
    // Drawn behind the content after it is laid out, since its height is known only then.
    let mut shapes = Vec::new();
    let r = CornerRadius::same(RADIUS_LG as u8);
    shapes.push(egui::Shape::from(
        Shadow {
            offset: [2, 3],
            blur: 6,
            spread: 0,
            color: pal().shade,
        }
        .as_shape(rect, r),
    ));
    shapes.push(egui::Shape::rect_filled(rect, r, pal().ground));
    shapes.push(egui::Shape::rect_stroke(
        rect,
        r,
        Stroke::new(1.0, pal().edge),
        egui::StrokeKind::Inside,
    ));
    ui.painter().set(where_, egui::Shape::Vec(shapes));
    inner.inner.inner
}

// MARK: text

/// Text in a given font and colour, laid out without wrapping.
pub fn paint_text(
    ui: &Ui,
    pos: Pos2,
    anchor: egui::Align2,
    text: &str,
    font: FontId,
    color: Color32,
) -> Rect {
    ui.painter().text(pos, anchor, text, font, color)
}

pub fn label_in(ui: &mut Ui, text: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(
        egui::Label::new(egui::RichText::new(text.into()).font(font).color(color))
            .selectable(false),
    )
}

/// Wrapping text, for notes and verdicts.
pub fn wrapped(ui: &mut Ui, text: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(
        egui::Label::new(egui::RichText::new(text.into()).font(font).color(color))
            .wrap()
            .selectable(false),
    )
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
    let galley = ui.painter().layout_job(job);
    if !galley.elided {
        return galley;
    }
    // egui cuts where the room ends, which can leave a space before the "…" ("White …").
    let shown: String = galley
        .rows
        .iter()
        .flat_map(|r| r.glyphs.iter().map(|g| g.chr))
        .collect();
    let kept = shown.trim_end_matches('…').trim_end();
    if kept.len() + '…'.len_utf8() == shown.len() {
        return galley;
    }
    ui.painter()
        .layout_no_wrap(format!("{kept}…"), font_of(&galley), color)
}

/// The font a one-font galley was laid out in.
fn font_of(galley: &egui::Galley) -> FontId {
    galley
        .job
        .sections
        .first()
        .map(|s| s.format.font_id.clone())
        .unwrap_or_default()
}

/// Small capitals with hair spaces between letters. egui does have tracking
/// (`TextFormat::extra_letter_spacing`, as `overline` uses); this is for plain strings.
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

fn overline_job(ui: &Ui, text: &str, color: Color32) -> egui::text::LayoutJob {
    let s = style(ui);
    let mut job = egui::text::LayoutJob::default();
    job.append(
        &text.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: self::text(12.0, s.overline_weight),
            color,
            extra_letter_spacing: s.overline_tracking,
            ..Default::default()
        },
    );
    job
}

/// A printed label: uppercase, tracked wide.
pub fn overline(ui: &mut Ui, text: &str, color: Color32) -> Response {
    let job = overline_job(ui, text, color);
    ui.add(egui::Label::new(job).selectable(false))
}

/// The same, painted with its left edge at `pos.x` and centred on `pos.y`. Returns its width.
pub fn overline_at(ui: &Ui, pos: Pos2, text: &str, color: Color32) -> f32 {
    let galley = ui.painter().layout_job(overline_job(ui, text, color));
    let w = galley.size().x;
    ui.painter()
        .galley(pos2(pos.x, pos.y - galley.size().y / 2.0), galley, color);
    w
}

/// Column titles in tables: uppercase, 11 pt semibold, tracked.
pub fn column_title(ui: &mut Ui, text: &str) -> Response {
    let mut job = egui::text::LayoutJob::default();
    job.append(
        &text.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: self::text(11.0, 600),
            color: pal().ink_muted,
            extra_letter_spacing: 1.2,
            ..Default::default()
        },
    );
    // Never cut short: a title wider than its column runs on, as the Mac table's do.
    ui.add(egui::Label::new(job).selectable(false).extend())
}

/// A cell exactly `width` wide (and at least `height` tall): table columns and form columns stay
/// aligned whatever their content.
pub fn cell<R>(
    ui: &mut Ui,
    width: f32,
    height: f32,
    layout: egui::Layout,
    add: impl FnOnce(&mut Ui) -> R,
) -> R {
    // Allocated like any widget, so a horizontal row centres it vertically with its neighbours.
    let (rect, _) = ui.allocate_exact_size(vec2(width, height), Sense::hover());
    // A child that doesn't move the parent's cursor again: the allocation above already did.
    let mut child = ui.new_child(egui::UiBuilder::new().max_rect(rect).layout(layout));
    add(&mut child)
}

// MARK: controls

pub fn text_width(ui: &Ui, text: &str, font: &FontId) -> f32 {
    ui.fonts_mut(|f| {
        f.layout_no_wrap(text.to_string(), font.clone(), pal().ink)
            .size()
            .x
    })
}

/// The chip's lamp: lit in the app's lamp colour (`Style::led`), a dim dot when not.
pub fn led(ui: &Ui, center: Pos2, lit: bool, size: f32) {
    let s = style(ui);
    led_in(
        ui.painter(),
        center,
        lit,
        size,
        s.led.colors().0,
        s.led.colors().1,
    );
}

fn led_in(p: &Painter, center: Pos2, lit: bool, size: f32, color: Color32, glow: Color32) {
    if lit {
        p.circle_filled(center, size * 1.1, glow);
        p.circle_filled(center, size / 2.0, color);
    } else {
        p.circle_filled(center, size / 2.0, alpha(pal().ink, 0.16));
    }
}

/// A chip: a small key for one-of-many choices; the chosen one sinks in and lights its lamp.
pub fn chip(ui: &mut Ui, title: &str, chosen: bool, enabled: bool) -> Response {
    chip_with(ui, title, chosen, enabled, None)
}

pub fn chip_icon(
    ui: &mut Ui,
    chosen: bool,
    enabled: bool,
    icon: fn(&Ui, Rect, Color32),
) -> Response {
    chip_with(ui, "", chosen, enabled, Some(icon))
}

fn chip_with(
    ui: &mut Ui,
    title: &str,
    chosen: bool,
    enabled: bool,
    icon: Option<fn(&Ui, Rect, Color32)>,
) -> Response {
    let s = style(ui);
    let font = label();
    let content = if icon.is_some() {
        14.0
    } else {
        text_width(ui, title, &font)
    };
    let size = vec2(s.chip_pad + 6.0 + S2 + content + s.chip_pad, s.chip_height);
    let sense = if enabled {
        Sense::click()
    } else {
        Sense::hover()
    };
    let (rect, response) = ui.allocate_exact_size(size, sense);
    if ui.is_rect_visible(rect) {
        let fade = if enabled { 1.0 } else { 0.4 };
        let r = s.chip_height / 2.0;
        if chosen {
            sunken(ui, rect, r);
        } else {
            raised(ui, rect, r, s.chip_raise);
            if response.hovered() && enabled {
                ui.painter()
                    .rect_filled(rect, CornerRadius::same(r as u8), alpha(pal().ink, 0.03));
            }
        }
        led(
            ui,
            pos2(rect.min.x + s.chip_pad + 3.0, rect.center().y),
            chosen,
            6.0,
        );
        let color = (if chosen { pal().ink } else { pal().ink_muted }).gamma_multiply(fade);
        let left = rect.min.x + s.chip_pad + 6.0 + S2;
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

/// Segments in a sunken pill; the chosen one raised in red. Answers the one pressed.
pub fn segments(
    ui: &mut Ui,
    labels: &[&str],
    chosen: usize,
    height: f32,
    pad: f32,
) -> Option<usize> {
    let font = label();
    let widths: Vec<f32> = labels
        .iter()
        .map(|l| text_width(ui, l, &font) + 2.0 * pad)
        .collect();
    let total: f32 = widths.iter().sum();
    let (rect, _) = ui.allocate_exact_size(vec2(total, height), Sense::hover());
    sunken(ui, rect, height / 2.0);
    let mut x = rect.min.x;
    let mut pressed = None;
    for (i, (title, w)) in labels.iter().zip(&widths).enumerate() {
        let seg = Rect::from_min_size(pos2(x, rect.min.y), vec2(*w, height));
        let response = ui
            .interact(seg, ui.scope_id().with(("segment", title)), Sense::click())
            .on_hover_cursor(egui::CursorIcon::PointingHand);
        if i == chosen {
            raise(ui, seg, height / 2.0, 0.6, RUBY);
        } else if response.hovered() {
            ui.painter()
                .rect_filled(seg, CornerRadius::same(255), pal().hover);
        }
        let color = if i == chosen {
            SEASHELL
        } else {
            pal().ink_muted
        };
        ui.painter().text(
            seg.center(),
            egui::Align2::CENTER_CENTER,
            *title,
            font.clone(),
            color,
        );
        if response.clicked() && i != chosen {
            pressed = Some(i);
        }
        x += w;
    }
    pressed
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Key {
    /// The one red key per view: a soft, almost flat red, what's on it light. Disabled, it is a
    /// dark unlit key.
    Primary,
    /// The design system's `key`: strong but not red, the body's own material, raised.
    Raised,
    /// A printed outline.
    Ghost,
}

/// How a key is drawn, beyond its kind and words.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct KeyOptions {
    /// The style's `small` size (table rows).
    pub small: bool,
    /// A trailing arrow ("Check →").
    pub arrow: bool,
    /// Prints quietly and takes no clicks.
    pub disabled: bool,
    /// A set width; words that don't fit end in "…".
    pub width: Option<f32>,
    /// At least this wide: a key whose words change keeps its neighbours still.
    pub min_width: f32,
    /// Another height than the style's (a ghost key in a row of chips takes the chips' height).
    pub height: Option<f32>,
}

/// The system's keys, at the style's sizes.
pub fn button(ui: &mut Ui, kind: Key, title: &str, small: bool) -> Response {
    button_with(
        ui,
        kind,
        title,
        KeyOptions {
            small,
            ..Default::default()
        },
    )
}

/// A key with a trailing arrow ("Check →", "Open Deliver Check →").
pub fn button_arrow(ui: &mut Ui, kind: Key, title: &str, small: bool) -> Response {
    button_with(
        ui,
        kind,
        title,
        KeyOptions {
            small,
            arrow: true,
            ..Default::default()
        },
    )
}

/// A key's body in the family's material, for its state; answers the colour its label takes.
fn key_body(
    ui: &Ui,
    rect: Rect,
    response: &Response,
    kind: Key,
    enabled: bool,
    pressed: bool,
) -> Color32 {
    let s = style(ui);
    let r = rect.height() / 2.0;
    let cr = CornerRadius::same(r.min(255.0) as u8);
    match kind {
        Key::Primary if !enabled => {
            // With nothing to do, the red key goes dark and unlit.
            ui.painter().rect_filled(rect, cr, pal().sunken);
            ui.painter().rect_stroke(
                rect,
                cr,
                Stroke::new(1.0, pal().line),
                egui::StrokeKind::Inside,
            );
            alpha(pal().ink, 0.36)
        }
        Key::Primary => {
            let p = ui.painter();
            for shape in shadow_shapes(rect, cr, &s.primary_shadow, 1.0) {
                p.add(shape);
            }
            let fill = if pressed {
                pal().accent.gamma_multiply(0.7)
            } else if response.hovered() {
                // A step brighter than the accent.
                if pal().dark {
                    Color32::from_rgb(0xDE, 0x1B, 0x0B)
                } else {
                    Color32::from_rgb(0xB4, 0x12, 0x06)
                }
            } else {
                pal().accent
            };
            p.rect_filled(rect, cr, fill);
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
                raised(ui, rect, r, s.key_raise)
            }
            if enabled { pal().ink } else { pal().ink_note }
        }
        Key::Ghost => {
            if response.hovered() && enabled {
                ui.painter().rect_filled(rect, cr, pal().hover);
            }
            let line = if enabled {
                pal().line_print
            } else {
                pal().line
            };
            ui.painter()
                .rect_stroke(rect, cr, Stroke::new(1.0, line), egui::StrokeKind::Inside);
            if !enabled {
                pal().ink_note
            } else if pressed {
                pal().ink_print.gamma_multiply(0.7)
            } else {
                pal().ink_print
            }
        }
    }
}

pub fn button_with(ui: &mut Ui, kind: Key, title: &str, o: KeyOptions) -> Response {
    let s = style(ui);
    let size = if o.small {
        s.small
    } else {
        match kind {
            Key::Primary => s.primary,
            Key::Raised => s.raised,
            Key::Ghost => s.ghost,
        }
    };
    let font = text(size.font_size, size.font_weight);
    let height = o.height.unwrap_or(size.height);
    let arrow_w = if o.arrow { S1 + 10.0 } else { 0.0 };
    let natural = size.pad * 2.0 + text_width(ui, title, &font) + arrow_w;
    let width = o.width.unwrap_or(natural.max(o.min_width));
    let enabled = !o.disabled;
    let sense = if enabled {
        Sense::click()
    } else {
        Sense::hover()
    };
    let (rect, response) = ui.allocate_exact_size(vec2(width, height), sense);
    if ui.is_rect_visible(rect) {
        let pressed = enabled && response.is_pointer_button_down_on();
        let color = key_body(ui, rect, &response, kind, enabled, pressed);
        if o.width.is_some() {
            let g = elided(ui, title, font, color, width - 2.0 * S2 - arrow_w);
            let pos = rect.center() - vec2(arrow_w / 2.0, 0.0) - g.size() / 2.0;
            let right = pos.x + g.size().x;
            ui.painter().galley(pos, g, color);
            if o.arrow {
                arrow_right(ui, pos2(right + S1 + 5.0, rect.center().y), 10.0, color);
            }
        } else {
            let left = rect.center().x - (natural - size.pad * 2.0) / 2.0;
            let text_rect = paint_text(
                ui,
                pos2(left, rect.center().y),
                egui::Align2::LEFT_CENTER,
                title,
                font,
                color,
            );
            if o.arrow {
                arrow_right(
                    ui,
                    pos2(text_rect.max.x + S1 + 5.0, rect.center().y),
                    10.0,
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

/// How a key that opens a menu or a picker looks: see [`menu_key`] and [`picker`].
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct MenuOptions {
    /// The key's material: `Raised` (default) or `Ghost`; `Primary` works too.
    pub kind: Key,
    /// The style's `small` size (table rows).
    pub small: bool,
    /// A set width; words that don't fit end in "…". `None`: as wide as its words.
    pub width: Option<f32>,
    /// At least this wide.
    pub min_width: f32,
    /// Another height than the style's.
    pub height: Option<f32>,
    /// The tallest the popup gets before it scrolls.
    pub max_height: f32,
    /// A picker: the current value at the left, as a combo box shows it. Otherwise the title is
    /// centred, as on any key.
    pub picker: bool,
    pub disabled: bool,
    /// Stays open while things inside are used (checkboxes, sliders), closing on a click outside,
    /// on the key or on Escape. Off: a click on any item closes it, as a menu of commands does.
    pub stay_open: bool,
}

impl Default for MenuOptions {
    fn default() -> Self {
        MenuOptions {
            kind: Key::Raised,
            small: false,
            width: None,
            min_width: 0.0,
            height: None,
            max_height: 420.0,
            picker: false,
            disabled: false,
            stay_open: false,
        }
    }
}

/// A key that opens a menu below it: the family's key with its label and a down chevron, sunk
/// while the menu is open; the menu is egui's own (`Popup::menu`, as `ComboBox` uses), in the
/// palette, so the keyboard works as there: Enter or Space opens it, Tab and the arrows move, Enter
/// picks, Escape closes. Put `ui.button`, `ui.selectable_value` or anything else in `add`; a click
/// on an item closes the menu.
pub fn menu_key<R>(
    ui: &mut Ui,
    title: &str,
    o: MenuOptions,
    add: impl FnOnce(&mut Ui) -> R,
) -> egui::InnerResponse<Option<R>> {
    let s = style(ui);
    let size = if o.small {
        s.small
    } else {
        match o.kind {
            Key::Primary => s.primary,
            Key::Raised => s.raised,
            Key::Ghost => s.ghost,
        }
    };
    let font = text(size.font_size, size.font_weight);
    let height = o.height.unwrap_or(size.height);
    let chevron_w = 8.0 + S2;
    let natural = size.pad * 2.0 + text_width(ui, title, &font) + chevron_w;
    let width = o.width.unwrap_or(natural).max(o.min_width);
    let enabled = !o.disabled;
    let sense = if enabled {
        Sense::click()
    } else {
        Sense::hover()
    };
    let (rect, response) = ui.allocate_exact_size(vec2(width, height), sense);
    let popup_id = egui::Popup::default_response_id(&response);
    let open = egui::Popup::is_id_open(ui.ctx(), popup_id);
    if ui.is_rect_visible(rect) {
        let pressed = enabled && (open || response.is_pointer_button_down_on());
        let color = key_body(ui, rect, &response, o.kind, enabled, pressed);
        let chevron = Rect::from_center_size(
            pos2(rect.max.x - size.pad - 4.0, rect.center().y),
            vec2(8.0, 8.0),
        );
        chevron_vertical(ui.painter(), chevron, color, open);
        let room = width - size.pad * 2.0 - chevron_w;
        let g = elided(ui, title, font, color, room);
        let x = if o.picker {
            rect.min.x + size.pad
        } else {
            rect.min.x + size.pad + (room - g.size().x) / 2.0
        };
        ui.painter()
            .galley(pos2(x, rect.center().y - g.size().y / 2.0), g, color);
    }
    response.widget_info(|| {
        let mut info = egui::WidgetInfo::new(egui::Role::ComboBox);
        info.enabled = enabled;
        info.label = Some(title.to_string());
        info
    });
    let inner = egui::Popup::menu(&response)
        .id(popup_id)
        .width(rect.width())
        .gap(S1)
        .close_behavior(if o.stay_open {
            egui::PopupCloseBehavior::CloseOnClickOutside
        } else {
            egui::PopupCloseBehavior::CloseOnClick
        })
        .show(|ui| {
            ui.set_min_width(ui.available_width());
            egui::ScrollArea::vertical()
                .max_height(o.max_height)
                .show(ui, add)
                .inner
        })
        .map(|r| r.inner);
    let response = if enabled {
        response.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        response
    };
    egui::InnerResponse::new(inner, response)
}

/// A picker: a key showing the current value, which opens the choices below it (what
/// `egui::ComboBox` does, drawn as the family's key). `width`: a set width, or `None` for as wide
/// as the value.
pub fn picker<R>(
    ui: &mut Ui,
    current: &str,
    width: Option<f32>,
    add: impl FnOnce(&mut Ui) -> R,
) -> egui::InnerResponse<Option<R>> {
    menu_key(
        ui,
        current,
        MenuOptions {
            picker: true,
            width,
            ..Default::default()
        },
        add,
    )
}

/// A round printed outline around a drawn glyph (day arrows, "previous", "next").
pub fn round_ghost(
    ui: &mut Ui,
    size: f32,
    enabled: bool,
    glyph: impl FnOnce(&Painter, Rect, Color32),
) -> Response {
    let sense = if enabled {
        Sense::click()
    } else {
        Sense::hover()
    };
    let (rect, response) = ui.allocate_exact_size(vec2(size, size), sense);
    if ui.is_rect_visible(rect) {
        let fade = if enabled { 1.0 } else { 0.3 };
        let p = ui.painter();
        if response.hovered() && enabled {
            p.circle_filled(rect.center(), size / 2.0, pal().hover);
        }
        p.circle_stroke(
            rect.center(),
            size / 2.0 - 0.5,
            Stroke::new(1.0, pal().line_print.gamma_multiply(fade)),
        );
        glyph(p, rect, pal().ink_print.gamma_multiply(fade));
    }
    if enabled {
        response.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        response
    }
}

/// A round raised key around a drawn glyph (a settings button).
pub fn round_raised(
    ui: &mut Ui,
    size: f32,
    glyph: impl FnOnce(&Painter, Rect, Color32),
) -> Response {
    let (rect, response) = ui.allocate_exact_size(vec2(size, size), Sense::click());
    if ui.is_rect_visible(rect) {
        // Sinks in while pressed, as every key of the family does.
        if response.is_pointer_button_down_on() {
            sunken(ui, rect, size / 2.0);
        } else {
            raised(ui, rect, size / 2.0, style(ui).chip_raise);
        }
        glyph(ui.painter(), rect, pal().ink);
    }
    response.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Switch: the knob fits inside the track; lit means on. Answers clicks; the caller flips.
pub fn switch(ui: &mut Ui, on: bool) -> Response {
    let s = style(ui);
    let (rect, response) = ui.allocate_exact_size(s.switch, Sense::click());
    let t = ui.ctx().animate_bool_with_time(response.id, on, 0.25);
    let p = ui.painter();
    let half = s.switch.y / 2.0;
    let track = CornerRadius::same(half as u8);
    p.rect_filled(
        rect,
        track,
        lerp_color(pal().sunken, alpha(pal().ink, 0.9), t),
    );
    if t < 1.0 {
        p.rect_stroke(
            rect,
            track,
            Stroke::new(1.0, pal().line_print.gamma_multiply(1.0 - t)),
            egui::StrokeKind::Inside,
        );
    }
    let x = egui::lerp(rect.min.x + half..=rect.max.x - half, t);
    let knob = pos2(x, rect.center().y);
    p.circle_filled(knob + vec2(1.0, 2.0), s.knob, pal().knob_shadow);
    p.circle_filled(
        knob,
        s.knob,
        lerp_color(alpha(pal().ink, 0.85), pal().ground, t),
    );
    response.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// A switch bound to a value: flips it when clicked; `changed()` says so.
pub fn toggle(ui: &mut Ui, on: &mut bool) -> Response {
    let mut response = switch(ui, *on);
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }
    response
}

pub fn lerp_color(a: Color32, b: Color32, t: f32) -> Color32 {
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgba_premultiplied(
        l(a.r(), b.r()),
        l(a.g(), b.g()),
        l(a.b(), b.b()),
        l(a.a(), b.a()),
    )
}

#[derive(Clone, Copy, PartialEq, Debug)]
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

    fn colours(self) -> (Color32, Color32) {
        match self {
            TagKind::Ink => (pal().ink, pal().ground),
            TagKind::Quiet => (pal().sunken, pal().ink_print),
            TagKind::Accent => (pal().accent, SEASHELL),
        }
    }
}

/// A small printed tag at the style's size (`Style::tag_height`).
pub fn tag(ui: &mut Ui, title: &str, kind: TagKind) -> Response {
    let s = style(ui);
    let g = tag_galley(ui.painter(), title, kind, s.tag_font, s.tag_tracking);
    let size = vec2(tag_width(g.size().x, s.tag_height), s.tag_height);
    let (rect, response) = ui.allocate_exact_size(size, Sense::hover());
    if ui.is_rect_visible(rect) {
        paint_tag_galley(ui.painter(), rect.min, s.tag_height, g, kind);
    }
    response
}

/// A tag painted with its top left at `at`, `height` tall, in type of `font` (size, weight):
/// for tags drawn over pictures. Returns its width.
pub fn paint_tag(
    painter: &Painter,
    at: Pos2,
    height: f32,
    font: (f32, u16),
    title: &str,
    kind: TagKind,
) -> f32 {
    let tracking = font.0 * 0.12;
    let g = tag_galley(painter, title, kind, font, tracking);
    let w = tag_width(g.size().x, height);
    paint_tag_galley(painter, at, height, g, kind);
    w
}

fn tag_galley(
    painter: &Painter,
    title: &str,
    kind: TagKind,
    font: (f32, u16),
    tracking: f32,
) -> Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::default();
    job.append(
        &title.to_uppercase(),
        0.0,
        egui::TextFormat {
            font_id: text(font.0, font.1),
            color: kind.colours().1,
            extra_letter_spacing: tracking,
            ..Default::default()
        },
    );
    painter.layout_job(job)
}

/// Left padding, the words, and the slanted end (the design system's 32-px tag: 11.5 before the
/// words, 28.4 after, scaled to the height).
fn tag_width(words: f32, height: f32) -> f32 {
    let s = height / 32.0;
    11.5 * s + words + 28.4 * s
}

fn paint_tag_galley(painter: &Painter, at: Pos2, height: f32, g: Arc<egui::Galley>, kind: TagKind) {
    let (fill, color) = kind.colours();
    let rect = Rect::from_min_size(at, vec2(tag_width(g.size().x, height), height));
    painter.add(egui::Shape::convex_polygon(
        tag_outline(rect),
        fill,
        Stroke::NONE,
    ));
    painter.galley(
        pos2(
            rect.min.x + 11.5 * height / 32.0,
            rect.center().y - g.size().y / 2.0,
        ),
        g,
        color,
    );
}

/// The tag outline, traced from the design system's own shape (TagShape in the Mac apps, 30
/// units tall): a flat top, the right side slanting in towards the bottom, a sharp top corner
/// rounded 7.89 and a wide bottom corner rounded 12.17 so the two read as equally round, the
/// left side rounded 8.
pub fn tag_outline(r: Rect) -> Vec<Pos2> {
    use std::f32::consts::PI;
    let s = r.height() / 30.0;
    let cap = r.max.x - 23.0 * s;
    let left = 8.0 * s;
    let at = |x: f32, y: f32| pos2(cap + x * s, r.min.y + y * s);
    let mut points = Vec::new();
    let arc = |points: &mut Vec<Pos2>, c: Pos2, radius: f32, from: f32, to: f32| {
        for i in 0..=8 {
            let a = from + (to - from) * i as f32 / 8.0;
            points.push(c + radius * Vec2::angled(a));
        }
    };
    // top left, the top edge to the sharp corner (centre (10.99, 7.89)), the slant, the wide
    // corner (centre (2.03, 17.83)), the bottom edge, bottom left
    arc(
        &mut points,
        pos2(r.min.x + left, r.min.y + left),
        left,
        PI,
        1.5 * PI,
    );
    let sharp_end = (11.02_f32 - 7.89).atan2(18.23 - 10.99);
    arc(
        &mut points,
        at(10.99, 7.89),
        7.89 * s,
        1.5 * PI,
        2.0 * PI + sharp_end,
    );
    let wide_start = (22.66_f32 - 17.83).atan2(13.19 - 2.03);
    arc(
        &mut points,
        at(2.03, 17.83),
        12.17 * s,
        wide_start,
        0.5 * PI,
    );
    arc(
        &mut points,
        pos2(r.min.x + left, r.max.y - left),
        left,
        0.5 * PI,
        PI,
    );
    points
}

/// What a status line says, for its lamp and weight.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Status {
    /// A pass: a dim dot, muted type.
    Ok,
    /// A recommendation: an ink dot.
    Neutral,
    /// A broken requirement: the lit red lamp, full ink type.
    Warning,
    /// Nothing published: an empty ring.
    Unspecified,
}

/// A status lamp before a line of text (Swift: AdviceLabel + StatusLamp): lit red for a broken
/// requirement, an ink dot for a recommendation, a dim dot for a pass, an empty ring where nothing
/// is published. Only the broken one gets full ink type.
pub fn advice(ui: &mut Ui, status: impl Into<Status>, message: &str) -> Response {
    let status = status.into();
    let (font, color) = advice_type(status);
    let line = ui.fonts_mut(|f| f.row_height(&font));
    ui.horizontal_top(|ui| {
        ui.spacing_mut().item_spacing.x = S2;
        let (rect, _) = ui.allocate_exact_size(vec2(6.0, font.size * 1.3), Sense::hover());
        advice_lamp(
            ui.painter(),
            pos2(rect.center().x, rect.min.y + line / 2.0),
            status,
        );
        wrapped(ui, message, font, color)
    })
    .inner
}

/// [`advice`] beside something `slot` tall (a key, a field, a row): its first line is centred in
/// the slot, the lamp on that line, and the same room is left under the last line, so a one-line
/// message is exactly as tall as the slot and a longer one grows downward. Lay it out in a row
/// aligned to the top (`Layout::left_to_right(Align::Min)`) with the thing it sits beside.
pub fn advice_in(ui: &mut Ui, status: impl Into<Status>, message: &str, slot: f32) -> Response {
    let status = status.into();
    let (font, color) = advice_type(status);
    let line = ui.fonts_mut(|f| f.row_height(&font));
    let pad = ((slot - line) / 2.0).max(0.0);
    ui.horizontal_top(|ui| {
        ui.spacing_mut().interact_size.y = 0.0;
        ui.spacing_mut().item_spacing.x = S2;
        let top = ui.cursor().min.y;
        let (rect, _) = ui.allocate_exact_size(vec2(6.0, line + 2.0 * pad), Sense::hover());
        advice_lamp(
            ui.painter(),
            pos2(rect.center().x, top + pad + line / 2.0),
            status,
        );
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 0.0;
            ui.add_space(pad);
            let r = wrapped(ui, message, font, color);
            ui.add_space(pad);
            r
        })
        .inner
    })
    .inner
}

/// The type of an advice line: a warning in the label's weight and full ink, the rest quieter.
fn advice_type(status: Status) -> (FontId, Color32) {
    match status {
        Status::Warning => (label(), pal().ink),
        Status::Neutral => (body(), pal().ink_print),
        Status::Ok => (body(), pal().ink_muted),
        Status::Unspecified => (body(), pal().ink_muted.gamma_multiply(0.75)),
    }
}

/// An advice line's lamp, centred on `c` (the middle of the text's first line).
fn advice_lamp(p: &Painter, c: Pos2, status: Status) {
    match status {
        // a warning is red in every app, whatever colour its chips' lamps are
        Status::Warning => led_in(p, c, true, 6.0, pal().accent, alpha(pal().accent, 0.25)),
        Status::Neutral => {
            p.circle_filled(c, 3.0, pal().ink_print);
        }
        Status::Ok => {
            p.circle_filled(c, 3.0, alpha(pal().ink, 0.22));
        }
        Status::Unspecified => {
            p.circle_stroke(c, 2.5, Stroke::new(1.0, pal().line_print));
        }
    }
}

/// A sunken text field at the style's height, in a capsule.
pub fn field(ui: &mut Ui, value: &mut String, width: f32, hint: &str, invalid: bool) -> Response {
    let s = style(ui);
    let h = s.field_height;
    let (rect, _) = ui.allocate_exact_size(vec2(width, h), Sense::hover());
    sunken(ui, rect, h / 2.0);
    // The text, hint, cursor and selection live in the field less its side margins (egui ignores a
    // text edit's own margin once it is given a frame).
    let size = s.field_font.0;
    let inner = rect.shrink2(vec2(s.field_margin, 0.0));
    let edit = egui::TextEdit::singleline(value)
        .font(text(size, s.field_font.1))
        .text_color(pal().ink)
        .hint_text(
            egui::RichText::new(hint)
                .font(text(size, s.field_font.1))
                .color(pal().ink_muted),
        )
        .frame(egui::Frame::NONE)
        .margin(egui::Margin::ZERO)
        .align(egui::Align2::LEFT_CENTER)
        .desired_width(inner.width());
    // `place`, not `put`: the field's whole width is already laid out above.
    let response = ui.place(inner, edit);
    let stroke = if invalid {
        Stroke::new(1.5, pal().accent)
    } else if response.has_focus() {
        Stroke::new(1.0, pal().line_print)
    } else {
        Stroke::new(1.0, pal().line)
    };
    ui.painter().rect_stroke(
        rect,
        CornerRadius::same((h / 2.0) as u8),
        stroke,
        egui::StrokeKind::Inside,
    );
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
    p.line_segment(
        [center - vec2(s * 0.85, 0.0), center + vec2(s * 0.85, 0.0)],
        stroke,
    );
    p.line_segment(
        [
            center + vec2(s * 0.85, 0.0),
            center + vec2(s * 0.15, -s * 0.7),
        ],
        stroke,
    );
    p.line_segment(
        [
            center + vec2(s * 0.85, 0.0),
            center + vec2(s * 0.15, s * 0.7),
        ],
        stroke,
    );
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

/// A chevron pointing up or down, centred in `rect` (for round keys).
pub fn chevron_vertical(p: &Painter, rect: Rect, color: Color32, up: bool) {
    let c = rect.center();
    let d = if up { -1.0 } else { 1.0 };
    p.line(
        vec![
            c + vec2(-4.0, -2.0 * d),
            c + vec2(0.0, 2.0 * d),
            c + vec2(4.0, -2.0 * d),
        ],
        Stroke::new(1.6, color),
    );
}

/// The settings glyph: three sliders.
pub fn sliders(p: &Painter, rect: Rect, color: Color32) {
    let c = rect.center();
    let stroke = Stroke::new(1.5, color);
    for (dy, knob) in [(-4.5_f32, 1.5_f32), (0.0, -2.0), (4.5, 2.5)] {
        p.line_segment([c + vec2(-7.0, dy), c + vec2(7.0, dy)], stroke);
        p.circle_filled(c + vec2(knob, dy), 2.4, pal().ground);
        p.circle_stroke(c + vec2(knob, dy), 2.2, stroke);
    }
}

/// A plus sign.
pub fn plus(p: &Painter, c: Pos2, color: Color32) {
    let s = Stroke::new(1.6, color);
    p.line_segment([c + vec2(-4.5, 0.0), c + vec2(4.5, 0.0)], s);
    p.line_segment([c + vec2(0.0, -4.5), c + vec2(0.0, 4.5)], s);
}

pub fn copy_icon(ui: &Ui, rect: Rect, color: Color32) {
    let s = rect.width() / 16.0;
    let stroke = Stroke::new(1.3, color);
    let front = Rect::from_min_size(rect.min + vec2(5.0, 5.0) * s, vec2(8.5, 8.5) * s);
    ui.painter().rect_stroke(
        front,
        CornerRadius::same(2),
        stroke,
        egui::StrokeKind::Middle,
    );
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
        ui.painter().extend(egui::Shape::dashed_line(
            &[pair[0], pair[1]],
            stroke,
            dash,
            gap,
        ));
    }
}
