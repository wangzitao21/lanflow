use super::*;

fn note(index: usize) -> Value {
    json!({"id":format!("favorite-message-{index:016}"),"originId":"favorite-test-device","originName":"Desktop","createdAt":"2026-10-22T00:00:00Z","kind":"text","text":format!("Independent note {index}"),"name":"","size":0,"sha256":""})
}
fn favorite(root: &Path, item: &Value) -> Value {
    dispatch(json!({"op":"set_favorites","root":root,"ids":[item["id"]],"value":true})).unwrap()["favorites"][item["id"].as_str().unwrap()].clone()
}
fn state(root: &Path, original: &str) -> Value {
    dispatch(json!({"op":"snapshot","root":root})).unwrap()["favorites"][original].clone()
}
fn legacy(id: &str, item: &Value, value: bool, revision: i64) -> Value {
    json!({"id":id,"type":"favorite","favorite":{"id":item["id"],"value":value,"revision":revision}})
}

#[test]
fn independent_text_snapshot_deletion_and_trash_restore_survive_restart() {
    let root = crate::tests::root();
    let item = note(1);
    let original = item["id"].as_str().unwrap();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let saved = favorite(&root, &item);
    assert_ne!(saved["snapshotId"], item["id"]);
    assert_eq!(saved["item"]["text"], item["text"]);
    let snapshot = saved["snapshotId"].as_str().unwrap();
    dispatch(json!({"op":"delete_favorites","root":root,"ids":[snapshot]})).unwrap();
    assert_eq!(
        initialize(&root).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let trash = dispatch(json!({"op":"trash","root":root})).unwrap();
    assert_eq!(trash[0]["source"], "favorite");
    assert_eq!(trash[0]["id"], snapshot);
    dispatch(json!({"op":"restore","root":root,"id":snapshot,"source":"favorite"})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":original})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let reopened = initialize(&root).unwrap();
    assert!(reopened["entries"].as_array().unwrap().is_empty());
    assert_eq!(reopened["favorites"][original]["item"], saved["item"]);
    assert_eq!(reopened["favorites"][original]["savedAt"], saved["savedAt"]);
    dispatch(json!({"op":"delete_favorites","root":root,"ids":[snapshot]})).unwrap();
    let trash = dispatch(json!({"op":"trash","root":root})).unwrap();
    assert_eq!(trash.as_array().unwrap().len(), 2);
    dispatch(json!({"op":"restore_favorites","root":root,"ids":[snapshot]})).unwrap();
    let restored = initialize(&root).unwrap();
    assert!(restored["entries"].as_array().unwrap().is_empty());
    assert_eq!(restored["favorites"][original]["value"], true);
    assert_eq!(restored["favorites"][original]["item"], saved["item"]);
    crate::tests::cleanup(&root);
}

#[test]
fn legacy_favorites_migrate_from_live_trash_or_event_only_without_duplicate_snapshots() {
    for source in ["live", "trash", "event"] {
        let root = crate::tests::root();
        let item = note(2);
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        if source != "live" {
            dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
        }
        let event = legacy("legacy-favorite-event-0001", &item, true, 700);
        {
            let shared = database(&root).unwrap();
            let db = shared.lock().unwrap();
            if source == "event" {
                db.execute("DELETE FROM trash", []).unwrap();
            }
            db.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event["id"].as_str().unwrap(), event.to_string()],
            )
            .unwrap();
            db.execute(
                "INSERT INTO favorites VALUES(?,?,?,?)",
                params![
                    item["id"].as_str().unwrap(),
                    700,
                    event["id"].as_str().unwrap(),
                    event["favorite"].to_string()
                ],
            )
            .unwrap();
        }
        dispatch(json!({"op":"close","root":root})).unwrap();
        let migrated = initialize(&root).unwrap();
        let migrated_favorite = &migrated["favorites"][item["id"].as_str().unwrap()];
        assert_eq!(migrated_favorite["item"]["text"], item["text"], "{source}");
        assert_eq!(
            migrated_favorite["snapshotId"],
            favorites::snapshot_id(item["id"].as_str().unwrap())
        );
        let before = dispatch(
            json!({"op":"page","root":root,"after":0,"capabilities":"favorites,favoriteSnapshots"}),
        )
        .unwrap();
        dispatch(json!({"op":"close","root":root})).unwrap();
        initialize(&root).unwrap();
        let after = dispatch(
            json!({"op":"page","root":root,"after":0,"capabilities":"favorites,favoriteSnapshots"}),
        )
        .unwrap();
        assert_eq!(before, after);
        crate::tests::cleanup(&root);
    }
}

