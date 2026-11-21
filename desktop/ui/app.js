// Earmark's window for Windows and Linux. Everything it shows comes from the Rust side
// (src-tauri/src/main.rs); this file only draws it and passes on what the person does.

const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args);
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

const PAGE = 300;
const state = {
  section: "sounds", // or "music"
  view: "list", // or "map"
  scope: { kind: "all" }, // all | library | duplicates | category | sub
  query: "",
  rows: [],
  total: 0,
  loading: false,
  selected: null,
  snap: null,
  expanded: new Set(),
  map: null,
  playing: null,
};

// MARK: formatting

function length(seconds) {
  if (seconds == null) return "";
  if (seconds < 60) return seconds.toFixed(1) + " s";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}
const number = (n) => (n ?? 0).toLocaleString("en-US");

// MARK: the sidebar and the status bar

async function refresh() {
  state.snap = await invoke("snapshot");
  drawSidebar();
  drawStatus();
  const nothing = state.snap.libraries.length === 0;
  $("empty").hidden = !nothing;
  $("list").hidden = nothing || state.view !== "list";
  $("map").hidden = nothing || state.view !== "map";
  if (!nothing) await reload();
}

function sideItem(label, count, on, onclick, extra) {
  const b = el("button", "side-item" + (on ? " on" : "") + (extra ? " " + extra : ""));
  b.append(el("span", "label", label), el("span", "count", count === "" ? "" : number(count)));
  b.onclick = onclick;
  return b;
}

function scopeIs(kind, value) {
  return state.scope.kind === kind && (value === undefined || state.scope.value === value);
}

function drawSidebar() {
  const snap = state.snap;
  const music = state.section === "music";
  $("all-sounds").firstChild.textContent = music ? "All Songs" : "All Sounds";
  $("all-count").textContent = number(music ? snap.songs : snap.sounds);
  $("all-sounds").classList.toggle("on", scopeIs("all"));
  $("all-sounds").onclick = () => choose({ kind: "all" });
  $("duplicates").parentElement.hidden = music;
  $("dup-count").textContent = number(snap.duplicates);
  $("duplicates").classList.toggle("on", scopeIs("duplicates"));
  $("duplicates").onclick = () => choose({ kind: "duplicates" });
  $("add-library").textContent = music ? "Add Music Folder…" : "Add Library…";

  const libs = $("libraries");
  libs.replaceChildren();
  for (const lib of snap.libraries.filter((l) => (l.kind === "music") === music)) {
    const item = sideItem(lib.name, lib.count, scopeIs("library", lib.id), () => choose({ kind: "library", value: lib.id }),
      lib.online ? "" : "offline");
    item.title = lib.online ? lib.path : lib.path + " (not connected)";
    item.oncontextmenu = (e) => {
      e.preventDefault();
      if (confirm(`Remove “${lib.name}” from Earmark? Its files stay where they are.`)) {
        invoke("remove_library", { id: lib.id }).then(refresh);
      }
    };
    libs.append(item);
  }

  const cats = $("categories");
  cats.replaceChildren();
  cats.parentElement.querySelectorAll(".side-title")[1].hidden = music;
  if (music) return;
  for (const c of snap.categories) {
    const open = state.expanded.has(c.name);
    const item = sideItem("", c.count, scopeIs("category", c.name), () => choose({ kind: "category", value: c.name }));
    const label = item.firstChild;
    // A chevron drawn, not a character: Tessel has no arrows.
    const arrow = el("span", "disclosure" + (open ? " open" : ""));
    arrow.innerHTML = '<svg viewBox="0 0 10 10" width="9" height="9"><path d="M3 1.5 6.5 5 3 8.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    arrow.onclick = (e) => {
      e.stopPropagation();
      open ? state.expanded.delete(c.name) : state.expanded.add(c.name);
      drawSidebar();
    };
    const name = el("span", "label", titleCase(c.name));
    label.replaceWith(arrow, name);
    cats.append(item);
    if (open) {
      for (const s of c.subcategories) {
        cats.append(sideItem(titleCase(s.label), s.count, scopeIs("sub", s.catId), () => choose({ kind: "sub", value: s.catId }), "sub"));
      }
    }
  }
}

