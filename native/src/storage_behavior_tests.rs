use super::*;

#[test]
fn storage_totals_include_recovered_edits_and_other_files_without_clearing_them() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    fs::create_dir_all(root.join("system/recovered")).unwrap();
    fs::create_dir_all(layout::previews(&root)).unwrap();
    fs::write(root.join("system/recovered/edited.bin"), vec![7; 8192]).unwrap();
    fs::write(root.join("kept-user-file.bin"), vec![9; 4096]).unwrap();
    fs::write(layout::previews(&root).join("preview.bin"), vec![3; 1024]).unwrap();
    let before = maintenance::storage(&root, false).unwrap();
    assert_eq!(before["recovered"], 8192);
    assert!(before["other"].as_u64().unwrap() >= 4096);
    let sum: u64 = [
        "blobs",
        "cache",
        "partial",
        "database",
        "recovered",
        "other",
    ]
    .iter()
    .map(|key| before[*key].as_u64().unwrap())
    .sum();
    assert_eq!(before["total"], sum);
    let after = maintenance::storage(&root, true).unwrap();
    assert_eq!(after["cache"], 0);
    assert_eq!(after["recovered"], 8192);
    assert_eq!(
        fs::read(root.join("system/recovered/edited.bin")).unwrap(),
        vec![7; 8192]
    );
    assert!(root.join("kept-user-file.bin").exists());
    crate::tests::cleanup(&root);
}

fn note(index: usize) -> Value {
    json!({"id":format!("message-{index:016}"),"originId":"device-test-origin","originName":"Desktop","createdAt":"2026-10-22T00:00:00Z","kind":"text","text":format!("Message {index}"),"name":"","size":0,"sha256":""})
}
fn file_record(index: usize) -> Value {
    let mut item = note(index);
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("report.bin");
    item["size"] = json!(10);
    item["sha256"] = json!("a".repeat(64));
    json!({"sequence":index+1,"event":item_event(&item)})
}

#[test]
fn content_cursor_excludes_receipts_but_snapshot_deltas_keep_them() {
    let root = crate::tests::root();
    let item = note(1);
    let first = dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let shared = database(&root).unwrap();
    let mut db = shared.lock().unwrap();
    let cursor = storage::change_cursor(&db).unwrap();
    let revision = first["revision"].as_i64().unwrap();

    // Receiving the same durable event from a second device only adds a receipt.
    assert!(apply(&root, &mut db, &item_event(&item), Some("device:peer")).unwrap());
    assert_eq!(storage::change_cursor(&db).unwrap(), cursor);
    let delta = snapshot_since(&db, Some(revision)).unwrap();
    assert_eq!(delta["delta"], true);
    assert!(delta["revision"].as_i64().unwrap() > revision);
    assert_eq!(delta["changeCursor"], cursor);
    assert_eq!(delta["entries"][0]["copies"], json!(["device:peer"]));
    db.execute(
        "UPDATE copies SET endpoint='device:renamed' WHERE endpoint='device:peer'",
        [],
    )
    .unwrap();
    db.execute("DELETE FROM copies", []).unwrap();
    assert_eq!(storage::change_cursor(&db).unwrap(), cursor);
    drop(db);
    drop(shared);

    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(
        dispatch(json!({"op":"snapshot","root":root})).unwrap()["changeCursor"],
        cursor
    );
    crate::tests::cleanup(&root);
}

