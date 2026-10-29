//! The similarity groups' tables (`SoundGroupStore.swift`): a set per subcategory, its groups and
//! their members, and the owner's changes.

use crate::{LibraryDatabase, Result};
use earmark_core::analysis::groups::{GroupSet, Name, Snapshot, VERSION};
use earmark_core::dates;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

/// One similarity group.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupRecord {
    pub id: i64,
    #[serde(rename = "catID")]
    pub cat_id: String,
    /// Earmark's name ("Long · Splashy · Watery").
    pub name: String,
    /// The owner's, if renamed.
    pub user_name: Option<String>,
    /// The words behind Earmark's name, "|" between them.
    pub ai_words: String,
    pub shape_words: String,
    pub keywords: String,
    /// The order in the sidebar (largest first when grouped).
    pub position: i64,
}

impl GroupRecord {
    /// The name shown: the owner's, else Earmark's.
    pub fn title(&self) -> &str {
        self.user_name.as_deref().unwrap_or(&self.name)
    }
}

/// Everything about groups, read in one go.
#[derive(Clone, Debug, Default)]
pub struct GroupSnapshot {
    pub plan: Snapshot,
    /// By catID, in sidebar order.
    pub groups: std::collections::BTreeMap<String, Vec<GroupRecord>>,
}

fn insert_group(c: &Connection, cat_id: &str, name: &Name, position: i64) -> rusqlite::Result<i64> {
    c.execute(
        "INSERT INTO soundGroup (catID, name, userName, aiWords, shapeWords, keywords, position) \
         VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6)",
        params![
            cat_id,
            name.name,
            name.ai_words.join("|"),
            name.shape_words.join("|"),
            name.keywords.join("|"),
            position
        ],
    )?;
    Ok(c.last_insert_rowid())
}

fn save_member(
    c: &Connection,
    sound_id: i64,
    fingerprint: &Option<String>,
    group: i64,
) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO soundGroupMember (soundId, fingerprint, soundGroupId) VALUES (?1, ?2, ?3) \
         ON CONFLICT(soundId) DO UPDATE SET fingerprint = ?2, soundGroupId = ?3",
        params![sound_id, fingerprint, group],
    )?;
    Ok(())
}

fn save_set(c: &Connection, cat_id: &str, grouped: i64) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO soundGroupSet (catID, version, grouped, changed, edited, groupedAt) VALUES (?1, ?2, ?3, 0, 0, ?4) \
         ON CONFLICT(catID) DO UPDATE SET version = ?2, grouped = ?3, changed = 0, edited = 0, groupedAt = ?4",
        params![cat_id, VERSION, grouped, dates::now()],
    )?;
    Ok(())
}

fn mark_edited(c: &Connection, cat_id: &str) -> rusqlite::Result<()> {
    c.execute(
        "UPDATE soundGroupSet SET edited = 1 WHERE catID = ?1",
        [cat_id],
    )?;
    Ok(())
}

fn drop_empty_groups(c: &Connection, cat_id: &str) -> rusqlite::Result<()> {
    c.execute(
        "DELETE FROM soundGroup WHERE catID = ?1 AND id NOT IN (SELECT DISTINCT soundGroupId FROM soundGroupMember)",
        [cat_id],
    )?;
    Ok(())
}