function titleCase(text) {
  return text.toLowerCase().replace(/(^|[\s/&-])(\p{L})/gu, (m, a, b) => a + b.toUpperCase());
}

function drawStatus() {
  const snap = state.snap;
  $("status-counts").textContent = `${number(snap.sounds)} sounds · ${number(snap.songs)} songs · ${number(snap.analysed)} analysed`;
  if (!snap.scanning && !$("status-activity").dataset.keep) $("status-activity").textContent = "";
}

// MARK: the list

function choose(scope) {
  state.scope = scope;
  state.selected = null;
  drawSidebar();
  drawDetails(null);
  state.map = null;
  reload();
}

async function reload() {
  state.rows = [];
  state.total = 0;
  $("rows").scrollTop = 0;
  drawHead();
  if (state.section === "music") {
    state.rows = await invoke("songs", { query: state.query });
    state.total = state.rows.length;
    drawRows();
    return;
  }
  if (state.view === "map") return drawMap();
  await more();
}

function filter() {
  const s = state.scope;
  return {
    query: state.query || null,
    category: s.kind === "category" || s.kind === "sub" ? s.value : null,
    groupId: s.kind === "group" ? s.value : null,
    libraryId: s.kind === "library" ? s.value : null,
    duplicates: s.kind === "duplicates",
  };
}

async function more() {
  if (state.loading || (state.total && state.rows.length >= state.total)) return;
  state.loading = true;
  const page = await invoke("sounds", { ...filter(), offset: state.rows.length, limit: PAGE });
  state.total = page.total;
  state.rows.push(...page.rows);
  state.loading = false;
  drawRows();
}

function drawHead() {
  const head = $("list-head");
  head.replaceChildren();
  const music = state.section === "music";
  head.className = "row head" + (music ? " music" : "");
  const names = music ? ["", "Title", "Artist", "Album", "Length", "BPM", "Key"] : ["", "Name", "Category", "Length", "Folder", "Format"];
  for (const n of names) head.append(el("span", "", n));
}

function drawRows() {
  const box = $("rows");
  box.replaceChildren();
  const music = state.section === "music";
  for (const r of state.rows) {
    const row = el("div", "row" + (music ? " music" : "") + (state.selected === r.id ? " on" : ""));
    const mark = el("span", "mark", state.playing === r.path ? "●" : "");
    if (music) {
      row.append(mark, el("span", "", r.title), el("span", "muted", r.artist ?? ""), el("span", "muted", r.album ?? ""),
        el("span", "muted", length(r.length)), el("span", "muted", r.bpm ? r.bpm.toFixed(1) : ""), el("span", "muted", r.key ?? ""));
    } else {
      row.append(mark, el("span", "", r.name), el("span", "muted", titleCase(r.category)), el("span", "muted", length(r.length)),
        el("span", "muted", r.folder), el("span", "muted", r.format));
    }
    row.onclick = () => select(r);
    row.ondblclick = () => play(r.path);
    box.append(row);
  }
  if (!state.rows.length) box.append(el("div", "note", state.query ? "  No sounds match." : "").parentElement ?? el("div"));
}

$("rows").addEventListener("scroll", () => {
  const box = $("rows");
  if (state.section === "sounds" && box.scrollTop + box.clientHeight > box.scrollHeight - 400) more();
});

document.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT") return;
  if (e.key === " ") {
    e.preventDefault();
    const r = state.rows.find((x) => x.id === state.selected);
    if (r) play(r.path);
  } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    const i = state.rows.findIndex((x) => x.id === state.selected);
    const next = state.rows[Math.max(0, Math.min(state.rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))];
    if (next) select(next);
  }
});

