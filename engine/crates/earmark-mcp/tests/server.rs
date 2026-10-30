//! The MCP server, through the SDK's own client over an in-memory pipe: what an agent sees.

use earmark_core::analysis::groups::Name;
use earmark_core::metadata::AudioTechnical;
use earmark_core::normalize::{MetadataField, NormalizedMetadata};
use earmark_core::scan::ScannedSound;
use earmark_db::{LibraryDatabase, SoundFacts};
use earmark_mcp::{EarmarkServer, EarmarkTools, Outside};
use earmark_resolve::{Added, At, Failure, Item, Placement, Track};
use rmcp::model::{CallToolRequestParams, CallToolResponse, ClientConfig, JsonObject};
use rmcp::service::RunningService;
use rmcp::{RoleClient, ServiceExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// What the server sent out of the process.
#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<String>>,
    items: Mutex<Vec<Item>>,
    preview: Mutex<bool>,
}

fn temp_folder() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!("earmark-mcp-{}-{n}", std::process::id()));
    std::fs::create_dir_all(root.join("Pack/Doors")).unwrap();
    root
}

/// A library of four sounds (files on disk, empty): two byte-identical copies, a long ambience,
/// a short door slam, with categories, a group and loudness.
fn library(root: &Path) -> (LibraryDatabase, HashMap<String, i64>) {
    let db = LibraryDatabase::open(None, false).unwrap();
    let r = root.to_string_lossy().into_owned();
    let lib = db.add_library("sounds", &r, None).unwrap();
    let scanned = |path: &str, fingerprint: &str, seconds: f64, description: &str| {
        let file = root.join(path);
        std::fs::write(&file, b"").unwrap();
        let mut m = NormalizedMetadata::default();
        m.fields
            .insert(MetadataField::Description, description.to_string());
        ScannedSound {
            path: file.to_string_lossy().into_owned(),
            file_size: 1,
            modified: 1_700_000_000.0,
            fingerprint: Some(fingerprint.to_string()),
            technical: AudioTechnical {
                sample_rate: Some(48000.0),
                channels: Some(2),
                bits_per_sample: Some(24),
                duration: Some(seconds),
            },
            metadata: m,
            warnings: Vec::new(),
        }
    };
    db.replace_sounds(
        lib.id,
        &r,
        &[
            scanned(
                "Pack/Doors/Door Wood Slam 01.wav",
                "a",
                1.2,
                "heavy wooden door slam",
            ),
            scanned(
                "Pack/Doors/Door Wood Slam 01 copy.wav",
                "a",
                1.2,
                "heavy wooden door slam",
            ),
            scanned("Pack/Forest Night.wav", "b", 60.0, "crickets and wind"),
            scanned("Pack/Doors/Door Creak.wav", "c", 3.0, "slow creak"),
        ],
    )
    .unwrap();
    let sounds = db.sounds(None).unwrap();
    let ids: HashMap<String, i64> = sounds
        .iter()
        .map(|s| (s.file_name.clone(), s.id.unwrap()))
        .collect();
    let doors: Vec<(i64, Option<String>)> = sounds
        .iter()
        .filter(|s| s.file_name.starts_with("Door"))
        .map(|s| (s.id.unwrap(), s.fingerprint.clone()))
        .collect();
    db.set_sound_category(&doors, Some("DOORWood")).unwrap();
    db.set_sound_category(
        &[(ids["Forest Night.wav"], Some("b".to_string()))],
        Some("AMBForst"),
    )
    .unwrap();
    db.replace_groups(
        "DOORWood",
        &[doors],
        &[Name {
            name: "Short · Wooden".into(),
            ai_words: vec![],
            shape_words: vec![],
            keywords: vec!["slam".into()],
        }],
    )
    .unwrap();
    db.save_facts(&[SoundFacts {
        sound_id: ids["Door Wood Slam 01.wav"],
        fingerprint: Some("a".into()),
        version: SoundFacts::CURRENT_VERSION,
        loudness: Some(-18.04),
        peak: Some(-1.0),
        error: None,
        analyzed_at: "2026-10-30 00:00:00.000".into(),
    }])
    .unwrap();
    (db, ids)
}

struct Connected {
    client: RunningService<RoleClient, ClientConfig>,
    recorder: Arc<Recorder>,
}

impl Connected {
    /// A tool's answer: its JSON text decoded, whether it's an error, the text.
    async fn call(&self, name: &'static str, arguments: Value) -> (Value, bool, String) {
        let arguments: JsonObject = arguments.as_object().cloned().unwrap_or_default();
        let answer = self
            .client
            .call_tool_once(CallToolRequestParams::new(name).with_arguments(arguments))
            .await
            .unwrap();
        let CallToolResponse::Complete(result) = answer else {
            panic!("not a result");
        };
        let text = result.content[0].as_text().unwrap().text.clone();
        let json = serde_json::from_str(&text).unwrap_or(Value::Null);
        let is_error = result.is_error == Some(true);
        if !is_error {
            assert_eq!(result.structured_content.as_ref(), Some(&json));
        }
        (json, is_error, text)
    }
}

