//! What the server tells agents: its instructions and its tools, as clients list them.

use rmcp::model::{Tool, ToolAnnotations};
use serde_json::{Map, Value, json};
use std::sync::Arc;

pub const INSTRUCTIONS: &str = "Earmark knows the owner's sound-effect libraries: every sound's UCS category (from its file, the \
owner's choices or Earmark's guesses), similarity groups inside each subcategory (named by what \
they sound like), duplicates, loudness, and which sounds sound alike. Find sounds with \
search_sounds (words, category, group, length) and find_similar, look closer with get_sound, \
then put them on the timeline open in DaVinci Resolve with add_to_resolve (check resolve_status \
first; use preview to see where they'd go). When Resolve Studio can't be reached (the free \
Resolve has no scripting) or the owner uses Final Cut Pro, save_timeline_file writes a timeline \
file they import instead. Sound ids come from search_sounds. Lengths and ranges are in seconds. \
Earmark never changes the sound files.";

/// Where save_timeline_file saves, as its description says it.
const TIMELINE_FOLDER: &str = if cfg!(target_os = "macos") {
    "~/Movies/Earmark"
} else {
    "the Earmark folder in Videos"
};

fn schema(properties: Value, required: &[&str]) -> Arc<Map<String, Value>> {
    let mut s = Map::new();
    s.insert("type".into(), json!("object"));
    s.insert("properties".into(), properties);
    if !required.is_empty() {
        s.insert("required".into(), json!(required));
    }
    Arc::new(s)
}

fn prop(kind: &str, description: &str) -> Value {
    json!({"type": kind, "description": description})
}

fn read_only(title: &str) -> ToolAnnotations {
    ToolAnnotations::with_title(title)
        .read_only(true)
        .open_world(false)
}

fn changes(title: &str, idempotent: bool) -> ToolAnnotations {
    ToolAnnotations::with_title(title)
        .read_only(false)
        .destructive(false)
        .idempotent(idempotent)
        .open_world(false)
}

fn tool(
    name: &'static str,
    description: String,
    input: Arc<Map<String, Value>>,
    annotations: ToolAnnotations,
) -> Tool {
    let title = annotations.title.clone().unwrap_or_default();
    Tool::new(name, description, input)
        .with_title(title)
        .with_annotations(annotations)
}