impl LibraryDatabase {
    pub fn group_snapshot(&self) -> Result<GroupSnapshot> {
        self.with(|c| {
            let mut snap = GroupSnapshot::default();
            let exists: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'soundGroup')",
                [],
                |r| r.get(0),
            )?;
            if !exists {
                return Ok(snap);
            }
            let mut st = c.prepare("SELECT catID, version, grouped, changed, edited, groupedAt FROM soundGroupSet")?;
            for s in st.query_map([], |r| {
                Ok(GroupSet {
                    cat_id: r.get(0)?,
                    version: r.get(1)?,
                    grouped: r.get(2)?,
                    changed: r.get(3)?,
                    edited: r.get(4)?,
                    grouped_at: r.get(5)?,
                })
            })? {
                let s = s?;
                snap.plan.sets.insert(s.cat_id.clone(), s);
            }
            let mut st = c.prepare(
                "SELECT id, catID, name, userName, aiWords, shapeWords, keywords, position FROM soundGroup \
                 ORDER BY catID, position, id",
            )?;
            for g in st.query_map([], |r| {
                Ok(GroupRecord {
                    id: r.get(0)?,
                    cat_id: r.get(1)?,
                    name: r.get(2)?,
                    user_name: r.get(3)?,
                    ai_words: r.get(4)?,
                    shape_words: r.get(5)?,
                    keywords: r.get(6)?,
                    position: r.get(7)?,
                })
            })? {
                let g = g?;
                snap.plan.groups.entry(g.cat_id.clone()).or_default().push(g.id);
                snap.groups.entry(g.cat_id.clone()).or_default().push(g);
            }
            let mut st = c.prepare("SELECT soundId, fingerprint, soundGroupId FROM soundGroupMember")?;
            for m in st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, i64>(2)?)))? {
                let (sound, fingerprint, group) = m?;
                snap.plan.membership.insert(sound, group);
                snap.plan.member_fingerprints.insert(sound, fingerprint);
            }
            Ok(snap)
        })
    }

    /// Replaces a subcategory's groups with freshly made ones (`groups[i]` named `names[i]`).
    pub fn replace_groups(
        &self,
        cat_id: &str,
        groups: &[Vec<(i64, Option<String>)>],
        names: &[Name],
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute("DELETE FROM soundGroup WHERE catID = ?1", [cat_id])?;
            for (i, members) in groups.iter().enumerate() {
                if members.is_empty() {
                    continue;
                }
                let g = insert_group(&tx, cat_id, &names[i], i as i64)?;
                for (id, fp) in members {
                    save_member(&tx, *id, fp, g)?;
                }
            }
            save_set(
                &tx,
                cat_id,
                groups.iter().map(Vec::len).sum::<usize>() as i64,
            )?;
            tx.commit()
        })
    }

    /// Sounds join groups (`add`: sound, fingerprint, group) or leave this subcategory's; groups
    /// left empty go.
    pub fn update_groups(
        &self,
        cat_id: &str,
        add: &[(i64, Option<String>, i64)],
        remove: &[i64],
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            // Only from this subcategory's groups: a sound whose category changed may already have
            // joined another's.
            for id in remove {
                tx.execute(
                    "DELETE FROM soundGroupMember WHERE soundId = ?1 AND soundGroupId IN \
                     (SELECT id FROM soundGroup WHERE catID = ?2)",
                    params![id, cat_id],
                )?;
            }
            for (id, fp, g) in add {
                save_member(&tx, *id, fp, *g)?;
            }
            drop_empty_groups(&tx, cat_id)?;
            tx.execute(
                "UPDATE soundGroupSet SET changed = changed + ?1 WHERE catID = ?2",
                params![(add.len() + remove.len()) as i64, cat_id],
            )?;
            tx.commit()
        })
    }

    pub fn drop_groups(&self, cat_id: &str) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute("DELETE FROM soundGroup WHERE catID = ?1", [cat_id])?;
            tx.execute("DELETE FROM soundGroupSet WHERE catID = ?1", [cat_id])?;
            tx.commit()
        })
    }

    /// A new name for a group; None goes back to Earmark's.
    pub fn rename_group(&self, id: i64, name: Option<&str>) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let row: Option<(String, String)> = tx
                .query_row(
                    "SELECT catID, name FROM soundGroup WHERE id = ?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let Some((cat_id, own)) = row else {
                return Ok(());
            };
            let trimmed = name
                .map(earmark_core::text::trim)
                .filter(|t| !t.is_empty() && *t != own);
            tx.execute(
                "UPDATE soundGroup SET userName = ?1 WHERE id = ?2",
                params![trimmed, id],
            )?;
            mark_edited(&tx, &cat_id)?;
            tx.commit()
        })
    }

    /// Moves these sounds into a group (of their own subcategory); groups left empty go.
    pub fn move_sounds(&self, sounds: &[(i64, Option<String>)], group: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let cat_id: Option<String> = tx
                .query_row("SELECT catID FROM soundGroup WHERE id = ?1", [group], |r| {
                    r.get(0)
                })
                .optional()?;
            let Some(cat_id) = cat_id else { return Ok(()) };
            for (id, fp) in sounds {
                save_member(&tx, *id, fp, group)?;
            }
            drop_empty_groups(&tx, &cat_id)?;
            mark_edited(&tx, &cat_id)?;
            tx.commit()
        })
    }

    /// A new group of these sounds, after the subcategory's others. Returns its id.
    pub fn new_group(
        &self,
        cat_id: &str,
        name: &str,
        sounds: &[(i64, Option<String>)],
    ) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            let last: Option<i64> = tx.query_row(
                "SELECT MAX(position) FROM soundGroup WHERE catID = ?1",
                [cat_id],
                |r| r.get(0),
            )?;
            let n = Name {
                name: name.into(),
                ai_words: vec![],
                shape_words: vec![],
                keywords: vec![],
            };
            let g = insert_group(&tx, cat_id, &n, last.unwrap_or(-1) + 1)?;
            for (id, fp) in sounds {
                save_member(&tx, *id, fp, g)?;
            }
            drop_empty_groups(&tx, cat_id)?;
            let has_set: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM soundGroupSet WHERE catID = ?1)",
                [cat_id],
                |r| r.get(0),
            )?;
            if !has_set {
                save_set(&tx, cat_id, sounds.len() as i64)?;
            }
            mark_edited(&tx, cat_id)?;
            tx.commit()?;
            Ok(g)
        })
    }

    /// Moves every sound of `groups` into `target` and removes those groups.
    pub fn merge_groups(&self, groups: &[i64], target: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let cat_id: Option<String> = tx
                .query_row(
                    "SELECT catID FROM soundGroup WHERE id = ?1",
                    [target],
                    |r| r.get(0),
                )
                .optional()?;
            let Some(cat_id) = cat_id else { return Ok(()) };
            for &g in groups.iter().filter(|&&g| g != target) {
                tx.execute(
                    "UPDATE soundGroupMember SET soundGroupId = ?1 WHERE soundGroupId = ?2",
                    params![target, g],
                )?;
                tx.execute("DELETE FROM soundGroup WHERE id = ?1", [g])?;
            }
            mark_edited(&tx, &cat_id)?;
            tx.commit()
        })
    }

    /// Forgets a subcategory's groups and the owner's changes, so Earmark groups it afresh.
    pub fn regroup(&self, cat_id: &str) -> Result<()> {
        self.drop_groups(cat_id)
    }
}
