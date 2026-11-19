//! The Swift SoundGroupStoreTests: what gets regrouped, and the owner's changes.

use earmark_core::analysis::groups::{Name, Work, nearest, work};
use earmark_db::LibraryDatabase;
use std::collections::BTreeMap;

fn name(s: &str) -> Name {
    Name {
        name: s.into(),
        ai_words: vec!["a".into(), "b".into()],
        shape_words: vec![],
        keywords: vec!["k".into()],
    }
}

fn sounds(ids: std::ops::RangeInclusive<i64>) -> Vec<(i64, Option<String>)> {
    ids.map(|i| (i, Some(format!("f{i}")))).collect()
}

type Sounds = Vec<(i64, Option<String>)>;

fn plan(entries: &[(&str, Sounds)], db: &LibraryDatabase) -> Vec<Work> {
    let map: BTreeMap<String, Vec<(i64, Option<String>)>> = entries
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect();
    work(&map, &db.group_snapshot().unwrap().plan)
}

fn ids(db: &LibraryDatabase, cat: &str) -> Vec<i64> {
    db.group_snapshot().unwrap().groups[cat]
        .iter()
        .map(|g| g.id)
        .collect()
}

#[test]
fn new_subcategories_are_grouped_and_unchanged_ones_left_alone() {
    let db = LibraryDatabase::open(None, false).unwrap();
    assert_eq!(
        plan(&[("DSGNWhsh", sounds(1..=40))], &db),
        [Work::Regroup {
            cat_id: "DSGNWhsh".into(),
            sounds: (1..=40).collect()
        }]
    );
    db.replace_groups(
        "DSGNWhsh",
        &[sounds(1..=25), sounds(26..=40)],
        &[name("Long · Airy"), name("Short · Metallic")],
    )
    .unwrap();
    let snap = db.group_snapshot().unwrap();
    assert_eq!(
        snap.groups["DSGNWhsh"]
            .iter()
            .map(|g| g.name.as_str())
            .collect::<Vec<_>>(),
        ["Long · Airy", "Short · Metallic"]
    );
    assert_eq!(snap.groups["DSGNWhsh"][0].keywords, "k");
    assert_eq!(snap.plan.membership.len(), 40);
    assert!(plan(&[("DSGNWhsh", sounds(1..=40))], &db).is_empty());
}

#[test]
fn few_new_sounds_join_many_regroup() {
    let db = LibraryDatabase::open(None, false).unwrap();
    db.replace_groups(
        "DSGNWhsh",
        &[sounds(1..=25), sounds(26..=40)],
        &[name("A"), name("B")],
    )
    .unwrap();
    // 5 more, and one file changed: joined, not regrouped.
    let mut current = sounds(1..=45);
    current[0].1 = Some("changed".into());
    assert_eq!(
        plan(&[("DSGNWhsh", current.clone())], &db),
        [Work::Update {
            cat_id: "DSGNWhsh".into(),
            add: vec![1, 41, 42, 43, 44, 45],
            remove: vec![1]
        }]
    );
    let g = ids(&db, "DSGNWhsh");
    let mut add = vec![(1, Some("changed".to_string()), g[0])];
    add.extend((41..=45).map(|i| (i, Some(format!("f{i}")), g[1])));
    db.update_groups("DSGNWhsh", &add, &[1]).unwrap();
    let snap = db.group_snapshot().unwrap();
    assert_eq!(snap.plan.membership[&1], g[0]);
    assert_eq!(
        snap.plan.member_fingerprints[&1].as_deref(),
        Some("changed")
    );
    assert_eq!(snap.plan.membership[&45], g[1]);
    assert_eq!(snap.plan.sets["DSGNWhsh"].changed, 7);
    // Another 4 makes 11 of 40 changed: regrouped.
    let mut more = current;
    more.extend(sounds(46..=49));
    assert_eq!(
        plan(&[("DSGNWhsh", more)], &db),
        [Work::Regroup {
            cat_id: "DSGNWhsh".into(),
            sounds: (1..=49).collect()
        }]
    );
}

