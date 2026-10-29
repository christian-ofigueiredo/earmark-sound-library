//! The migrations, with the exact SQL GRDB wrote for the Swift app (copied from a real
//! database's `sqlite_master`), recorded in GRDB's own `grdb_migrations` table. Either app can
//! then open a database the other made. Port of `LibraryDatabase.migrator`.

use rusqlite::{Connection, OptionalExtension};

/// Each migration's identifier, as GRDB records it, and its SQL.
pub const MIGRATIONS: &[(&str, &str)] = &[
    (
        "v1",
        r#"CREATE TABLE "library" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "kind" TEXT NOT NULL, "path" TEXT NOT NULL UNIQUE, "bookmark" BLOB, "addedAt" DATETIME NOT NULL);
CREATE TABLE "sound" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "libraryId" INTEGER NOT NULL REFERENCES "library"("id") ON DELETE CASCADE, "path" TEXT NOT NULL UNIQUE, "fileName" TEXT NOT NULL, "folder" TEXT NOT NULL, "fileSize" INTEGER NOT NULL, "modifiedAt" DATETIME NOT NULL, "fingerprint" TEXT, "duration" DOUBLE, "sampleRate" DOUBLE, "channels" INTEGER, "bitsPerSample" INTEGER, "fxName" TEXT, "details" TEXT, "keywords" TEXT, "vendorLibrary" TEXT, "manufacturer" TEXT, "designer" TEXT, "catID" TEXT, "category" TEXT, "subcategory" TEXT, "categorySource" TEXT);
CREATE INDEX "sound_on_libraryId" ON "sound"("libraryId");
CREATE INDEX "sound_on_fingerprint" ON "sound"("fingerprint");
CREATE INDEX "sound_on_catID" ON "sound"("catID");
CREATE TABLE "song" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "libraryId" INTEGER NOT NULL REFERENCES "library"("id") ON DELETE CASCADE, "path" TEXT NOT NULL UNIQUE, "fileName" TEXT NOT NULL, "folder" TEXT NOT NULL, "fileSize" INTEGER NOT NULL, "modifiedAt" DATETIME NOT NULL, "title" TEXT, "artist" TEXT, "album" TEXT, "duration" DOUBLE, "bpm" DOUBLE, "bpmLow" DOUBLE, "bpmHigh" DOUBLE, "tempoStability" TEXT, "beatsPerBar" INTEGER, "keyPitchClass" INTEGER, "keyMinor" BOOLEAN, "keyConfidence" DOUBLE, "analysisSource" TEXT);
CREATE INDEX "song_on_libraryId" ON "song"("libraryId");"#,
    ),
    // Ids of sounds that left the database, by fingerprint, so the same file gets its id back.
    (
        "v2-retired-sounds",
        r#"CREATE TABLE "retiredSound" ("fingerprint" TEXT PRIMARY KEY NOT NULL, "soundId" INTEGER NOT NULL);"#,
    ),
    (
        "v3-sound-facts",
        r#"CREATE TABLE "soundFacts" ("soundId" INTEGER PRIMARY KEY, "fingerprint" TEXT, "version" INTEGER NOT NULL, "loudness" DOUBLE, "peak" DOUBLE, "error" TEXT, "analyzedAt" DATETIME NOT NULL);"#,
    ),
    (
        "v4-sound-embeddings",
        r#"CREATE TABLE "soundEmbedding" ("soundId" INTEGER NOT NULL, "model" TEXT NOT NULL, "fingerprint" TEXT, "version" INTEGER NOT NULL, "vector" BLOB, "error" TEXT, "analyzedAt" DATETIME NOT NULL, PRIMARY KEY ("soundId", "model"));"#,
    ),
    (
        "v5-folder-rules",
        r#"CREATE TABLE "folderRule" ("libraryId" INTEGER NOT NULL, "folder" TEXT NOT NULL, "catID" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, PRIMARY KEY ("libraryId", "folder"));"#,
    ),
    (
        "v6-folder-guesses",
        r#"CREATE TABLE "folderGuess" ("libraryId" INTEGER NOT NULL, "folder" TEXT NOT NULL, "catID" TEXT NOT NULL, "alternatives" TEXT NOT NULL, "reason" TEXT NOT NULL, "isUnsure" BOOLEAN NOT NULL, "analysed" INTEGER NOT NULL, "version" INTEGER NOT NULL, "createdAt" DATETIME NOT NULL, PRIMARY KEY ("libraryId", "folder"));"#,
    ),
    (
        "v7-song-corrections",
        r#"CREATE TABLE "songCorrection" ("path" TEXT PRIMARY KEY, "bpm" DOUBLE, "bpmLow" DOUBLE, "bpmHigh" DOUBLE, "keyPitchClass" INTEGER, "keyMinor" BOOLEAN, "beatsPerBar" INTEGER, "correctedAt" DATETIME NOT NULL);"#,
    ),
    (
        "v8-sound-groups",
        r#"CREATE TABLE "soundGroupSet" ("catID" TEXT PRIMARY KEY NOT NULL, "version" INTEGER NOT NULL, "grouped" INTEGER NOT NULL, "changed" INTEGER NOT NULL, "edited" BOOLEAN NOT NULL, "groupedAt" DATETIME NOT NULL);
CREATE TABLE "soundGroup" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "catID" TEXT NOT NULL, "name" TEXT NOT NULL, "userName" TEXT, "aiWords" TEXT NOT NULL, "shapeWords" TEXT NOT NULL, "keywords" TEXT NOT NULL, "position" INTEGER NOT NULL);
CREATE INDEX "soundGroup_on_catID" ON "soundGroup"("catID");
CREATE TABLE "soundGroupMember" ("soundId" INTEGER PRIMARY KEY, "fingerprint" TEXT, "soundGroupId" INTEGER NOT NULL REFERENCES "soundGroup"("id") ON DELETE CASCADE);
CREATE INDEX "soundGroupMember_on_soundGroupId" ON "soundGroupMember"("soundGroupId");"#,
    ),
    (
        "v9-sound-categories",
        r#"CREATE TABLE "soundCategory" ("soundId" INTEGER PRIMARY KEY, "fingerprint" TEXT, "catID" TEXT NOT NULL, "byOwner" BOOLEAN NOT NULL, "share" DOUBLE, "replaced" TEXT, "version" INTEGER NOT NULL, "createdAt" DATETIME NOT NULL);"#,
    ),
    (
        "v10-sound-duplicates",
        r#"CREATE TABLE "soundDuplicate" ("soundA" INTEGER NOT NULL, "soundB" INTEGER NOT NULL, "similarity" DOUBLE NOT NULL, PRIMARY KEY ("soundA", "soundB"));"#,
    ),
];