// MARK: details

async function select(r) {
  state.selected = r.id;
  drawRows();
  if (state.section === "music") return drawSong(r);
  try {
    drawDetails(await invoke("sound", { id: r.id }));
  } catch (err) {
    drawDetails(null);
  }
}

function pair(box, label, value) {
  if (value == null || value === "") return;
  const p = el("div", "pair");
  p.append(el("span", "", label), el("span", "", String(value)));
  box.append(p);
}

function block(title) {
  const b = el("div", "block");
  b.append(el("div", "block-title", title));
  return b;
}

function drawDetails(d) {
  $("details-empty").hidden = !!d;
  const body = $("details-body");
  body.hidden = !d;
  body.replaceChildren();
  if (!d) return;
  const s = d.sound;
  const playKey = el("button", "play" + (state.playing === s.path ? " on" : ""), state.playing === s.path ? "■" : "▶");
  playKey.onclick = () => play(s.path);
  const top = el("div", "actions");
  top.append(playKey);
  body.append(el("h2", "", s.name), el("div", "note", s.file), top);

  const about = block("About");
  pair(about, "Category", s.category ? titleCase(s.category) : "Uncategorised");
  pair(about, "From", d.categorySource);
  pair(about, "Group", d.groupInfo?.name);
  pair(about, "Description", d.description);
  pair(about, "Keywords", d.keywords);
  pair(about, "Library", d.vendorLibrary ?? s.library);
  pair(about, "Designer", d.designer);
  body.append(about);

  const sound = block("Sound");
  pair(sound, "Length", length(s.length));
  pair(sound, "Format", s.format);
  pair(sound, "Loudness", s.loudness != null ? s.loudness.toFixed(1) + " LUFS" : null);
  pair(sound, "Peak", d.peak != null ? d.peak.toFixed(1) + " dBFS" : null);
  body.append(sound);

  const file = block("File");
  pair(file, "Folder", s.folder);
  pair(file, "Path", s.path);
  if (d.copies?.length) pair(file, "Copies", d.copies.length);
  if (d.sameRecording?.length) pair(file, "Same recording", d.sameRecording.length);
  body.append(file);

  const keys = el("div", "actions");
  const similar = el("button", "key", "Find Similar");
  similar.disabled = !d.analysed;
  similar.title = d.analysed ? "" : "Analyse it first (or import an analysis file)";
  similar.onclick = () => showSimilar(s);
  const resolve = el("button", "key", "Add to DaVinci Resolve");
  resolve.onclick = () => addToResolve(s);
  const timeline = el("button", "key", "Save as Timeline File");
  timeline.onclick = () => saveTimeline([s.id]);
  const reveal = el("button", "key", "Show in Folder");
  reveal.onclick = () => invoke("reveal", { path: s.path });
  keys.append(similar, resolve, timeline, reveal);
  body.append(keys);
  const list = el("div", "block");
  list.id = "similar";
  body.append(list);
}

function drawSong(r) {
  $("details-empty").hidden = true;
  const body = $("details-body");
  body.hidden = false;
  body.replaceChildren();
  const playKey = el("button", "play" + (state.playing === r.path ? " on" : ""), state.playing === r.path ? "■" : "▶");
  playKey.onclick = () => play(r.path);
  const top = el("div", "actions");
  top.append(playKey);
  body.append(el("h2", "", r.title), el("div", "note", r.artist ?? ""), top);
  const b = block("Song");
  pair(b, "Album", r.album);
  pair(b, "Length", length(r.length));
  pair(b, "Tempo", r.bpm ? r.bpm.toFixed(1) + " BPM" : null);
  pair(b, "Key", r.key);
  pair(b, "Path", r.path);
  body.append(b);
  const reveal = el("button", "key", "Show in Folder");
  reveal.onclick = () => invoke("reveal", { path: r.path });
  const keys = el("div", "actions");
  keys.append(reveal);
  body.append(keys);
}