#[test]
fn sounds_moving_category_and_empty_subcategories() {
    let db = LibraryDatabase::open(None, false).unwrap();
    db.replace_groups("A", &[sounds(1..=30)], &[name("A1")])
        .unwrap();
    db.replace_groups("B", &[sounds(31..=60)], &[name("B1")])
        .unwrap();
    db.replace_groups("C", &[sounds(61..=62)], &[name("C1")])
        .unwrap();
    let mut b_sounds = sounds(31..=60);
    b_sounds.push((1, Some("f1".into())));
    let w = plan(&[("A", sounds(2..=30)), ("B", b_sounds)], &db);
    assert!(w.contains(&Work::Update {
        cat_id: "A".into(),
        add: vec![],
        remove: vec![1]
    }));
    assert!(w.contains(&Work::Update {
        cat_id: "B".into(),
        add: vec![1],
        remove: vec![]
    }));
    assert!(w.contains(&Work::Drop { cat_id: "C".into() }));
    // B's join happens first; A's leave mustn't undo it.
    let b = ids(&db, "B")[0];
    db.update_groups("B", &[(1, Some("f1".into()), b)], &[])
        .unwrap();
    db.update_groups("A", &[], &[1]).unwrap();
    db.drop_groups("C").unwrap();
    let snap = db.group_snapshot().unwrap();
    assert_eq!(snap.plan.membership[&1], b);
    assert!(
        !snap.groups.contains_key("C")
            && !snap.plan.sets.contains_key("C")
            && !snap.plan.membership.contains_key(&61)
    );
}

#[test]
fn the_owners_changes_stick() {
    let db = LibraryDatabase::open(None, false).unwrap();
    db.replace_groups(
        "A",
        &[sounds(1..=20), sounds(21..=30), sounds(31..=40)],
        &[name("One"), name("Two"), name("Three")],
    )
    .unwrap();
    let g = ids(&db, "A");
    db.rename_group(g[0], Some("  Big swells ")).unwrap();
    let snap = db.group_snapshot().unwrap();
    let first = snap.groups["A"].iter().find(|r| r.id == g[0]).unwrap();
    assert_eq!((first.title(), first.name.as_str()), ("Big swells", "One"));
    assert!(snap.plan.sets["A"].edited);
    db.rename_group(g[0], Some("")).unwrap();
    assert_eq!(db.group_snapshot().unwrap().groups["A"][0].user_name, None);

    // Move all of Two's sounds out: Two goes.
    db.move_sounds(&sounds(21..=30), g[2]).unwrap();
    let snap = db.group_snapshot().unwrap();
    assert_eq!(snap.groups["A"].len(), 2);
    assert_eq!(snap.plan.membership[&25], g[2]);
    let made = db.new_group("A", "Mine", &sounds(1..=3)).unwrap();
    db.merge_groups(&[g[2]], g[0]).unwrap();
    let snap = db.group_snapshot().unwrap();
    assert_eq!(
        snap.groups["A"]
            .iter()
            .map(|r| r.title().to_string())
            .collect::<Vec<_>>(),
        ["One", "Mine"]
    );
    assert_eq!(
        (snap.plan.membership[&1], snap.plan.membership[&35]),
        (made, g[0])
    );

    // Edited: lots of new sounds only join.
    assert_eq!(
        plan(&[("A", sounds(1..=80))], &db),
        [Work::Update {
            cat_id: "A".into(),
            add: (41..=80).collect(),
            remove: vec![]
        }]
    );
    // Regroup forgets the changes.
    db.regroup("A").unwrap();
    assert_eq!(
        plan(&[("A", sounds(1..=80))], &db),
        [Work::Regroup {
            cat_id: "A".into(),
            sounds: (1..=80).collect()
        }]
    );
}

#[test]
fn new_sounds_join_the_nearest_group() {
    // Two groups along x and y; a sound near y joins the second.
    let x = [1.0, 0.0, 0.9, 0.1, 0.0, 1.0, 0.1, 0.9];
    let members = BTreeMap::from([(7, vec![0, 1]), (9, vec![2, 3])]);
    assert_eq!(nearest(&[0.2, 0.98], &x, 2, &members), Some(9));
}
