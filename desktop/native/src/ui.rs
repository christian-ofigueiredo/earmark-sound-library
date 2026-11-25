//! Earmark's window for Windows and Linux, drawn with egui: the header (wordmark, the section
//! switch, search), the sidebar (libraries, duplicates, categories), the list or the map, a sound's
//! details, and the status bar. Same layout as the Mac app and the earlier web window.

use crate::backend::{Backend, Event, Row, Scope, Snapshot, SongRow, SoundMap, teller};
use crate::look::{self, INK_NOTE};
use crate::player::Player;
use crate::theme::{self, INK, INK_MUTED, INK_PRINT, Key as KeyKind, LINE, SHARK};

const ROW_HEIGHT: f32 = 28.0;
use egui::{Align, Align2, Color32, CornerRadius, Frame, Key, Layout, Margin, Rect, Sense, Stroke, Ui, pos2, vec2};
use serde_json::Value;
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

pub fn number(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn length(seconds: Option<f64>) -> String {
    let Some(s) = seconds else {
        return String::new();
    };
    if s < 60.0 {
        return format!("{s:.1} s");
    }
    let m = (s / 60.0).floor() as u64;
    let rest = (s % 60.0).floor() as u64;
    format!("{m}:{rest:02}")
}

/// "FOOTSTEPS-HUMAN" → "Footsteps-Human"; "UI" stays "UI".
pub fn title_case(text: &str) -> String {
    let mut out = String::new();
    let mut start = true;
    for c in text.chars() {
        if start && c.is_alphabetic() {
            out.extend(c.to_uppercase());
        } else {
            out.extend(c.to_lowercase());
        }
        start = c.is_whitespace() || matches!(c, '/' | '&' | '-');
    }
    out.split_inclusive([' ', '/', '&', '-'])
        .map(|w| {
            let bare = w.trim_end_matches([' ', '/', '&', '-']);
            if ["Ui", "Tv", "Sfx", "Dj", "Pa"].contains(&bare) {
                format!("{}{}", bare.to_uppercase(), &w[bare.len()..])
            } else {
                w.to_string()
            }
        })
        .collect()
}

/// The map's colours, by how many sounds a category has there (the rest share the last).
const MAP_COLOURS: [Color32; 7] = [
    Color32::from_rgb(0xd4, 0x11, 0x01),
    Color32::from_rgb(0xe5, 0xa2, 0x3a),
    Color32::from_rgb(0x5a, 0xa9, 0xe6),
    Color32::from_rgb(0x7b, 0xc4, 0x7f),
    Color32::from_rgb(0xb4, 0x8e, 0xad),
    Color32::from_rgb(0xe0, 0x7a, 0x5f),
    Color32::from_rgb(0x9a, 0xa5, 0xb1),
];

enum Dialog {
    Remove(i64, String),
    Message(String),
}

/// For checking without driving the window: `--shot file.png` saves what's drawn and quits.
pub struct Shot {
    pub path: std::path::PathBuf,
    pub select_first: bool,
    pub music: bool,
    pub map: bool,
    frames: u32,
    asked: bool,
}

impl Shot {
    pub fn new(path: std::path::PathBuf, select_first: bool, music: bool, map: bool) -> Self {
        Shot {
            path,
            select_first,
            music,
            map,
            frames: 0,
            asked: false,
        }
    }
}

pub struct EarmarkApp {
    back: Arc<Backend>,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    snap: Snapshot,
    music: bool,
    map_view: bool,
    scope: Scope,
    query: String,
    rows: Vec<Row>,
    songs: Vec<SongRow>,
    dirty: bool,
    selected: Option<i64>,
    details: Option<Value>,
    similar: Option<Result<Vec<Value>, String>>,
    expanded: HashSet<String>,
    map: Option<Arc<SoundMap>>,
    map_scope: Option<Option<String>>,
    map_problem: Option<String>,
    player: Player,
    activity: String,
    activity_until: Option<Instant>,
    analysing: bool,
    stopping: bool,
    dialog: Option<Dialog>,
    /// The list's scroll: where it is, how tall it shows, where to go next.
    offset: f32,
    viewport: f32,
    scroll_to: Option<f32>,
    shot: Option<Shot>,
}

impl EarmarkApp {
    pub fn new(cc: &eframe::CreationContext<'_>, back: Backend, shot: Option<Shot>) -> Self {
        theme::install(&cc.egui_ctx);
        crate::frame::paint(cc);
        // Linux: ask for the dark theme, which Wayland's drawn title bar and GNOME follow.
        cc.egui_ctx
            .send_viewport_cmd(egui::ViewportCommand::SetTheme(egui::SystemTheme::Dark));
        let (tx, rx) = channel();
        let mut app = EarmarkApp {
            back: Arc::new(back),
            tx,
            rx,
            snap: Snapshot::default(),
            music: false,
            map_view: false,
            scope: Scope::All,
            query: String::new(),
            rows: Vec::new(),
            songs: Vec::new(),
            dirty: true,
            selected: None,
            details: None,
            similar: None,
            expanded: HashSet::new(),
            map: None,
            map_scope: None,
            map_problem: None,
            player: Player::new(),
            activity: String::new(),
            activity_until: None,
            analysing: false,
            stopping: false,
            dialog: None,
            offset: 0.0,
            viewport: 0.0,
            scroll_to: None,
            shot,
        };
        app.refresh();
        app
    }

    fn tell(&self, ctx: &egui::Context) -> impl Fn(Event) + Send + Sync + 'static {
        teller(self.tx.clone(), ctx.clone())
    }

    fn refresh(&mut self) {
        match self.back.snapshot() {
            Ok(s) => self.snap = s,
            Err(e) => self.dialog = Some(Dialog::Message(e)),
        }
        self.dirty = true;
        self.map = None;
        self.map_scope = None;
    }

    fn reload(&mut self) {
        self.dirty = false;
        let result = if self.music {
            self.back.songs(&self.scope, &self.query).map(|s| self.songs = s)
        } else {
            self.back.sounds(&self.scope, &self.query).map(|r| self.rows = r)
        };
        if let Err(e) = result {
            self.say(&e, Some(6));
        }
    }

    fn say(&mut self, text: &str, seconds: Option<u64>) {
        self.activity = text.to_string();
        self.activity_until = seconds.map(|s| Instant::now() + Duration::from_secs(s));
    }

    fn choose(&mut self, scope: Scope) {
        self.scope = scope;
        self.selected = None;
        self.details = None;
        self.similar = None;
        self.scroll_to = Some(0.0);
        self.map = None;
        self.map_scope = None;
        self.dirty = true;
    }

    fn set_section(&mut self, music: bool) {
        self.music = music;
        if music {
            self.map_view = false;
        }
        self.choose(Scope::All);
    }

    fn select_sound(&mut self, id: i64) {
        self.selected = Some(id);
        self.similar = None;
        self.details = if self.music {
            None
        } else {
            match self.back.tool("get_sound", serde_json::json!({ "sound_id": id })) {
                Ok(v) => Some(v),
                Err(e) => {
                    self.say(&e, Some(6));
                    None
                }
            }
        };
    }

    fn play(&mut self, path: &str) {
        if let Err(e) = self.player.toggle(path) {
            self.say(&format!("Couldn't play it: {e}"), Some(5));
        }
    }

    fn add_library(&mut self, ctx: &egui::Context, music: bool) {
        let Some(folder) = rfd::FileDialog::new().pick_folder() else {
            return;
        };
        match self.back.add_library(music, &folder) {
            Ok(id) => {
                self.refresh();
                self.back.start_scan(vec![id], self.tell(ctx));
            }
            Err(e) => self.dialog = Some(Dialog::Message(e)),
        }
    }

    fn import(&mut self) {
        let Some(file) = rfd::FileDialog::new()
            .add_filter("Earmark analysis", &["json"])
            .pick_file()
        else {
            return;
        };
        let said = match self.back.import_analysis(&file) {
            Ok(said) => said,
            Err(e) => format!("Couldn't import it: {e}"),
        };
        self.dialog = Some(Dialog::Message(said));
        self.refresh();
    }

    fn analyse(&mut self, ctx: &egui::Context) {
        if self.analysing {
            self.back.stop_analysis();
            self.stopping = true;
            return;
        }
        self.analysing = true;
        self.stopping = false;
        self.say("Analysing…", None);
        self.back.start_analysis(self.tell(ctx));
    }

    fn find_similar(&mut self, ctx: &egui::Context, id: i64) {
        self.similar = Some(Ok(Vec::new()));
        let back = self.back.clone();
        let tell = self.tell(ctx);
        std::thread::spawn(move || {
            let found = back
                .tool("find_similar", serde_json::json!({ "sound_id": id, "limit": 50 }))
                .map(|v| v["similar"].as_array().cloned().unwrap_or_default());
            tell(Event::Similar(id, found));
        });
    }

    fn add_to_resolve(&mut self, ctx: &egui::Context, id: i64, name: &str) {
        self.say(&format!("Adding “{name}” to DaVinci Resolve…"), None);
        let back = self.back.clone();
        let tell = self.tell(ctx);
        std::thread::spawn(move || match back.add_to_resolve(id) {
            Ok(said) => tell(Event::Said(said)),
            Err(e) => tell(Event::Problem(e)),
        });
    }

    fn save_timeline(&mut self, id: i64) {
        match self.back.save_timeline(&[id], "25") {
            Ok(path) => {
                let _ = opener::reveal(&path);
                self.say(&format!("Saved {path}"), Some(6));
            }
            Err(e) => self.dialog = Some(Dialog::Message(e)),
        }
    }

    fn take_events(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                Event::Progress(name, done, total) => self.say(
                    &format!("Reading “{name}”: {} of {} files", number(done), number(total)),
                    None,
                ),
                Event::Scanned(problem) => {
                    match problem {
                        Some(p) => self.say(&format!("Couldn't read it: {p}"), Some(8)),
                        None => self.say("", None),
                    }
                    self.refresh();
                }
                Event::Analysis(what, done, total) => {
                    self.say(&format!("{what}: {} of {}", number(done), number(total)), None)
                }
                Event::Analysed(said) => {
                    self.analysing = false;
                    self.stopping = false;
                    self.say(&said, Some(15));
                    self.refresh();
                }
                Event::Similar(id, found) => {
                    if self.selected == Some(id) {
                        self.similar = Some(
                            found
                                .map(|list| {
                                    if list.is_empty() {
                                        Err("Nothing like it yet.".to_string())
                                    } else {
                                        Ok(list)
                                    }
                                })
                                .and_then(|r| r),
                        );
                    }
                }
                Event::Map(scope, result) => {
                    let wanted = self.map_scope.clone().flatten().unwrap_or_default();
                    if scope == wanted {
                        match result {
                            Ok(m) => {
                                self.map = Some(m);
                                self.map_problem = None;
                            }
                            Err(e) => self.map_problem = Some(e),
                        }
                    }
                }
                Event::Said(said) => self.say(&said, Some(5)),
                Event::Problem(p) => {
                    self.say("", None);
                    self.dialog = Some(Dialog::Message(p));
                }
            }
        }
        if self.activity_until.is_some_and(|t| Instant::now() > t) {
            self.activity.clear();
            self.activity_until = None;
        }
        if self.player.tick() {
            // A sound ended by itself.
        }
    }

    fn keys(&mut self, ctx: &egui::Context) {
        if ctx.egui_wants_keyboard_input() || self.dialog.is_some() {
            return;
        }
        let (space, down, up) = ctx.input(|i| {
            (
                i.key_pressed(Key::Space),
                i.key_pressed(Key::ArrowDown),
                i.key_pressed(Key::ArrowUp),
            )
        });
        let ids: Vec<(i64, String)> = if self.music {
            self.songs.iter().map(|s| (s.id, s.path.clone())).collect()
        } else {
            self.rows.iter().map(|r| (r.id, r.path.clone())).collect()
        };
        let at = self.selected.and_then(|s| ids.iter().position(|(id, _)| *id == s));
        if space && let Some(i) = at {
            let path = ids[i].1.clone();
            self.play(&path);
        }
        if (down || up) && !ids.is_empty() {
            let next = match at {
                None => 0,
                Some(i) if down => (i + 1).min(ids.len() - 1),
                Some(i) => i.saturating_sub(1),
            };
            self.select_sound(ids[next].0);
            let top = next as f32 * ROW_HEIGHT;
            if top < self.offset {
                self.scroll_to = Some(top);
            } else if top + ROW_HEIGHT > self.offset + self.viewport {
                self.scroll_to = Some(top + ROW_HEIGHT - self.viewport);
            }
        }
    }

    // MARK: header

    fn header(&mut self, ui: &mut Ui) {
        ui.horizontal_centered(|ui| {
            ui.spacing_mut().item_spacing.x = 18.0;
            let (rect, _) = ui.allocate_exact_size(vec2(131.0, 34.0), Sense::hover());
            ui.painter().text(
                pos2(rect.min.x, rect.center().y + 1.0),
                Align2::LEFT_CENTER,
                "EARMARK",
                theme::display(30.0, 700),
                INK,
            );
            if let Some(i) = look::segments(ui, &["Sound Effects", "Music"], usize::from(self.music), 34.0, 18.0) {
                self.set_section(i == 1);
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let (rect, _) = ui.allocate_exact_size(vec2(304.0, 32.0), Sense::hover());
                theme::sunken(ui, rect, 255.0);
                let inner = rect.shrink2(vec2(14.0, 0.0));
                let edit = egui::TextEdit::singleline(&mut self.query)
                    .frame(Frame::NONE)
                    .hint_text(egui::RichText::new("Search").color(INK_NOTE))
                    .font(theme::text(13.0, 400))
                    .text_color(INK)
                    .align(Align2::LEFT_CENTER)
                    .margin(Margin::ZERO);
                let response = ui.put(inner, edit);
                if response.changed() {
                    self.dirty = true;
                    self.scroll_to = Some(0.0);
                    self.map = None;
                }
            });
        });
    }

    // MARK: sidebar

    fn side_item(ui: &mut Ui, label: &str, count: Option<usize>, on: bool, indent: f32, dim: bool) -> egui::Response {
        let (rect, response) = ui.allocate_exact_size(vec2(ui.available_width(), 27.0), Sense::click());
        let p = ui.painter();
        if on {
            p.rect_filled(rect, CornerRadius::same(8), theme::SELECTION_RED);
        } else if response.hovered() {
            p.rect_filled(rect, CornerRadius::same(8), theme::HOVER);
        }
        let mut right = rect.max.x - 8.0;
        if let Some(n) = count {
            let g = p.layout_no_wrap(number(n), theme::text(11.0, 400), INK_NOTE);
            right -= g.size().x;
            p.galley(pos2(right, rect.center().y - g.size().y / 2.0), g, INK_NOTE);
            right -= 6.0;
        }
        let x = rect.min.x + 8.0 + indent;
        let color = if dim {
            INK_NOTE
        } else if indent > 0.0 && !on {
            INK_PRINT
        } else {
            INK
        };
        let g = look::elided(ui, label, theme::text(13.0, 400), color, right - x);
        ui.painter()
            .galley(pos2(x, rect.center().y - g.size().y / 2.0), g, color);
        response
    }

    fn side_title(ui: &mut Ui, title: &str) {
        ui.add_space(16.0 - ui.spacing().item_spacing.y);
        let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 14.0), Sense::hover());
        ui.painter().text(
            pos2(rect.min.x + 8.0, rect.center().y),
            Align2::LEFT_CENTER,
            look::spaced(title),
            theme::text(11.0, 600),
            INK_NOTE,
        );
        ui.add_space(6.0 - ui.spacing().item_spacing.y);
    }

    fn sidebar(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        ui.spacing_mut().item_spacing.y = 0.0;
        let music = self.music;
        let all = if music { "All Songs" } else { "All Sounds" };
        let count = if music { self.snap.songs } else { self.snap.sounds };
        if Self::side_item(ui, all, Some(count), self.scope == Scope::All, 0.0, false).clicked() {
            self.choose(Scope::All);
        }
        Self::side_title(ui, "Libraries");
        let libraries: Vec<_> = self
            .snap
            .libraries
            .iter()
            .filter(|l| l.music == music)
            .cloned()
            .collect();
        for lib in libraries {
            let on = self.scope == Scope::Library(lib.id);
            let r = Self::side_item(ui, &lib.name, Some(lib.count), on, 0.0, !lib.online);
            let r = r.on_hover_text(if lib.online {
                lib.path.clone()
            } else {
                format!("{} (not connected)", lib.path)
            });
            if r.clicked() {
                self.choose(Scope::Library(lib.id));
            }
            r.context_menu(|ui| {
                if ui.button("Read Again").clicked() {
                    self.back.start_scan(vec![lib.id], self.tell(ctx));
                    ui.close();
                }
                if ui.button("Remove from Earmark…").clicked() {
                    self.dialog = Some(Dialog::Remove(lib.id, lib.name.clone()));
                    ui.close();
                }
            });
        }
        let add = if music { "Add Music Folder…" } else { "Add Library…" };
        if Self::side_item(ui, add, None, false, 0.0, true).clicked() {
            self.add_library(ctx, music);
        }
        if music {
            return;
        }
        ui.add_space(6.0);
        if Self::side_item(
            ui,
            "Duplicates",
            Some(self.snap.duplicates),
            self.scope == Scope::Duplicates,
            0.0,
            false,
        )
        .clicked()
        {
            self.choose(Scope::Duplicates);
        }
        Self::side_title(ui, "Categories");
        let categories = self.snap.categories.clone();
        for c in categories {
            let open = self.expanded.contains(&c.name);
            let on = self.scope == Scope::Category(c.name.clone());
            let r = Self::side_item(ui, &title_case(&c.name), Some(c.count), on, 18.0, false);
            // The chevron, drawn: Tessel has no arrows.
            let centre = pos2(r.rect.min.x + 14.0, r.rect.center().y);
            let points = if open {
                vec![
                    centre + vec2(-3.5, -1.8),
                    centre + vec2(0.0, 1.8),
                    centre + vec2(3.5, -1.8),
                ]
            } else {
                vec![
                    centre + vec2(-1.8, -3.5),
                    centre + vec2(1.8, 0.0),
                    centre + vec2(-1.8, 3.5),
                ]
            };
            ui.painter().line(points, Stroke::new(1.6, INK_NOTE));
            if r.clicked() {
                let on_chevron = r.interact_pointer_pos().is_some_and(|p| p.x < r.rect.min.x + 24.0);
                if on_chevron {
                    if open {
                        self.expanded.remove(&c.name);
                    } else {
                        self.expanded.insert(c.name.clone());
                    }
                } else {
                    self.choose(Scope::Category(c.name.clone()));
                }
            }
            if open {
                for s in &c.subcategories {
                    let on = self.scope == Scope::Category(s.cat_id.clone());
                    if Self::side_item(ui, &title_case(&s.label), Some(s.count), on, 18.0, false).clicked() {
                        self.choose(Scope::Category(s.cat_id.clone()));
                    }
                }
            }
        }
    }

    // MARK: the list

    /// The columns' x and width inside a row of `width`, as the web window's grid: fixed ones and
    /// shares of the rest; narrow lists drop Folder, then Format (Album for songs).
    fn columns(width: f32, music: bool) -> Vec<Option<(f32, f32)>> {
        // (share or fixed width, is fixed)
        let spec: &[(f32, bool)] = if music {
            &[
                (2.0, false),
                (1.2, false),
                (1.2, false),
                (64.0, true),
                (56.0, true),
                (80.0, true),
            ]
        } else {
            &[(2.0, false), (1.1, false), (64.0, true), (1.4, false), (130.0, true)]
        };
        let shown: Vec<bool> = (0..spec.len())
            .map(|i| match (music, i) {
                (false, 3) => width > 620.0,
                (false, 4) => width > 470.0,
                (true, 2) => width > 470.0,
                _ => true,
            })
            .collect();
        let gap = 12.0;
        let pad = 14.0;
        let n = shown.iter().filter(|s| **s).count() as f32;
        let fixed: f32 = spec
            .iter()
            .zip(&shown)
            .filter(|((_, f), s)| *f && **s)
            .map(|((w, _), _)| w)
            .sum();
        let shares: f32 = spec
            .iter()
            .zip(&shown)
            .filter(|((_, f), s)| !*f && **s)
            .map(|((w, _), _)| w)
            .sum();
        let free = (width - 2.0 * pad - gap * (n - 1.0) - fixed).max(0.0);
        let mut x = pad;
        spec.iter()
            .zip(&shown)
            .map(|((w, f), s)| {
                if !s {
                    return None;
                }
                let width = if *f { *w } else { free * w / shares };
                let col = (x, width);
                x += width + gap;
                Some(col)
            })
            .collect()
    }

    fn cells(ui: &Ui, rect: Rect, cols: &[Option<(f32, f32)>], texts: &[(&str, bool)], head: bool) {
        let font = if head {
            theme::text(11.0, 600)
        } else {
            theme::text(13.0, 400)
        };
        for (i, (col, (text, right))) in cols.iter().zip(texts).enumerate() {
            let Some((x, w)) = col else { continue };
            let color = if head {
                INK_NOTE
            } else if i == 0 {
                INK
            } else {
                INK_MUTED
            };
            let shown = if head { look::spaced(text) } else { text.to_string() };
            let g = look::elided(ui, &shown, font.clone(), color, *w);
            let gx = if *right {
                rect.min.x + x + w - g.size().x
            } else {
                rect.min.x + x
            };
            ui.painter()
                .galley(pos2(gx, rect.center().y - g.size().y / 2.0), g, color);
        }
    }

    fn list(&mut self, ui: &mut Ui) {
        let width = ui.available_width();
        let music = self.music;
        let cols = Self::columns(width, music);
        // The header row.
        let (head, _) = ui.allocate_exact_size(vec2(width, 26.0), Sense::hover());
        let names: Vec<(&str, bool)> = if music {
            vec![
                ("Title", false),
                ("Artist", false),
                ("Album", false),
                ("Length", true),
                ("BPM", true),
                ("Key", false),
            ]
        } else {
            vec![
                ("Name", false),
                ("Category", false),
                ("Length", true),
                ("Folder", false),
                ("Format", false),
            ]
        };
        Self::cells(ui, head, &cols, &names, true);
        ui.painter()
            .hline(head.x_range(), head.max.y - 0.5, Stroke::new(1.0, LINE));

        let count = if music { self.songs.len() } else { self.rows.len() };
        if count == 0 {
            if !self.query.is_empty() {
                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    ui.add_space(14.0);
                    ui.label(
                        egui::RichText::new(if music { "No songs match." } else { "No sounds match." }).color(INK_NOTE),
                    );
                });
            }
            return;
        }
        let mut area = egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .id_salt(("list", music));
        if let Some(y) = self.scroll_to.take() {
            area = area.vertical_scroll_offset(y);
        }
        let mut clicked: Option<usize> = None;
        let mut double: Option<usize> = None;
        let playing = self.player.path.clone();
        let output = area.show_rows(ui, ROW_HEIGHT, count, |ui, range| {
            ui.spacing_mut().item_spacing.y = 0.0;
            for i in range {
                let (rect, response) = ui.allocate_exact_size(vec2(width, ROW_HEIGHT), Sense::click());
                let (id, path) = if music {
                    (self.songs[i].id, &self.songs[i].path)
                } else {
                    (self.rows[i].id, &self.rows[i].path)
                };
                if self.selected == Some(id) {
                    ui.painter().rect_filled(rect, 0.0, theme::SELECTION_RED);
                } else if response.hovered() {
                    ui.painter().rect_filled(rect, 0.0, theme::HOVER);
                }
                if playing.as_deref() == Some(path.as_str()) {
                    // The playing mark sits in the left margin, so names line up with the
                    // toolbar's left edge.
                    let c = pos2(rect.min.x + 7.0, rect.center().y);
                    ui.painter()
                        .circle_filled(c, 6.0, Color32::from_rgba_unmultiplied(212, 17, 1, 50));
                    ui.painter().circle_filled(c, 4.0, theme::MILANO);
                }
                if music {
                    let s = &self.songs[i];
                    let len = length(s.length);
                    let bpm = s.bpm.map(|b| format!("{b:.1}")).unwrap_or_default();
                    Self::cells(
                        ui,
                        rect,
                        &cols,
                        &[
                            (&s.title, false),
                            (s.artist.as_deref().unwrap_or(""), false),
                            (s.album.as_deref().unwrap_or(""), false),
                            (&len, true),
                            (&bpm, true),
                            (s.key.as_deref().unwrap_or(""), false),
                        ],
                        false,
                    );
                } else {
                    let r = &self.rows[i];
                    let len = length(r.length);
                    let cat = title_case(&r.category);
                    Self::cells(
                        ui,
                        rect,
                        &cols,
                        &[
                            (&r.name, false),
                            (&cat, false),
                            (&len, true),
                            (&r.folder, false),
                            (&r.format, false),
                        ],
                        false,
                    );
                }
                if response.double_clicked() {
                    double = Some(i);
                } else if response.clicked() {
                    clicked = Some(i);
                }
            }
        });
        self.offset = output.state.clamped_offset().y;
        self.viewport = output.inner_rect.height();
        let pick = |me: &Self, i: usize| -> (i64, String) {
            if me.music {
                (me.songs[i].id, me.songs[i].path.clone())
            } else {
                (me.rows[i].id, me.rows[i].path.clone())
            }
        };
        if let Some(i) = clicked {
            let (id, _) = pick(self, i);
            self.select_sound(id);
        }
        if let Some(i) = double {
            let (id, path) = pick(self, i);
            if self.selected != Some(id) {
                self.select_sound(id);
            }
            self.play(&path);
        }
    }

    // MARK: the map

    fn map(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        let scope = match &self.scope {
            Scope::Category(c) => Some(c.clone()),
            _ => None,
        };
        if self.map_scope.as_ref() != Some(&scope) {
            self.map_scope = Some(scope.clone());
            self.map = None;
            self.map_problem = None;
            let back = self.back.clone();
            let tell = self.tell(ctx);
            std::thread::spawn(move || {
                let made = back.sound_map(scope.clone());
                tell(Event::Map(scope.unwrap_or_default(), made));
            });
        }
        let (rect, response) = ui.allocate_exact_size(ui.available_size(), Sense::click());
        let note_at = rect.min + vec2(16.0, 10.0);
        let note = |ui: &Ui, text: &str| {
            ui.painter()
                .text(note_at, Align2::LEFT_TOP, text, theme::text(13.0, 400), INK_NOTE);
        };
        if let Some(p) = &self.map_problem {
            note(ui, p);
            return;
        }
        let Some(map) = self.map.clone() else {
            note(ui, "Making the map…");
            return;
        };
        if map.points.is_empty() {
            note(ui, "No analysed sounds here yet.");
            return;
        }
        note(ui, &format!("{} analysed sounds", number(map.points.len())));
        let mut counts: std::collections::HashMap<&str, usize> = Default::default();
        for p in &map.points {
            *counts.entry(p.category.as_str()).or_default() += 1;
        }
        let mut order: Vec<(&str, usize)> = counts.into_iter().collect();
        order.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        let colour = |c: &str| {
            let i = order.iter().position(|(n, _)| *n == c).unwrap_or(usize::MAX);
            MAP_COLOURS[i.min(MAP_COLOURS.len() - 1)]
        };
        let pad = 30.0;
        let size = rect.width().min(rect.height()) - 2.0 * pad;
        let origin = rect.center() - vec2(size, size) / 2.0;
        let at = |x: f32, y: f32| origin + vec2(x * size, y * size);
        let painter = ui.painter_at(rect);
        for p in &map.points {
            let c = at(p.x, p.y);
            painter.rect_filled(
                Rect::from_center_size(c, vec2(2.4, 2.4)),
                0.0,
                colour(&p.category).gamma_multiply(0.75),
            );
        }
        // The nearest point under the pointer: its name, and a click selects it.
        let near = |pos: egui::Pos2| {
            map.points
                .iter()
                .map(|p| (p, at(p.x, p.y).distance_sq(pos)))
                .filter(|(_, d)| *d < 64.0)
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .map(|(p, _)| p)
        };
        if let Some(pos) = response.hover_pos()
            && let Some(p) = near(pos)
        {
            painter.circle_stroke(at(p.x, p.y), 4.0, Stroke::new(1.5, INK));
            response.clone().on_hover_text_at_pointer(&p.name);
        }
        if response.clicked()
            && let Some(pos) = response.interact_pointer_pos()
            && let Some(p) = near(pos)
        {
            let id = p.id;
            self.select_sound(id);
        }
        if let Some(id) = self.selected
            && let Some(p) = map.points.iter().find(|p| p.id == id)
        {
            painter.circle_stroke(at(p.x, p.y), 5.0, Stroke::new(2.0, theme::MILANO));
        }
    }

    // MARK: empty

    fn empty(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        let music = self.music;
        ui.vertical_centered(|ui| {
            ui.add_space((ui.available_height() / 2.0 - 90.0).max(20.0));
            ui.label(
                egui::RichText::new(if music {
                    "Add your music"
                } else {
                    "Add your sound library"
                })
                .font(theme::display(34.0, 700))
                .color(INK),
            );
            ui.add_space(10.0);
            ui.label(
                egui::RichText::new(if music {
                    "Pick the folder that holds your music. Earmark reads the files and never changes them."
                } else {
                    "Pick the folder that holds your sound effects. Earmark reads the files and never changes them."
                })
                .color(INK_MUTED),
            );
            ui.add_space(14.0);
            let widths = if music { 290.0 } else { 440.0 };
            ui.allocate_ui_with_layout(vec2(widths, 30.0), Layout::left_to_right(Align::Center), |ui| {
                ui.spacing_mut().item_spacing.x = 10.0;
                if music {
                    if look::key(ui, KeyKind::Primary, "Add Music Folder…", true, None).clicked() {
                        self.add_library(ctx, true);
                    }
                } else {
                    if look::key(ui, KeyKind::Primary, "Add Sound Library…", true, None).clicked() {
                        self.add_library(ctx, false);
                    }
                    if look::key(ui, KeyKind::Raised, "Add Music Folder…", true, None).clicked() {
                        self.add_library(ctx, true);
                    }
                }
                if look::key(ui, KeyKind::Raised, "Import Analysis…", true, None).clicked() {
                    self.import();
                }
            });
        });
    }

    // MARK: details

    fn pair(ui: &mut Ui, label: &str, value: &str) {
        if value.is_empty() {
            return;
        }
        let width = ui.available_width();
        let top = ui.cursor().min;
        ui.painter()
            .hline(top.x..=top.x + width, top.y + 0.5, Stroke::new(1.0, LINE));
        ui.add_space(5.0);
        ui.horizontal_top(|ui| {
            ui.spacing_mut().item_spacing.x = 10.0;
            let (rect, _) = ui.allocate_exact_size(vec2(88.0, 16.0), Sense::hover());
            ui.painter().text(
                pos2(rect.min.x, rect.min.y),
                Align2::LEFT_TOP,
                label,
                theme::text(13.0, 400),
                INK_NOTE,
            );
            ui.add(
                egui::Label::new(egui::RichText::new(value).color(INK))
                    .wrap()
                    .selectable(true),
            );
        });
        ui.add_space(5.0);
    }

    fn block_title(ui: &mut Ui, title: &str) {
        ui.add_space(18.0);
        ui.label(
            egui::RichText::new(look::spaced(title))
                .font(theme::text(11.0, 600))
                .color(INK_NOTE),
        );
        ui.add_space(6.0);
    }

    fn play_key(&mut self, ui: &mut Ui, path: &str) {
        let (rect, response) = ui.allocate_exact_size(vec2(44.0, 44.0), Sense::click());
        let on = self.player.path.as_deref() == Some(path);
        look::raise(ui, rect, 22.0, if on { theme::RUBY } else { SHARK });
        let c = rect.center();
        if on {
            ui.painter()
                .rect_filled(Rect::from_center_size(c, vec2(9.0, 9.0)), CornerRadius::same(1), INK);
        } else {
            ui.painter().add(egui::Shape::convex_polygon(
                vec![c + vec2(-3.0, -5.0), c + vec2(5.5, 0.0), c + vec2(-3.0, 5.0)],
                INK,
                Stroke::NONE,
            ));
        }
        if response.on_hover_text("Play (Space)").clicked() {
            self.play(path);
        }
    }

    fn details(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        let song = if self.music {
            self.selected
                .and_then(|id| self.songs.iter().find(|s| s.id == id).cloned())
        } else {
            None
        };
        if self.details.is_none() && song.is_none() {
            ui.add_space(ui.available_height() * 0.3);
            ui.vertical_centered(|ui| {
                ui.label(
                    egui::RichText::new(if self.music {
                        "No Song Selected"
                    } else {
                        "No Sound Selected"
                    })
                    .font(theme::text(13.0, 600)),
                );
                ui.add_space(4.0);
                ui.label(egui::RichText::new("Select one to hear it.").color(INK_NOTE));
            });
            return;
        }
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .id_salt("details")
            .show(ui, |ui| {
                ui.spacing_mut().item_spacing.y = 0.0;
                if let Some(s) = song {
                    self.song_details(ui, &s);
                } else {
                    self.sound_details(ui, ctx);
                }
                ui.add_space(18.0);
            });
    }

    fn heading(ui: &mut Ui, title: &str, under: &str) {
        ui.add(
            egui::Label::new(egui::RichText::new(title).font(theme::text(17.0, 600)).color(INK))
                .wrap()
                .selectable(true),
        );
        ui.add_space(4.0);
        if !under.is_empty() {
            ui.add(egui::Label::new(egui::RichText::new(under).color(INK_NOTE)).wrap());
        }
        ui.add_space(14.0);
    }

    fn song_details(&mut self, ui: &mut Ui, s: &SongRow) {
        Self::heading(ui, &s.title, s.artist.as_deref().unwrap_or(""));
        self.play_key(ui, &s.path);
        Self::block_title(ui, "Song");
        Self::pair(ui, "Album", s.album.as_deref().unwrap_or(""));
        Self::pair(ui, "Length", &length(s.length));
        Self::pair(ui, "Tempo", &s.bpm.map(|b| format!("{b:.1} BPM")).unwrap_or_default());
        Self::pair(ui, "Key", s.key.as_deref().unwrap_or(""));
        Self::pair(ui, "Path", &s.path);
        ui.add_space(18.0);
        let half = (ui.available_width() - 8.0) / 2.0;
        if look::key(ui, KeyKind::Raised, "Show in Folder", true, Some(half)).clicked() {
            let _ = opener::reveal(&s.path);
        }
    }

    fn sound_details(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        let Some(d) = self.details.clone() else {
            return;
        };
        let s = &d["sound"];
        let text = |v: &Value| match v {
            Value::String(t) => t.clone(),
            Value::Number(n) => n.to_string(),
            _ => String::new(),
        };
        let id = s["id"].as_i64().or(self.selected).unwrap_or_default();
        let name = text(&s["name"]);
        let path = text(&s["path"]);
        Self::heading(ui, &name, &text(&s["file"]));
        self.play_key(ui, &path);

        Self::block_title(ui, "About");
        let category = s["category"]
            .as_str()
            .map(title_case)
            .unwrap_or_else(|| "Uncategorised".into());
        Self::pair(ui, "Category", &category);
        Self::pair(ui, "From", &text(&d["categorySource"]));
        Self::pair(ui, "Group", &text(&d["groupInfo"]["name"]));
        Self::pair(ui, "Description", &text(&d["description"]));
        Self::pair(ui, "Keywords", &text(&d["keywords"]));
        let library = d["vendorLibrary"]
            .as_str()
            .map(String::from)
            .unwrap_or_else(|| text(&s["library"]));
        Self::pair(ui, "Library", &library);
        Self::pair(ui, "Designer", &text(&d["designer"]));

        Self::block_title(ui, "Sound");
        Self::pair(ui, "Length", &length(s["length"].as_f64()));
        Self::pair(ui, "Format", &text(&s["format"]));
        Self::pair(
            ui,
            "Loudness",
            &s["loudness"]
                .as_f64()
                .map(|l| format!("{l:.1} LUFS"))
                .unwrap_or_default(),
        );
        Self::pair(
            ui,
            "Peak",
            &d["peak"].as_f64().map(|l| format!("{l:.1} dBFS")).unwrap_or_default(),
        );

        Self::block_title(ui, "File");
        Self::pair(ui, "Folder", &text(&s["folder"]));
        Self::pair(ui, "Path", &path);
        let n = |v: &Value| v.as_array().map_or(0, Vec::len);
        if n(&d["copies"]) > 0 {
            Self::pair(ui, "Copies", &n(&d["copies"]).to_string());
        }
        if n(&d["sameRecording"]) > 0 {
            Self::pair(ui, "Same recording", &n(&d["sameRecording"]).to_string());
        }

        // Two short keys side by side, the two long ones across the pane.
        ui.add_space(18.0);
        let width = ui.available_width();
        let half = (width - 8.0) / 2.0;
        let analysed = d["analysed"].as_bool().unwrap_or(false);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 8.0;
            let similar = look::key(ui, KeyKind::Raised, "Find Similar", analysed, Some(half));
            let similar = if analysed {
                similar
            } else {
                similar.on_hover_text("Analyse it first (or import an analysis file)")
            };
            if similar.clicked() {
                self.find_similar(ctx, id);
            }
            if look::key(ui, KeyKind::Raised, "Show in Folder", true, Some(half)).clicked() {
                let _ = opener::reveal(&path);
            }
        });
        ui.add_space(8.0);
        if look::key(ui, KeyKind::Raised, "Add to DaVinci Resolve", true, Some(width)).clicked() {
            self.add_to_resolve(ctx, id, &name);
        }
        ui.add_space(8.0);
        if look::key(ui, KeyKind::Raised, "Save as Timeline File", true, Some(width)).clicked() {
            self.save_timeline(id);
        }

        if let Some(found) = self.similar.clone() {
            Self::block_title(ui, "Similar");
            match found {
                Err(e) => {
                    ui.label(egui::RichText::new(e).color(INK_NOTE));
                }
                Ok(list) if list.is_empty() => {
                    ui.label(egui::RichText::new("Finding…").color(INK_NOTE));
                }
                Ok(list) => {
                    for r in list {
                        let (rect, response) = ui.allocate_exact_size(vec2(ui.available_width(), 26.0), Sense::click());
                        ui.painter()
                            .hline(rect.x_range(), rect.min.y + 0.5, Stroke::new(1.0, LINE));
                        if response.hovered() {
                            ui.painter().rect_filled(rect, 0.0, theme::HOVER);
                        }
                        let pct = r["similarity"]
                            .as_f64()
                            .map(|s| format!("{}%", (s * 100.0).round()))
                            .unwrap_or_default();
                        let pg = ui.painter().layout_no_wrap(pct, theme::text(13.0, 400), INK_NOTE);
                        let px = rect.max.x - pg.size().x;
                        ui.painter()
                            .galley(pos2(px, rect.center().y - pg.size().y / 2.0), pg, INK_NOTE);
                        let ng = look::elided(
                            ui,
                            r["name"].as_str().unwrap_or(""),
                            theme::text(13.0, 400),
                            INK,
                            px - rect.min.x - 8.0,
                        );
                        ui.painter()
                            .galley(pos2(rect.min.x, rect.center().y - ng.size().y / 2.0), ng, INK);
                        let rpath = r["path"].as_str().unwrap_or("").to_string();
                        if response.double_clicked() {
                            if let Some(rid) = r["id"].as_i64() {
                                self.select_sound(rid);
                            }
                        } else if response.clicked() {
                            self.play(&rpath);
                        }
                    }
                }
            }
        }
    }

    // MARK: dialogs

    fn dialogs(&mut self, ctx: &egui::Context) {
        let Some(dialog) = &self.dialog else { return };
        let (text, remove) = match dialog {
            Dialog::Remove(id, name) => (
                format!("Remove “{name}” from Earmark? Its files stay where they are."),
                Some(*id),
            ),
            Dialog::Message(t) => (t.clone(), None),
        };
        let mut close = false;
        let mut confirmed = false;
        egui::Modal::new(egui::Id::unique("dialog"))
            .frame(
                Frame::new()
                    .fill(SHARK)
                    .stroke(Stroke::new(1.0, LINE))
                    .corner_radius(14)
                    .inner_margin(Margin::same(22))
                    .shadow(ctx.global_style().visuals.window_shadow),
            )
            .show(ctx, |ui| {
                ui.set_max_width(380.0);
                ui.add(egui::Label::new(egui::RichText::new(text).color(INK)).wrap());
                ui.add_space(18.0);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = 8.0;
                    if remove.is_some() {
                        if look::key(ui, KeyKind::Primary, "Remove", true, None).clicked() {
                            confirmed = true;
                        }
                        if look::key(ui, KeyKind::Raised, "Cancel", true, None).clicked() {
                            close = true;
                        }
                    } else if look::key(ui, KeyKind::Primary, "OK", true, None).clicked() {
                        close = true;
                    }
                });
            });
        if ctx.input(|i| i.key_pressed(Key::Escape)) {
            close = true;
        }
        if confirmed && let Some(id) = remove {
            if let Err(e) = self.back.remove_library(id) {
                self.dialog = Some(Dialog::Message(e));
                return;
            }
            if self.scope == Scope::Library(id) {
                self.choose(Scope::All);
            }
            self.refresh();
            close = true;
        }
        if close {
            self.dialog = None;
        }
    }

    // MARK: checking

    fn shot(&mut self, ctx: &egui::Context) {
        let Some(shot) = self.shot.as_mut() else {
            return;
        };
        shot.frames += 1;
        if shot.frames == 2 {
            let (music, map, select) = (shot.music, shot.map, shot.select_first);
            if music {
                self.set_section(true);
            }
            if map {
                self.map_view = true;
            }
            if select {
                self.dirty = false;
                self.reload();
                let first = if self.music {
                    self.songs.first().map(|s| s.id)
                } else {
                    self.rows.first().map(|r| r.id)
                };
                if let Some(id) = first {
                    self.select_sound(id);
                }
            }
        }
        let shot = self.shot.as_mut().expect("checked above");
        let waiting = self.map_view && self.map.is_none() && self.map_problem.is_none();
        if shot.frames > 12 && !shot.asked && !waiting {
            shot.asked = true;
            let path = shot.path.clone();
            let ctx2 = ctx.clone();
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(
                move |image| {
                    let [w, h] = image.size;
                    let bytes: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_array()).collect();
                    if let Some(buffer) = image::RgbaImage::from_raw(w as u32, h as u32, bytes) {
                        let _ = buffer.save(&path);
                    }
                    ctx2.send_viewport_cmd(egui::ViewportCommand::Close);
                    ctx2.request_repaint();
                },
            )));
        }
        ctx.request_repaint();
    }
}

