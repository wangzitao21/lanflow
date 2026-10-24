use super::*;
pub(super) fn root() -> PathBuf {
    std::env::temp_dir().join(format!("lanflow-rust-{}", uuid::Uuid::new_v4()))
}
fn note() -> Value {
    json!({"id":"message-123456789","originId":"device-1234567890","originName":"手机","createdAt":now(),"kind":"text","text":"离线消息","name":"","size":0,"sha256":""})
}
pub(super) fn cleanup(root: &Path) {
    dispatch(json!({"op":"close","root":root})).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pending_sync_tracks_durable_content_including_deletions() {
    let root = root();
    let key = "device:offline-test";
    let pending = || dispatch(json!({"op":"sync_pending","root":root,"key":key})).unwrap();
    assert_eq!(pending(), false);
    let item = note();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    assert_eq!(pending(), true);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute("INSERT INTO cursors(endpoint,pushed) VALUES(?,(SELECT MAX(sequence) FROM events))", [key]).unwrap();
    }
    assert_eq!(pending(), false);
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(pending(), true);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute("INSERT OR IGNORE INTO seen SELECT id,? FROM events", [key]).unwrap();
    }
    assert_eq!(pending(), false);
    cleanup(&root);
}

#[test]
fn incremental_snapshots_include_only_changed_entities_and_survive_restart() {
    let root = root();
    for index in 0..100 {
        let mut item = note();
        item["id"] = json!(format!("history-item-{index:016}"));
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    }
    let before = initialize(&root).unwrap();
    let revision = before["revision"].clone();
    let item = note();
    let change =
        dispatch(json!({"op":"add","root":root,"item":item,"knownRevision":revision})).unwrap();
    assert_eq!(change["delta"], true);
    assert_eq!(change["entries"].as_array().unwrap().len(), 1);
    assert_eq!(change["entries"][0]["item"], item);
    let removed = dispatch(
        json!({"op":"delete","root":root,"id":item["id"],"knownRevision":change["revision"]}),
    )
    .unwrap();
    assert!(removed["entries"].as_array().unwrap().is_empty());
    assert_eq!(removed["removed"][0], item["id"]);
    assert_eq!(removed["deleted"][0], item["id"]);
    dispatch(json!({"op":"close","root":root})).unwrap();
    let after_restart =
        dispatch(json!({"op":"snapshot","root":root,"knownRevision":revision})).unwrap();
    assert_eq!(after_restart["delta"], true);
    assert!(after_restart["entries"].as_array().unwrap().is_empty());
    assert_eq!(
        initialize(&root).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        100
    );
    // Clients without a revision still get the full compatible representation.
    let full = dispatch(json!({"op":"snapshot","root":root})).unwrap();
    assert_eq!(full["entries"].as_array().unwrap().len(), 100);
    cleanup(&root);
}
#[test]
fn startup_preferences_skip_history_and_return_only_appearance() {
    let root = root();
    dispatch(json!({"op":"save_meta","root":root,"value":{
        "appearance":"system","composerFraction":0.24,
        "drafts":{"private":"unsent text"}
    }}))
    .unwrap();
    {
        let shared = database(&root).unwrap();
        shared
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO items VALUES('broken-history',1,'invalid json')",
                [],
            )
            .unwrap();
    }
    let prefs = dispatch(json!({"op":"preferences","root":root})).unwrap();
    assert_eq!(
        prefs,
        json!({"appearance":"system","composerFraction":0.24,"language":null})
    );
    cleanup(&root);
}