#[test]
fn legacy_enrichment_is_deterministic_after_different_previous_favorite_rounds() {
    let a = crate::tests::root();
    let b = crate::tests::root();
    let item = note(3);
    let first = legacy("legacy-previous-event-001", &item, true, 100);
    let second = legacy("legacy-previous-event-002", &item, true, 200);
    let remove = legacy("legacy-remove-event-0003", &item, false, 300);
    for root in [&a, &b] {
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        dispatch(json!({"op":"apply","root":root,"event":first})).unwrap();
    }
    dispatch(json!({"op":"apply","root":b,"event":second})).unwrap();
    for root in [&a, &b] {
        dispatch(json!({"op":"apply","root":root,"event":remove})).unwrap();
    }
    let id = digest(b"favorite-snapshot:legacy-remove-event-0003");
    let read = |root: &Path| {
        let db = database(root).unwrap();
        let text: String = db
            .lock()
            .unwrap()
            .query_row("SELECT body FROM events WHERE id=?", [&id], |r| r.get(0))
            .unwrap();
        serde_json::from_str::<Value>(&text).unwrap()
    };
    let left = read(&a);
    let right = read(&b);
    assert_eq!(left, right);
    dispatch(json!({"op":"apply","root":a,"event":right})).unwrap();
    dispatch(json!({"op":"apply","root":b,"event":left})).unwrap();
    assert_eq!(
        state(&a, item["id"].as_str().unwrap()),
        state(&b, item["id"].as_str().unwrap())
    );
    crate::tests::cleanup(&a);
    crate::tests::cleanup(&b);
}