impl eframe::App for EarmarkApp {
    fn ui(&mut self, root: &mut Ui, _frame: &mut eframe::Frame) {
        let ctx = &root.ctx().clone();
        self.take_events();
        self.shot(ctx);
        if self.dirty {
            self.reload();
        }
        self.keys(ctx);
        let line = Stroke::new(1.0, LINE);
        let fill = Frame::new().fill(SHARK);

        egui::Panel::top("header")
            .exact_size(58.0)
            .show_separator_line(false)
            .frame(fill.inner_margin(Margin::symmetric(18, 0)))
            .show(root, |ui| self.header(ui));
        egui::Panel::bottom("status")
            .exact_size(29.0)
            .frame(fill.inner_margin(Margin::symmetric(18, 0)))
            .show(root, |ui| {
                ui.horizontal_centered(|ui| {
                    let counts = format!(
                        "{} sounds · {} songs · {} analysed",
                        number(self.snap.sounds),
                        number(self.snap.songs),
                        number(self.snap.analysed)
                    );
                    ui.label(egui::RichText::new(counts).font(theme::text(12.0, 400)).color(INK_NOTE));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        ui.label(
                            egui::RichText::new(&self.activity)
                                .font(theme::text(12.0, 400))
                                .color(INK_NOTE),
                        );
                    });
                });
            });
        egui::Panel::left("sidebar")
            .exact_size(240.0)
            .resizable(false)
            .frame(fill.inner_margin(Margin {
                left: 10,
                right: 10,
                top: 10,
                bottom: 20,
            }))
            .show(root, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| self.sidebar(ui, ctx));
            });
        egui::Panel::right("details")
            .exact_size(340.0)
            .resizable(false)
            .frame(fill.inner_margin(Margin {
                left: 18,
                right: 18,
                top: 10,
                bottom: 0,
            }))
            .show(root, |ui| self.details(ui, ctx));
        egui::CentralPanel::no_frame()
            .frame(fill.stroke(Stroke::NONE))
            .show(root, |ui| {
                let nothing = !self.snap.libraries.iter().any(|l| l.music == self.music);
                // The toolbar.
                let bar = Rect::from_min_size(ui.max_rect().min, vec2(ui.available_width(), 50.0));
                ui.scope_builder(egui::UiBuilder::new().max_rect(bar.shrink2(vec2(14.0, 10.0))), |ui| {
                    ui.horizontal_centered(|ui| {
                        ui.spacing_mut().item_spacing.x = 8.0;
                        if !self.music
                            && let Some(i) =
                                look::segments(ui, &["List", "Map"], usize::from(self.map_view), 30.0, 14.0)
                        {
                            self.map_view = i == 1;
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if look::key(ui, KeyKind::Raised, "Rescan All Folders", true, None).clicked() {
                                let ids = self.back.library_ids();
                                self.back.start_scan(ids, self.tell(ctx));
                            }
                            if look::key(ui, KeyKind::Raised, "Import Analysis…", true, None).clicked() {
                                self.import();
                            }
                            let label = if self.stopping {
                                "Stopping…"
                            } else if self.analysing {
                                "Stop Analysis"
                            } else {
                                "Analyse"
                            };
                            if look::key(ui, KeyKind::Raised, label, true, None).clicked() {
                                self.analyse(ctx);
                            }
                        });
                    });
                });
                ui.advance_cursor_after_rect(bar);
                if nothing {
                    self.empty(ui, ctx);
                } else if self.map_view && !self.music {
                    self.map(ui, ctx);
                } else {
                    self.list(ui);
                }
            });
        // The thin lines between the columns.
        let screen = ctx.content_rect();
        let painter = ctx.layer_painter(egui::LayerId::new(egui::Order::Foreground, egui::Id::unique("lines")));
        let top = screen.min.y + 58.0;
        let bottom = screen.max.y - 29.0;
        painter.vline(screen.min.x + 240.5, top..=bottom, line);
        painter.vline(screen.max.x - 340.5, top..=bottom, line);
        painter.hline(screen.x_range(), bottom + 0.5, line);
        self.dialogs(ctx);
        if self.player.path.is_some() || self.scanning_or_analysing() {
            ctx.request_repaint_after(Duration::from_millis(200));
        }
    }
}

impl EarmarkApp {
    fn scanning_or_analysing(&self) -> bool {
        self.analysing || self.back.scanning.load(std::sync::atomic::Ordering::Relaxed)
    }
}