pub fn definitions() -> Vec<Tool> {
    let sound_id = prop("integer", "The sound's id.");
    vec![
        tool(
            "library_overview",
            "The sound libraries: their sounds (online or not), how many are analysed, and every category with \
             its subcategories (CatIDs), sound counts and number of similarity groups. A good first call."
                .into(),
            schema(json!({}), &[]),
            read_only("Library overview"),
        ),
        tool(
            "search_sounds",
            "Finds sounds. `query`: words that must all appear in the sound's name, description, keywords, \
             category, library or folder (e.g. \"door wood slam\"). Filters: `category` (a category like FOOTSTEPS, \
             a subcategory like \"Footsteps / Human\", or a CatID like FEETHmn), `group_id` (from list_groups), \
             `library_id`, `min_length`/`max_length` in seconds, `source` of the category (file, folder, guess, owner, \
             none). Sounds with the words in their name come first. Returns `total` and up to `limit` rows (default \
             25, at most 200) from `offset`."
                .into(),
            schema(
                json!({
                    "query": prop("string", "Words the sound must contain."),
                    "category": prop("string", "Category, \"Category / Subcategory\" or CatID."),
                    "group_id": prop("integer", "A similarity group's id (list_groups)."),
                    "library_id": prop("integer", "A library's id (library_overview)."),
                    "min_length": prop("number", "Shortest length, seconds."),
                    "max_length": prop("number", "Longest length, seconds."),
                    "source": prop("string", "Where the category comes from: file, folder, guess, owner or none."),
                    "limit": prop("integer", "Rows to return, 1–200 (default 25)."),
                    "offset": prop("integer", "Rows to skip, for the next page."),
                }),
                &[],
            ),
            read_only("Search sounds"),
        ),
        tool(
            "get_sound",
            "Everything about one sound: name, category and where it came from, similarity group and the words \
             its files share, description and keywords, length, format, loudness (LUFS) and peak, whether it's \
             analysed and online, other formats, byte-identical copies and the same recording in other files."
                .into(),
            schema(
                json!({"sound_id": prop("integer", "The sound's id (search_sounds).")}),
                &["sound_id"],
            ),
            read_only("Sound details"),
        ),
        tool(
            "find_similar",
            "The sounds that sound most like this one (Earmark's audio embeddings, cosine similarity 0–1), \
             best first, as the app's Find Similar Sounds. The sound must be analysed."
                .into(),
            schema(
                json!({"sound_id": sound_id, "limit": prop("integer", "How many, 1–100 (default 20).")}),
                &["sound_id"],
            ),
            read_only("Find similar sounds"),
        ),
        tool(
            "list_groups",
            "A subcategory's similarity groups: sounds that sound alike, named from what they sound like \
             (e.g. \"Long · Splashy · Watery\") with words their files share (\"#sewer\"), and how many sounds each \
             has. Use a group's id with search_sounds."
                .into(),
            schema(
                json!({"subcategory": prop("string", "A CatID (FEETHmn) or \"Category / Subcategory\".")}),
                &["subcategory"],
            ),
            read_only("Similarity groups"),
        ),
        tool(
            "show_in_earmark",
            "Opens Earmark on this sound, selected in its list, so the owner can hear it.".into(),
            schema(json!({"sound_id": sound_id}), &["sound_id"]),
            changes("Show in Earmark", true),
        ),
        tool(
            "resolve_status",
            "Whether DaVinci Resolve Studio can be reached, and its open project and timeline: frame rate, start \
             timecode, playhead, end, and the audio tracks (index, name, kind, locked, clips, where the last clip ends)."
                .into(),
            schema(json!({}), &[]),
            read_only("DaVinci Resolve status"),
        ),
        tool(
            "add_to_resolve",
            "Puts sounds on the timeline open in DaVinci Resolve Studio, as cuts of the original files (nothing \
             is rendered or copied), audio only, one after another. Each item: `sound_id`; `start`/`end` in seconds \
             into the file for part of it (default all); `at`, where on the timeline: seconds from the timeline's \
             start (number) or a timecode \"HH:MM:SS:FF\" (default the playhead); `track`: \"new\" (default: a track \
             named Earmark, a new one if none is free there), \"free\" (the first free audio track), or a track number. \
             Cuts are frame-accurate. `preview: true` says where each would go without placing anything. Returns \
             each item's track and timecodes, or the problem."
                .into(),
            schema(
                json!({
                    "items": {
                        "type": "array",
                        "description": "The sounds to place.",
                        "items": schema(
                            json!({
                                "sound_id": sound_id,
                                "start": prop("number", "Seconds into the file where the cut starts."),
                                "end": prop("number", "Seconds into the file where the cut ends."),
                                "at": {"description": "Seconds from the timeline's start, or a timecode \"HH:MM:SS:FF\".",
                                       "type": ["number", "string"]},
                                "track": {"description": "\"new\", \"free\" or an audio track number.",
                                          "type": ["string", "integer"]},
                            }),
                            &["sound_id"],
                        ),
                    },
                    "preview": prop("boolean", "Only say where they'd go."),
                }),
                &["items"],
            ),
            changes("Add to the Resolve timeline", false),
        ),
        tool(
            "save_timeline_file",
            format!(
                "Writes the sounds into a timeline file (FCPXML 1.10) that the free DaVinci Resolve (File ▸ Import ▸ \
                 Timeline…), Resolve Studio and Final Cut Pro (File ▸ Import ▸ XML…) import as a new timeline, as cuts of the \
                 original files. Each item: `sound_id`; `start`/`end` in seconds into the file (default all); `at`, seconds \
                 from the timeline's start (default: where the previous one ends). Each goes on the first track free at its \
                 time. Cuts are whole frames. `frame_rate`: one of 23.976, 24, 25, 29.97, 29.97 DF, 30, 50, 59.94, 59.94 DF, \
                 60 (default 25; use the owner's timeline's). Saved in {TIMELINE_FOLDER} as `name`.fcpxml (never overwrites). \
                 Returns the path and each item's track and timecodes."
            ),
            schema(
                json!({
                    "items": {
                        "type": "array",
                        "description": "The sounds to put in the file.",
                        "items": schema(
                            json!({
                                "sound_id": sound_id,
                                "start": prop("number", "Seconds into the file where the cut starts."),
                                "end": prop("number", "Seconds into the file where the cut ends."),
                                "at": prop("number", "Seconds from the timeline's start."),
                            }),
                            &["sound_id"],
                        ),
                    },
                    "frame_rate": prop("string", "The timeline's frame rate, e.g. \"25\" or \"29.97 DF\"."),
                    "start_timecode": prop("string", "The timeline's start timecode (default 01:00:00:00)."),
                    "name": prop("string", "The file's and timeline's name (default \"Earmark sounds\")."),
                }),
                &["items"],
            ),
            changes("Save a timeline file", false),
        ),
    ]
}