#[test]
fn content_cursor_keeps_every_publishable_event_and_rolls_back_atomically() {
    let root = crate::tests::root();
    let shared = database(&root).unwrap();
    let mut db = shared.lock().unwrap();
    let item = note(2);
    let mut cursor = storage::change_cursor(&db).unwrap();
    for event in [
        item_event(&item),
        json!({"id":"profile-content-event","type":"profile","profile":{"id":"device-test-origin","name":"Renamed","avatar":"","revision":1}}),
        json!({"id":"conversation-content-event","type":"conversation","conversation":{"id":"conversation-content","name":"Messages","revision":1}}),
        json!({"id":"favorite-content-event","type":"favorite","favorite":{"id":item["id"],"value":true,"revision":1}}),
        json!({"id":"delete-content-event","type":"delete","target":item["id"]}),
    ] {
        assert!(apply(&root, &mut db, &event, None).unwrap());
        let next = storage::change_cursor(&db).unwrap();
        assert!(next > cursor, "missing notification for {}", event["type"]);
        cursor = next;
        assert!(!apply(&root, &mut db, &event, None).unwrap());
        assert_eq!(storage::change_cursor(&db).unwrap(), cursor);
    }
    {
        let tx = db.transaction().unwrap();
        tx.execute(
            "INSERT INTO events(id,body) VALUES('rolled-back-event','{}')",
            [],
        )
        .unwrap();
        assert!(storage::change_cursor(&tx).unwrap() > cursor);
        tx.rollback().unwrap();
    }
    assert_eq!(storage::change_cursor(&db).unwrap(), cursor);
    drop(db);
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn content_cursor_upgrade_preserves_the_deployed_watch_baseline() {
    let root = crate::tests::root();
    layout::prepare(&root).unwrap();
    let item = note(3);
    let event = item_event(&item);
    {
        // A deployed database with a high snapshot revision and very few events.
        let db = Connection::open(layout::database(&root)).unwrap();
        db.execute_batch(
            "CREATE TABLE revision(value INTEGER NOT NULL);
             INSERT INTO revision VALUES(900000);
             CREATE TABLE items(id TEXT PRIMARY KEY,sequence INTEGER NOT NULL,body TEXT NOT NULL);
             CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,body TEXT NOT NULL);",
        )
        .unwrap();
        db.execute(
            "INSERT INTO items VALUES(?,1,?)",
            params![
                item["id"].as_str().unwrap(),
                serde_json::to_string(&item).unwrap()
            ],
        )
        .unwrap();
        db.execute(
            "INSERT INTO events(id,body) VALUES(?,?)",
            params![
                event["id"].as_str().unwrap(),
                serde_json::to_string(&event).unwrap()
            ],
        )
        .unwrap();
    }
    {
        let shared = database(&root).unwrap();
        let mut db = shared.lock().unwrap();
        assert_eq!(storage::change_cursor(&db).unwrap(), 900000);
        assert!(apply(&root, &mut db, &event, Some("device:peer")).unwrap());
        assert_eq!(storage::change_cursor(&db).unwrap(), 900000);
        assert!(apply(&root, &mut db, &item_event(&note(4)), None).unwrap());
        assert!(storage::change_cursor(&db).unwrap() > 900000);
    }
    let first = dispatch(json!({"op":"snapshot","root":root})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let reopened = dispatch(json!({"op":"snapshot","root":root})).unwrap();
    assert_eq!(reopened["changeCursor"], first["changeCursor"]);
    assert_eq!(reopened["revision"], first["revision"]);
    crate::tests::cleanup(&root);
}

#[test]
fn content_cursor_notifies_once_for_repaired_and_recovered_attachments() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let bytes = b"an attachment that arrived without another event";
    let hash = digest(bytes);
    let mut item = note(5);
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("repaired.bin");
    item["size"] = json!(bytes.len());
    item["sha256"] = json!(hash);
    fs::write(layout::pending(&root).join(&hash), bytes).unwrap();
    let first = dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let path = attachments::path(&root, &hash);
    fs::remove_file(&path).unwrap();
    fs::write(layout::pending(&root).join(&hash), bytes).unwrap();
    let repaired = dispatch(json!({"op":"apply","root":root,"event":item_event(&item),"knownRevision":first["revision"]})).unwrap();
    assert_eq!(repaired["changed"], true);
    assert_eq!(repaired["delta"], true);
    assert!(repaired["changeCursor"].as_i64().unwrap() > first["changeCursor"].as_i64().unwrap());
    assert_eq!(repaired["entries"][0]["item"]["id"], item["id"]);
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let same = dispatch(json!({"op":"apply","root":root,"event":item_event(&item),"knownRevision":repaired["revision"]})).unwrap();
    assert_eq!(same["changed"], false);
    assert_eq!(same["changeCursor"], repaired["changeCursor"]);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        // The file move completed before a crash, but its ready transaction did not.
        db.execute("UPDATE attachment_files SET ready=0", [])
            .unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    let recovered = dispatch(json!({"op":"apply","root":root,"event":item_event(&item),"knownRevision":repaired["revision"]})).unwrap();
    assert_eq!(recovered["changed"], true);
    assert!(
        recovered["changeCursor"].as_i64().unwrap() > repaired["changeCursor"].as_i64().unwrap()
    );
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let same = dispatch(json!({"op":"apply","root":root,"event":item_event(&item),"knownRevision":recovered["revision"]})).unwrap();
    assert_eq!(same["changed"], false);
    assert_eq!(same["changeCursor"], recovered["changeCursor"]);
    crate::tests::cleanup(&root);
}