#[derive(Debug)]
pub enum MigrationError {
    Sqlite(rusqlite::Error),
    /// The database has migrations this engine doesn't know: it was made by a newer Earmark.
    Newer(Vec<String>),
}

impl From<rusqlite::Error> for MigrationError {
    fn from(e: rusqlite::Error) -> Self {
        MigrationError::Sqlite(e)
    }
}

/// Applies the missing migrations, each in its own transaction, as GRDB's migrator does.
pub fn migrate(conn: &mut Connection) -> Result<(), MigrationError> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
    )?;
    let applied: Vec<String> = {
        let mut st = conn.prepare("SELECT identifier FROM grdb_migrations")?;
        st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?
    };
    let unknown: Vec<String> = applied
        .iter()
        .filter(|a| !MIGRATIONS.iter().any(|(id, _)| id == a))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        return Err(MigrationError::Newer(unknown));
    }
    for (id, sql) in MIGRATIONS {
        if applied.iter().any(|a| a == id) {
            continue;
        }
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.execute("INSERT INTO grdb_migrations (identifier) VALUES (?1)", [id])?;
        tx.commit()?;
    }
    Ok(())
}

/// Whether every migration is applied (a read-only opener checks this instead of migrating).
pub fn is_current(conn: &Connection) -> rusqlite::Result<bool> {
    let exists: Option<String> = conn
        .query_row(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'grdb_migrations'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if exists.is_none() {
        return Ok(false);
    }
    let n: i64 = conn.query_row("SELECT COUNT(*) FROM grdb_migrations", [], |r| r.get(0))?;
    Ok(n as usize >= MIGRATIONS.len())
}