async function showSimilar(s) {
  const box = $("similar");
  box.replaceChildren(el("div", "block-title", "Similar"));
  try {
    const found = await invoke("similar", { id: s.id });
    for (const r of found.similar) {
      const item = el("button", "similar-item");
      item.append(el("span", "", r.name), el("span", "note", r.similarity != null ? Math.round(r.similarity * 100) + "%" : ""));
      item.onclick = () => play(r.path);
      item.ondblclick = () => select({ id: r.id, path: r.path });
      box.append(item);
    }
  } catch (err) {
    box.append(el("div", "note", String(err)));
  }
}

async function addToResolve(s) {
  activity(`Adding “${s.name}” to DaVinci Resolve…`);
  try {
    const added = await invoke("add_to_resolve", { id: s.id });
    const placed = added.items?.[0];
    activity(placed?.ok ? `Added to “${added.timeline}”, track A${placed.track}` : placed?.problem ?? "Resolve didn't place it.", 5000);
  } catch (err) {
    activity("", 0);
    alert(String(err));
  }
}

async function saveTimeline(ids) {
  try {
    const saved = await invoke("save_timeline", { ids, frameRate: "25" });
    activity(`Saved ${saved.path}`, 6000);
  } catch (err) {
    alert(String(err));
  }
}

function activity(text, clearAfter) {
  const a = $("status-activity");
  a.textContent = text;
  a.dataset.keep = text ? "1" : "";
  if (clearAfter) setTimeout(() => {
    if (a.textContent === text) {
      a.textContent = "";
      a.dataset.keep = "";
    }
  }, clearAfter);
}

// MARK: playing

const player = $("player");
function play(path) {
  if (state.playing === path && !player.paused) {
    player.pause();
    state.playing = null;
  } else {
    player.src = tauri.core.convertFileSrc(path);
    player.play().catch((err) => activity("Couldn't play it: " + err.message, 5000));
    state.playing = path;
  }
  drawRows();
  const key = document.querySelector(".details .play");
  if (key) {
    key.classList.toggle("on", state.playing != null);
    key.textContent = state.playing ? "■" : "▶";
  }
}
player.onended = () => {
  state.playing = null;
  drawRows();
  const key = document.querySelector(".details .play");
  if (key) {
    key.classList.remove("on");
    key.textContent = "▶";
  }
};

// MARK: the map

const COLORS = ["#d41101", "#e5a23a", "#5aa9e6", "#7bc47f", "#b48ead", "#e07a5f", "#9aa5b1"];

async function drawMap() {
  const note = $("map-note");
  const canvas = $("map-canvas");
  const scope = state.scope.kind === "category" || state.scope.kind === "sub" ? state.scope.value : null;
  if (!state.map) {
    note.textContent = "Making the map…";
    try {
      state.map = await invoke("sound_map", { category: scope });
    } catch (err) {
      note.textContent = String(err);
      return;
    }
  }
  const points = state.map.points;
  note.textContent = points.length ? `${number(points.length)} analysed sounds` : "No analysed sounds here yet.";
  const counts = {};
  for (const p of points) counts[p[3]] = (counts[p[3]] ?? 0) + 1;
  const order = Object.keys(counts).sort((a, b) => counts[b] - counts[a]);
  const color = (c) => COLORS[Math.min(order.indexOf(c), COLORS.length - 1)];
  const ratio = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  canvas.width = w * ratio;
  canvas.height = h * ratio;
  const g = canvas.getContext("2d");
  g.scale(ratio, ratio);
  g.clearRect(0, 0, w, h);
  const pad = 30, size = Math.min(w, h) - 2 * pad;
  const ox = (w - size) / 2, oy = (h - size) / 2;
  const at = (p) => [ox + p[1] * size, oy + p[2] * size];
  for (const p of points) {
    const [x, y] = at(p);
    g.fillStyle = color(p[3]);
    g.globalAlpha = 0.75;
    g.fillRect(x - 1.2, y - 1.2, 2.4, 2.4);
  }
  g.globalAlpha = 1;
  canvas.onclick = (e) => {
    const r = canvas.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    let best = null, bestD = 64;
    for (const p of points) {
      const [x, y] = at(p);
      const d = (x - mx) ** 2 + (y - my) ** 2;
      if (d < bestD) { bestD = d; best = p; }
    }
    if (best) select({ id: best[0] }).then(() => {
      const path = document.querySelector(".details .pair:last-child span:last-child");
    });
  };
}
window.addEventListener("resize", () => state.view === "map" && state.map && drawMap());