async fn connect(db: LibraryDatabase, placements: Vec<Placement>, timelines: PathBuf) -> Connected {
    let recorder = Arc::new(Recorder::default());
    let (opened, added) = (recorder.clone(), recorder.clone());
    let outside = Outside {
        open: Box::new(move |url| opened.opened.lock().unwrap().push(url.to_string())),
        resolve_status: Box::new(|| Err(Failure::NotConnected)),
        resolve_add: Box::new(move |items, preview| {
            *added.items.lock().unwrap() = items.to_vec();
            *added.preview.lock().unwrap() = preview;
            let items = if placements.is_empty() {
                items
                    .iter()
                    .map(|_| Placement {
                        ok: Some(true),
                        track: Some(3),
                        track_name: Some("Earmark".into()),
                        start: Some("01:00:02:00".into()),
                        end: Some("01:00:03:06".into()),
                        new_track: Some(true),
                        error: None,
                    })
                    .collect()
            } else {
                placements.clone()
            };
            Ok(Added {
                project: "Film".into(),
                timeline: "Edit 1".into(),
                items,
            })
        }),
        timeline_folder: timelines,
    };
    let (client_side, server_side) = tokio::io::duplex(1 << 20);
    let server = EarmarkServer::new(EarmarkTools::with_database(db, outside));
    tokio::spawn(async move {
        let running = server.serve(server_side).await.unwrap();
        let _ = running.waiting().await;
    });
    let client = ClientConfig::default().serve(client_side).await.unwrap();
    Connected { client, recorder }
}