#[test]
fn equal_revision_legacy_flags_keep_the_same_winner_on_old_and_new_peers() {
    let root = crate::tests::root();
    let item = note(4);
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    for event in [
        legacy("00000000000000000000000000000001", &item, true, 900),
        legacy("00000000000000000000000000000002", &item, false, 900),
    ] {
        dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
    }
    let old =
        dispatch(json!({"op":"page","root":root,"after":0,"capabilities":"favorites"})).unwrap();
    let visible = old["items"].as_array().unwrap();
    assert!(
        visible
            .iter()
            .all(|r| r["event"]["type"] != "favorite_snapshot")
    );
    let winner = visible
        .iter()
        .filter(|r| r["event"]["type"] == "favorite")
        .max_by_key(|r| {
            (
                r["event"]["favorite"]["revision"].as_i64().unwrap(),
                r["event"]["id"].as_str().unwrap(),
            )
        })
        .unwrap();
    assert_eq!(winner["event"]["favorite"]["value"], false);
    assert_eq!(state(&root, item["id"].as_str().unwrap())["value"], false);
    let modern = dispatch(
        json!({"op":"page","root":root,"after":0,"capabilities":"favorites,favoriteSnapshots"}),
    )
    .unwrap();
    assert!(
        modern["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["event"]["type"] == "favorite_snapshot")
    );
    crate::tests::cleanup(&root);
}

#[test]
fn linked_deletion_is_atomic_and_only_the_initiator_reads_its_local_setting() {
    let a = crate::tests::root();
    let b = crate::tests::root();
    let item = note(5);
    for root in [&a, &b] {
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        favorite(root, &item);
    }
    dispatch(json!({"op":"save_meta","root":b,"value":{"linkFavoriteDeletion":true}})).unwrap();
    // A's default independent delete does not inherit B's linked policy.
    dispatch(json!({"op":"delete","root":a,"id":item["id"]})).unwrap();
    let deletion = json!({"id":digest(format!("delete:{}",item["id"].as_str().unwrap()).as_bytes()),"type":"delete","target":item["id"]});
    dispatch(json!({"op":"apply","root":b,"event":deletion})).unwrap();
    assert_eq!(state(&b, item["id"].as_str().unwrap())["value"], true);
    let second = note(6);
    dispatch(json!({"op":"add","root":b,"item":second})).unwrap();
    let saved = favorite(&b, &second);
    let before = initialize(&b).unwrap();
    assert!(
        dispatch(json!({"op":"delete_favorites","root":b,"ids":[saved["snapshotId"],"bad"]}))
            .is_err()
    );
    assert_eq!(initialize(&b).unwrap(), before);
    {
        let shared = database(&b).unwrap();
        let db = shared.lock().unwrap();
        db.execute_batch("CREATE TEMP TRIGGER fail_second_side BEFORE INSERT ON deleted BEGIN SELECT RAISE(ABORT,'injected deletion failure'); END;").unwrap();
    }
    // The favorite false event and its trash row have already been attempted
    // when the second side fails. The entire user action must roll back.
    assert!(
        dispatch(json!({"op":"delete_favorites","root":b,"ids":[saved["snapshotId"]]})).is_err()
    );
    assert_eq!(initialize(&b).unwrap(), before);
    {
        let shared = database(&b).unwrap();
        let db = shared.lock().unwrap();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM favorite_trash", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        db.execute_batch("DROP TRIGGER fail_second_side").unwrap();
    }
    dispatch(json!({"op":"delete_favorites","root":b,"ids":[saved["snapshotId"]]})).unwrap();
    assert_eq!(state(&b, second["id"].as_str().unwrap())["value"], false);
    assert!(
        initialize(&b).unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    dispatch(json!({"op":"restore_favorites","root":b,"ids":[saved["snapshotId"]]})).unwrap();
    assert!(
        initialize(&b).unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let third = note(7);
    dispatch(json!({"op":"add","root":b,"item":third})).unwrap();
    favorite(&b, &third);
    dispatch(json!({"op":"delete_many","root":b,"ids":[third["id"]]})).unwrap();
    assert_eq!(state(&b, third["id"].as_str().unwrap())["value"], false);
    dispatch(json!({"op":"close","root":b})).unwrap();
    assert_eq!(initialize(&b).unwrap()["linkFavoriteDeletion"], true);
    let fourth = note(10);
    for root in [&a, &b] {
        dispatch(json!({"op":"add","root":root,"item":fourth})).unwrap();
    }
    let saved = favorite(&a, &fourth);
    let page = dispatch(
        json!({"op":"page","root":a,"after":0,"capabilities":"favorites,favoriteSnapshots"}),
    )
    .unwrap();
    let addition = page["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["event"]["favorite"]["id"] == fourth["id"])
        .unwrap()["event"]
        .clone();
    dispatch(json!({"op":"apply","root":b,"event":addition})).unwrap();
    dispatch(json!({"op":"delete_favorites","root":a,"ids":[saved["snapshotId"]]})).unwrap();
    let page = dispatch(
        json!({"op":"page","root":a,"after":0,"capabilities":"favorites,favoriteSnapshots"}),
    )
    .unwrap();
    let removal = page["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| {
            r["event"]["favorite"]["id"] == fourth["id"] && r["event"]["favorite"]["value"] == false
        })
        .unwrap()["event"]
        .clone();
    dispatch(json!({"op":"apply","root":b,"event":removal})).unwrap();
    assert_eq!(state(&b, fourth["id"].as_str().unwrap())["value"], false);
    assert!(
        initialize(&b).unwrap()["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["item"]["id"] == fourth["id"])
    );
    crate::tests::cleanup(&a);
    crate::tests::cleanup(&b);
}

#[test]
fn favorite_only_attachment_shares_blob_survives_backup_gc_and_independent_trash() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let bytes = b"one immutable original attachment";
    let source = root.join("input.tmp");
    fs::write(&source, bytes).unwrap();
    let imported = dispatch(
        json!({"op":"import_file","root":root,"path":source,"name":"shared.bin","kind":"file"}),
    )
    .unwrap();
    fs::remove_file(source).unwrap();
    let mut item = note(8);
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("shared.bin");
    item["size"] = json!(bytes.len());
    item["sha256"] = imported["sha256"].clone();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let saved = favorite(&root, &item);
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    let original = root.join(saved["blobPath"].as_str().unwrap());
    assert_eq!(fs::read(&original).unwrap(), bytes);
    assert_eq!(fs::read_dir(root.join("files")).unwrap().count(), 1);
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(
        maintenance_gc::cleanup(&root, true).unwrap()["removedFiles"],
        0
    );
    initialize(&root).unwrap();
    let backup = root.join("favorite-backup.sqlite3");
    backup::database(&root, &backup).unwrap();
    let copy = Connection::open(&backup).unwrap();
    let body: String = copy
        .query_row("SELECT body FROM favorites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&body).unwrap()["item"],
        saved["item"]
    );
    drop(copy);
    fs::remove_file(backup).unwrap();
    dispatch(json!({"op":"delete_favorites","root":root,"ids":[saved["snapshotId"]]})).unwrap();
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        transfers::queue_favorites(&db, "device:peer", 0, true).unwrap();
        db.execute("UPDATE transfer_jobs SET state='paused'", [])
            .unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(
        maintenance_gc::cleanup(&root, false).unwrap()["removedFiles"],
        0
    );
    initialize(&root).unwrap();
    dispatch(json!({"op":"restore_favorites","root":root,"ids":[saved["snapshotId"]]})).unwrap();
    assert!(
        initialize(&root).unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(fs::read(&original).unwrap(), bytes);
    dispatch(json!({"op":"delete_favorites","root":root,"ids":[saved["snapshotId"]]})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(
        maintenance_gc::cleanup(&root, true).unwrap()["removedFiles"],
        1
    );
    assert!(!original.exists());
    assert!(
        dispatch(json!({"op":"transfers","root":root}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    crate::tests::cleanup(&root);
}

#[test]
fn favorite_metadata_then_blob_then_duplicate_event_publishes_a_visible_delta() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let bytes = b"favorite arrived before its file";
    let source = note(9);
    let original = source["id"].as_str().unwrap();
    let mut item = source.clone();
    item["id"] = json!(favorites::snapshot_id(original));
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("delayed.bin");
    item["size"] = json!(bytes.len());
    item["sha256"] = json!(digest(bytes));
    let event = json!({"id":"favorite-delayed-event-01","type":"favorite","favorite":{"id":original,"value":true,"revision":100,"snapshotId":item["id"],"item":item,"savedAt":"2026-10-22T00:00:00Z"}});
    let first = dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
    assert!(first["favorites"][original]["blobPath"].is_null());
    fs::write(layout::pending(&root).join(digest(bytes)), bytes).unwrap();
    let second =
        dispatch(json!({"op":"apply","root":root,"event":event,"knownRevision":first["revision"]}))
            .unwrap();
    assert_eq!(second["changed"], true);
    assert_eq!(second["delta"], true);
    assert!(second["changeCursor"].as_i64().unwrap() > first["changeCursor"].as_i64().unwrap());
    assert_eq!(
        fs::read(root.join(second["favorites"][original]["blobPath"].as_str().unwrap())).unwrap(),
        bytes
    );
    let third = dispatch(
        json!({"op":"apply","root":root,"event":event,"knownRevision":second["revision"]}),
    )
    .unwrap();
    assert_eq!(third["changed"], false);
    assert_eq!(third["revision"], second["revision"]);
    crate::tests::cleanup(&root);
}