// MARK: the header and keys

function section(name) {
  state.section = name;
  $("tab-sounds").classList.toggle("on", name === "sounds");
  $("tab-music").classList.toggle("on", name === "music");
  $("view-list").parentElement.hidden = name === "music";
  if (name === "music") setView("list", false);
  state.scope = { kind: "all" };
  state.selected = null;
  drawDetails(null);
  drawSidebar();
  reload();
}
$("tab-sounds").onclick = () => section("sounds");
$("tab-music").onclick = () => section("music");

function setView(view, load = true) {
  state.view = view;
  $("view-list").classList.toggle("on", view === "list");
  $("view-map").classList.toggle("on", view === "map");
  $("list").hidden = view !== "list";
  $("map").hidden = view !== "map";
  if (load) reload();
}
$("view-list").onclick = () => setView("list");
$("view-map").onclick = () => setView("map");

let typing;
$("search").addEventListener("input", () => {
  clearTimeout(typing);
  typing = setTimeout(() => {
    state.query = $("search").value.trim();
    reload();
  }, 180);
});

async function addLibrary(kind) {
  await invoke("add_library", { kind });
  refresh();
}
$("add-library").onclick = () => addLibrary(state.section === "music" ? "music" : "sounds");
$("empty-sounds").onclick = () => addLibrary("sounds");
$("empty-music").onclick = () => addLibrary("music");
$("rescan").onclick = () => invoke("rescan", { id: null });

async function importAnalysis() {
  try {
    const report = await invoke("import_analysis");
    if (report) {
      alert(`Imported: ${number(report.soundsMatched)} sounds matched, ${number(report.facts)} loudness values, ` +
        `${number(report.embeddings)} sound vectors, ${number(report.songAnalyses)} song analyses.`);
      refresh();
    }
  } catch (err) {
    alert("Couldn't import it: " + err);
  }
}
$("import").onclick = importAnalysis;

// Analysing: loudness, the models' vectors (when installed), the groups. The key stops it.
let analysing = false;
$("analyse").onclick = async () => {
  if (analysing) {
    invoke("stop_analysis");
    $("analyse").textContent = "Stopping…";
    return;
  }
  analysing = true;
  $("analyse").textContent = "Stop Analysis";
  activity("Analysing…");
  invoke("analyse");
};
tauri.event.listen("analysis", (e) => {
  const p = e.payload;
  activity(`${p.what}: ${number(p.done)} of ${number(p.total)}`);
});
tauri.event.listen("analysed", async (e) => {
  analysing = false;
  $("analyse").textContent = "Analyse";
  let said = e.payload;
  if (said.includes("no models in")) {
    const folder = await invoke("models_folder");
    said += ` To add them, put CLAPAudio.onnx and the PEAV folder in ${folder}.`;
  }
  activity(said, 15000);
  state.map = null;
  refresh();
});
$("empty-import").onclick = importAnalysis;

tauri.event.listen("progress", (e) => {
  const p = e.payload;
  $("status-activity").textContent = `Reading “${p.name}”: ${number(p.done)} of ${number(p.total)} files`;
});
tauri.event.listen("scanned", (e) => {
  $("status-activity").textContent = e.payload ? "Couldn't read it: " + e.payload : "";
  refresh();
});

refresh();