#[tokio::test]
async fn the_tools_and_what_they_may_change() {
    let root = temp_folder();
    let (db, _) = library(&root);
    let c = connect(db, vec![], root.clone()).await;
    let info = c.client.peer_info().unwrap();
    assert_eq!(info.server_info.as_ref().unwrap().name, "Earmark");
    assert!(
        info.instructions
            .as_deref()
            .unwrap()
            .contains("search_sounds")
    );
    let tools = c.client.list_all_tools().await.unwrap();
    let names: Vec<&str> = tools.iter().map(|t| &*t.name).collect();
    assert_eq!(
        names,
        [
            "library_overview",
            "search_sounds",
            "get_sound",
            "find_similar",
            "list_groups",
            "show_in_earmark",
            "resolve_status",
            "add_to_resolve",
            "save_timeline_file"
        ]
    );
    let read_only: Vec<&str> = tools
        .iter()
        .filter(|t| t.annotations.as_ref().unwrap().read_only_hint == Some(true))
        .map(|t| &*t.name)
        .collect();
    assert_eq!(
        read_only,
        [
            "library_overview",
            "search_sounds",
            "get_sound",
            "find_similar",
            "list_groups",
            "resolve_status"
        ]
    );
    assert!(
        tools
            .iter()
            .all(|t| t.annotations.as_ref().unwrap().destructive_hint != Some(true))
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn searching_and_details() {
    let root = temp_folder();
    let (db, ids) = library(&root);
    let c = connect(db, vec![], root.clone()).await;

    let (overview, ..) = c.call("library_overview", json!({})).await;
    assert_eq!(overview["sounds"], 4);
    assert_eq!(overview["duplicates"], 2);

    // Words in the name first; the category filter takes a CatID or a label.
    let (found, ..) = c
        .call("search_sounds", json!({"query": "door", "limit": 2}))
        .await;
    assert_eq!(found["total"], 3);
    assert_eq!(found["sounds"].as_array().unwrap().len(), 2);
    let (found, ..) = c
        .call("search_sounds", json!({"category": "Ambience / Forest"}))
        .await;
    assert_eq!(found["sounds"][0]["id"], ids["Forest Night.wav"]);
    let (found, ..) = c
        .call(
            "search_sounds",
            json!({"query": "wooden", "max_length": "2"}),
        )
        .await;
    assert_eq!(found["total"], 2);

    let (slam, ..) = c
        .call(
            "get_sound",
            json!({"sound_id": ids["Door Wood Slam 01.wav"]}),
        )
        .await;
    assert_eq!(slam["sound"]["catID"], "DOORWood");
    assert_eq!(slam["sound"]["group"], "Short · Wooden");
    assert_eq!(slam["sound"]["loudness"], -18);
    assert_eq!(slam["categorySource"], "the owner's choice for this sound");
    assert_eq!(slam["copies"][0]["id"], ids["Door Wood Slam 01 copy.wav"]);

    let (groups, ..) = c
        .call("list_groups", json!({"subcategory": "DOORWood"}))
        .await;
    assert_eq!(groups["groups"][0]["sounds"], 3);

    let (_, error, text) = c.call("get_sound", json!({"sound_id": 424242})).await;
    assert!(error && text.contains("no sound 424242"));
    let (_, error, text) = c
        .call("find_similar", json!({"sound_id": ids["Door Creak.wav"]}))
        .await;
    assert!(error && text.contains("analysed"));
    let (_, error, text) = c.call("nonsense", json!({})).await;
    assert!(error && text.contains("no tool"));
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn showing_and_placing() {
    let root = temp_folder();
    let (db, ids) = library(&root);
    let c = connect(db, vec![], root.clone()).await;
    let creak = ids["Door Creak.wav"];

    c.call("show_in_earmark", json!({"sound_id": creak})).await;
    assert_eq!(
        *c.recorder.opened.lock().unwrap(),
        [format!("earmark://sound/{creak}")]
    );

    // Defaults: the whole file at the playhead on an "Earmark" track.
    let (placed, error, _) = c
        .call(
            "add_to_resolve",
            json!({
                "items": [
                    {"sound_id": creak},
                    {"sound_id": creak, "start": 0.5, "end": 1.5, "at": 12.25, "track": "free"},
                    {"sound_id": creak, "at": "01:00:10:00", "track": 2}
                ],
                "preview": true,
            }),
        )
        .await;
    assert!(!error);
    assert!(*c.recorder.preview.lock().unwrap());
    {
        let items = c.recorder.items.lock().unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].track, Track::Earmark);
        assert_eq!(items[0].at, None);
        assert_eq!(items[0].length, Some(3.0));
        assert_eq!(items[0].channels, Some(2));
        assert_eq!((items[1].start, items[1].end), (Some(0.5), Some(1.5)));
        assert_eq!(items[1].at, Some(At::Seconds(12.25)));
        assert_eq!(items[1].track, Track::Free);
        assert_eq!(items[2].at, Some(At::Timecode("01:00:10:00".into())));
        assert_eq!(items[2].track, Track::Index(2));
    }
    assert_eq!(placed["items"][0]["sound_id"], creak);
    assert_eq!(placed["items"][0]["placed"], true);
    assert_eq!(placed["items"][0]["trackName"], "Earmark");
    assert_eq!(placed["timeline"], "Edit 1");

    // An offline file isn't sent to Resolve.
    std::fs::remove_file(root.join("Pack/Doors/Door Creak.wav")).unwrap();
    let (_, error, text) = c
        .call("add_to_resolve", json!({"items": [{"sound_id": creak}]}))
        .await;
    assert!(error && text.contains("offline"));

    let (_, error, text) = c.call("resolve_status", json!({})).await;
    assert!(error && text.contains("External scripting"));
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn a_placement_resolve_refused() {
    let root = temp_folder();
    let (db, ids) = library(&root);
    let busy = Placement {
        error: Some("busy".into()),
        ..Placement::default()
    };
    let c = connect(db, vec![busy], root.clone()).await;
    let (r, ..) = c
        .call(
            "add_to_resolve",
            json!({"items": [{"sound_id": ids["Forest Night.wav"], "track": 1}]}),
        )
        .await;
    assert_eq!(r["items"][0]["placed"], false);
    assert_eq!(r["items"][0]["problem"], "That track has a clip there.");
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn saving_a_timeline_file() {
    let root = temp_folder();
    let (db, ids) = library(&root);
    let folder = root.join("Timelines");
    let c = connect(db, vec![], folder.clone()).await;
    let items = json!([
        {"sound_id": ids["Door Creak.wav"]},
        {"sound_id": ids["Door Wood Slam 01.wav"], "start": 0.2, "end": 1, "at": 1}
    ]);

    let (saved, error, _) = c
        .call(
            "save_timeline_file",
            json!({"items": items, "frame_rate": "29.97 DF", "name": "Doors: take 1"}),
        )
        .await;
    assert!(!error);
    let path = saved["path"].as_str().unwrap();
    assert_eq!(Path::new(path), folder.join("Doors- take 1.fcpxml"));
    let xml = std::fs::read_to_string(path).unwrap();
    assert!(xml.contains(r#"tcFormat="DF""#));
    assert!(xml.contains(r#"<project name="Doors- take 1">"#));
    assert_eq!(saved["items"][0]["sound_id"], ids["Door Creak.wav"]);
    assert_eq!(saved["frameRate"], "29.97 DF");
    assert!(saved["howToImport"].as_str().unwrap().contains("Timeline…"));
    assert_eq!(saved["items"][0]["track"], 1);
    assert_eq!(saved["items"][1]["track"], 2);
    assert_eq!(saved["items"][0]["start"], "01:00:00;00");
    assert_eq!(saved["items"][1]["start"], "01:00:01;00");

    // Never overwrites; a frame rate it doesn't know is refused.
    let (again, ..) = c
        .call(
            "save_timeline_file",
            json!({"items": items, "frame_rate": 29.97, "name": "Doors: take 1"}),
        )
        .await;
    assert_eq!(
        Path::new(again["path"].as_str().unwrap()),
        folder.join("Doors- take 1 2.fcpxml")
    );
    let (_, error, text) = c
        .call(
            "save_timeline_file",
            json!({"items": items, "frame_rate": "12"}),
        )
        .await;
    assert!(error && text.contains("29.97 DF"));
    std::fs::remove_dir_all(root).unwrap();
}