#[test]
fn recently_deleted_restores_as_a_new_durable_item_without_reviving_old_ids() {
    let root = root();
    let original = note();
    dispatch(json!({"op":"add","root":root,"item":original})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":original["id"]})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let trash = dispatch(json!({"op":"trash","root":root})).unwrap();
    assert_eq!(trash[0]["item"], original);
    let restored = dispatch(json!({"op":"restore","root":root,"id":original["id"]})).unwrap();
    assert_eq!(restored["entries"].as_array().unwrap().len(), 1);
    assert_ne!(restored["entries"][0]["item"]["id"], original["id"]);
    assert_eq!(restored["entries"][0]["item"]["text"], original["text"]);
    dispatch(json!({"op":"restore","root":root,"id":original["id"]})).unwrap();
    let replay = dispatch(json!({"op":"add","root":root,"item":original})).unwrap();
    assert_eq!(replay["entries"].as_array().unwrap().len(), 1);
    assert!(
        dispatch(json!({"op":"trash","root":root}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    cleanup(&root);
}

#[test]
fn clearing_previews_keeps_originals_drafts_and_partial_transfers() {
    let root = root();
    initialize(&root).unwrap();
    fs::create_dir_all(layout::previews(&root).join("item")).unwrap();
    fs::write(layout::previews(&root).join("item/preview.bin"), b"preview").unwrap();
    fs::write(layout::pending(&root).join("original"), b"original").unwrap();
    fs::write(layout::incoming(&root).join("resume.part"), b"resume").unwrap();
    let before = dispatch(json!({"op":"storage_stats","root":root})).unwrap();
    assert_eq!(before["cache"], 7);
    let after = dispatch(json!({"op":"clear_preview_cache","root":root})).unwrap();
    assert_eq!(after["cache"], 0);
    assert_eq!(after["blobs"], 8);
    assert_eq!(after["partial"], 6);
    assert_eq!(
        fs::read(layout::pending(&root).join("original")).unwrap(),
        b"original"
    );
    cleanup(&root);
}

#[test]
fn transfer_controls_and_offsets_survive_restart_and_deletion_removes_jobs() {
    let root = root();
    let mut item = note();
    item["kind"] = json!("file");
    item["name"] = json!("pending.bin");
    item["size"] = json!(9000000);
    item["sha256"] = json!("a".repeat(64));
    let event = item_event(&item);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        transfers::enqueue(
            &db,
            "device:test",
            "download",
            &json!({"sequence":1,"event":event}),
        )
        .unwrap();
        transfers::progress(
            &db,
            "device:test",
            "download",
            event["id"].as_str().unwrap(),
            4194304,
            None,
        )
        .unwrap();
    }
    dispatch(json!({"op":"transfer_action","root":root,"endpoint":"device:test","direction":"download","eventId":event["id"],"action":"pause"})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let jobs = dispatch(json!({"op":"transfers","root":root})).unwrap();
    assert_eq!(jobs[0]["state"], "paused");
    assert_eq!(jobs[0]["transferred"], 4194304);
    assert_eq!(dispatch(json!({"op":"transfer_blocked","root":root,"endpoint":"device:test","digest":item["sha256"]})).unwrap(),true);
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    assert!(
        dispatch(json!({"op":"transfers","root":root}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    cleanup(&root);
}
#[test]
fn conversations_preserve_old_items_and_merge_after_restart() {
    let root = root();
    let old = note();
    dispatch(json!({"op":"add","root":root,"item":old})).unwrap();
    let category = "conversation-work-001";
    for (revision, name) in [(2, "工作"), (1, "旧分类")] {
        let event = json!({"id":uuid::Uuid::new_v4().simple().to_string(),
            "type":"conversation","conversation":{"id":category,"name":name,"revision":revision}});
        dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
    }
    let mut item = note();
    item["id"] = json!("category-message-001");
    item["conversationId"] = json!(category);
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let state = initialize(&root).unwrap();
    assert_eq!(state["conversations"][category]["name"], "工作");
    assert!(state["entries"][0]["item"].get("conversationId").is_none());
    assert_eq!(state["entries"][1]["item"]["conversationId"], category);
    // Replayed legacy messages still have the exact immutable body.
    dispatch(json!({"op":"add","root":root,"item":old})).unwrap();
    cleanup(&root);
}
#[test]
fn deletion_wins_over_late_arrival_and_restart() {
    let root = root();
    initialize(&root).unwrap();
    let item = note();
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    let state = initialize(&root).unwrap();
    assert!(state["entries"].as_array().unwrap().is_empty());
    assert_eq!(state["deleted"][0], item["id"]);
    cleanup(&root);
}
#[test]
fn profile_merge_is_order_independent_and_history_resolves_current_name() {
    let root = root();
    initialize(&root).unwrap();
    let item = note();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    for (index, name) in [(2, "工作手机"), (1, "旧名字")] {
        dispatch(json!({"op":"apply","root":root,"event":{"id":format!("profile-event-000{index}"),"type":"profile","profile":{"id":item["originId"],"name":name,"avatar":"","revision":index}}})).unwrap();
    }
    let state = initialize(&root).unwrap();
    assert_eq!(
        state["profiles"][item["originId"].as_str().unwrap()]["name"],
        "工作手机"
    );
    assert_eq!(state["entries"].as_array().unwrap().len(), 1);
    cleanup(&root);
}
#[test]
fn unchanged_refresh_is_small_and_copy_receipts_invalidate_it() {
    let root = root();
    initialize(&root).unwrap();
    let item = note();
    let state = dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let revision = state["revision"].clone();
    let unchanged =
        dispatch(json!({"op":"snapshot","root":root,"knownRevision":revision})).unwrap();
    assert_eq!(unchanged["unchanged"], true);
    assert!(unchanged.get("entries").is_none());
    let event = item_event(&item);
    let received =
        dispatch(json!({"op":"apply","root":root,"event":event,"source":"device:other"})).unwrap();
    assert_eq!(received["changed"], true);
    let refreshed =
        dispatch(json!({"op":"snapshot","root":root,"knownRevision":revision})).unwrap();
    assert_eq!(refreshed["entries"][0]["copies"][0], "device:other");
    assert_ne!(refreshed["revision"], revision);
    let duplicate =
        dispatch(json!({"op":"apply","root":root,"event":event,"source":"device:other"})).unwrap();
    assert_eq!(duplicate["changed"], false);
    let unchanged =
        dispatch(json!({"op":"snapshot","root":root,"knownRevision":refreshed["revision"]}))
            .unwrap();
    assert_eq!(unchanged["unchanged"], true);
    cleanup(&root);
}
#[test]
fn file_hash_copy_and_database_commit_are_durable() {
    let root = root();
    initialize(&root).unwrap();
    let file = root.join("source.bin");
    fs::write(&file, vec![37; 1000003]).unwrap();
    let stored = import_file(&root, &file).unwrap();
    assert_eq!(stored["sha256"], hash_file(&file).unwrap());
    fs::remove_file(file).unwrap();
    let mut item = note();
    item["kind"] = json!("file");
    item["name"] = json!("测试.bin");
    item["size"] = stored["size"].clone();
    item["sha256"] = stored["sha256"].clone();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    assert_eq!(
        initialize(&root).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    cleanup(&root);
}