#[test]
fn completed_transfers_are_bounded_paged_durable_and_never_requeued() {
    let root = crate::tests::root();
    {
        let shared = database(&root).unwrap();
        let mut db = shared.lock().unwrap();
        let tx = db.transaction().unwrap();
        for index in 0..503 {
            let record = file_record(index);
            transfers::enqueue(&tx, "device:peer", "upload", &record).unwrap();
            transfers::complete(
                &tx,
                "device:peer",
                "upload",
                record["event"]["id"].as_str().unwrap(),
                10,
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert!(
        dispatch(json!({"op":"transfers","root":root}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    let first = dispatch(json!({"op":"transfers_page","root":root,"limit":200})).unwrap();
    assert_eq!(first["total"], 500);
    assert_eq!(first["items"].as_array().unwrap().len(), 200);
    assert_eq!(first["more"], true);
    assert_eq!(first["nextOffset"], 200);
    let latest = &first["items"][0];
    assert_eq!(latest["state"], "completed");
    assert_eq!(latest["transferred"], 10);
    assert!(latest["completedAt"].as_i64().unwrap() > 0);
    assert_eq!(dispatch(json!({"op":"transfer_action","root":root,"endpoint":latest["endpoint"],"direction":latest["direction"],"eventId":latest["eventId"],"action":"retry"})).unwrap(), false);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        let record = file_record(502);
        transfers::enqueue(&db, "device:peer", "upload", &record).unwrap();
        assert!(
            !transfers::active(
                &db,
                "device:peer",
                "upload",
                record["event"]["id"].as_str().unwrap()
            )
            .unwrap()
        );
    }
    let second =
        dispatch(json!({"op":"transfers_page","root":root,"offset":200,"limit":200})).unwrap();
    let last =
        dispatch(json!({"op":"transfers_page","root":root,"offset":400,"limit":200})).unwrap();
    assert_eq!(last["items"].as_array().unwrap().len(), 100);
    assert_eq!(last["more"], false);
    let ids: std::collections::HashSet<_> = [&first, &second, &last]
        .into_iter()
        .flat_map(|page| {
            page["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| item["eventId"].as_str().unwrap())
        })
        .collect();
    assert_eq!(ids.len(), 500);
    crate::tests::cleanup(&root);
}

#[test]
fn retry_deadlines_and_error_categories_survive_restart_and_pause_wins_over_progress() {
    let root = crate::tests::root();
    let record = file_record(1);
    let event_id = record["event"]["id"].as_str().unwrap();
    let before = Utc::now().timestamp();
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        transfers::enqueue(&db, "device:peer", "download", &record).unwrap();
        let error = errors::api(503, "Try again later");
        transfers::progress(
            &db,
            "device:peer",
            "download",
            event_id,
            4,
            Some(error.as_ref()),
        )
        .unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    let jobs = dispatch(json!({"op":"transfers","root":root})).unwrap();
    assert_eq!(jobs[0]["state"], "failed");
    assert_eq!(jobs[0]["errorCategory"], "busy");
    assert!(jobs[0]["retryAfter"].as_i64().unwrap() >= before + 4);
    dispatch(json!({"op":"transfer_action","root":root,"endpoint":"device:peer","direction":"download","eventId":event_id,"action":"pause"})).unwrap();
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        transfers::progress(&db, "device:peer", "download", event_id, 10, None).unwrap();
        transfers::complete(&db, "device:peer", "download", event_id, 10).unwrap();
    }
    let jobs = dispatch(json!({"op":"transfers","root":root})).unwrap();
    assert_eq!(jobs[0]["state"], "paused");
    assert_eq!(jobs[0]["transferred"], 4);
    assert!(jobs[0]["retryAfter"].is_null());
    assert!(jobs[0]["errorCategory"].is_null());
    crate::tests::cleanup(&root);
}

#[test]
fn local_favorites_ignore_missing_items_deduplicate_and_remain_independent_of_restore() {
    let root = crate::tests::root();
    let item = note(1);
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let first = dispatch(json!({"op":"set_favorites","root":root,"ids":[item["id"],item["id"],"missing-message-0001"],"value":true})).unwrap();
    let revision = first["revision"].clone();
    let same = dispatch(json!({"op":"set_favorites","root":root,"ids":[item["id"]],"value":true}))
        .unwrap();
    assert_eq!(same["revision"], revision);
    assert_eq!(same["favorites"].as_object().unwrap().len(), 1);
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    let restored = dispatch(json!({"op":"restore","root":root,"id":item["id"]})).unwrap();
    let new_id = restored["entries"][0]["item"]["id"].as_str().unwrap();
    assert_ne!(new_id, item["id"]);
    assert!(restored["favorites"][new_id].is_null());
    assert_eq!(
        restored["favorites"][item["id"].as_str().unwrap()]["value"],
        true
    );
    let favorites =
        dispatch(json!({"op":"search_messages","root":root,"favoritesOnly":true})).unwrap();
    assert_eq!(favorites["ids"], json!([]));
    crate::tests::cleanup(&root);
}

#[test]
fn search_is_literal_filtered_paginated_and_orders_real_instants() {
    let root = crate::tests::root();
    for index in 1..=3 {
        let mut item = note(index);
        item["text"] = json!(if index == 1 {
            "Budget %_ 方案"
        } else {
            "BUDGET summary"
        });
        item["createdAt"] = json!(match index {
            1 => "2026-10-22T09:00:00+08:00",
            2 => "2026-10-22T02:00:00Z",
            _ => "2026-10-22T03:00:00Z",
        });
        if index == 3 {
            item["conversationId"] = json!("conversation-work-001");
        }
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    }
    let literal = dispatch(json!({"op":"search_messages","root":root,"query":"%_"})).unwrap();
    assert_eq!(literal["ids"], json!([note(1)["id"]]));
    let chinese = dispatch(json!({"op":"search_messages","root":root,"query":"方案"})).unwrap();
    assert_eq!(chinese["total"], 1);
    let first = dispatch(json!({"op":"search_messages","root":root,"query":"budget","conversationId":"lanflow-self-chat","kind":"text","originId":"device-test-origin","limit":1})).unwrap();
    assert_eq!(first["ids"], json!([note(2)["id"]]));
    assert_eq!(first["total"], 2);
    assert_eq!(first["more"], true);
    let next = dispatch(json!({"op":"search_messages","root":root,"query":"budget","conversationId":"lanflow-self-chat","offset":1,"limit":1})).unwrap();
    assert_eq!(next["ids"], json!([note(1)["id"]]));
    let dated = dispatch(json!({"op":"search_messages","root":root,"afterDate":"2026-10-22T01:00:00Z","beforeDate":"2026-10-22T02:00:00Z"})).unwrap();
    assert_eq!(dated["ids"], json!([note(1)["id"]]));
    assert!(dispatch(json!({"op":"search_messages","root":root,"afterDate":"invalid"})).is_err());
    let shared = database(&root).unwrap();
    let db = shared.lock().unwrap();
    let read_root = root.clone();
    let (sent, result) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        sent.send(dispatch(
            json!({"op":"search_messages","root":read_root,"query":"budget"}),
        ))
        .unwrap()
    });
    assert_eq!(
        result
            .recv_timeout(Duration::from_secs(3))
            .expect("search must not wait on the write connection mutex")
            .unwrap()["total"],
        3
    );
    reader.join().unwrap();
    let plan: String = db.query_row("EXPLAIN QUERY PLAN SELECT id FROM items WHERE json_valid(body) AND COALESCE(json_extract(body,'$.conversationId'),'lanflow-self-chat')=? ORDER BY julianday(json_extract(body,'$.createdAt')) DESC,id DESC", ["lanflow-self-chat"], |r| r.get(3)).unwrap();
    assert!(plan.contains("items_conversation_date"), "{plan}");
    drop(db);
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn cancelled_tokens_cannot_restart_or_mutate() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let first = sync_control::begin(&root, "device:peer").unwrap();
    let run = sync_control::Run::acquire(&root, "device:peer", &first).unwrap();
    assert!(sync_control::Run::acquire(&root, "device:peer", &first).is_err());
    sync_control::cancel(&root, Some("device:peer"));
    assert!(run.mutation().is_err());
    assert!(sync_control::Run::acquire(&root, "device:peer", &first).is_err());
    let second = sync_control::begin(&root, "device:peer").unwrap();
    let next = sync_control::Run::acquire(&root, "device:peer", &second).unwrap();
    drop(run);
    assert!(
        next.check().is_ok(),
        "dropping a stale run cannot remove a newer run"
    );
    drop(next);
    assert!(sync_control::Run::acquire(&root, "device:peer", &second).is_err());
    crate::tests::cleanup(&root);
}

#[test]
fn legacy_change_pages_filter_optional_events_without_empty_more_pages() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":note(1)})).unwrap();
    for index in 0..55 {
        dispatch(
            json!({"op":"set_favorites","root":root,"ids":[note(1)["id"]],"value":index%2==0}),
        )
        .unwrap();
    }
    dispatch(json!({"op":"add","root":root,"item":note(2)})).unwrap();
    let legacy = dispatch(json!({"op":"page","root":root,"after":0})).unwrap();
    assert_eq!(legacy["items"].as_array().unwrap().len(), 2);
    assert_eq!(legacy["items"][1]["event"]["item"]["id"], note(2)["id"]);
    assert_eq!(legacy["cursor"], legacy["items"][1]["sequence"]);
    assert_eq!(legacy["more"], false);
    let modern =
        dispatch(json!({"op":"page","root":root,"after":0,"capabilities":"favorites"})).unwrap();
    assert_eq!(modern["items"].as_array().unwrap().len(), 50);
    assert_eq!(modern["items"][1]["event"]["type"], "favorite");
    assert_eq!(modern["more"], true);
    let empty = dispatch(json!({"op":"page","root":root,"after":legacy["cursor"]})).unwrap();
    assert!(empty["items"].as_array().unwrap().is_empty());
    assert_eq!(empty["cursor"], legacy["cursor"]);
    assert_eq!(empty["more"], false);
    crate::tests::cleanup(&root);
}
