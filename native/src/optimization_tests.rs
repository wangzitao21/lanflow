use super::*;

fn note(index: usize) -> Value {
    json!({"id":format!("optimized-message-{index:016}"),"originId":"optimized-device-origin","originName":"Test",
        "createdAt":"2026-10-27T00:00:00Z","kind":"text","text":"中文 A中b\0说明 😀","name":"","size":0,"sha256":""})
}

#[test]
fn batches_commit_once_or_roll_back_every_event_and_can_be_replayed() {
    let root = crate::tests::root();
    let first = item_event(&note(1));
    let before = initialize(&root).unwrap()["changeCursor"].clone();
    let bad = json!({"id":"invalid-batch-event-id","type":"invalid"});
    assert!(dispatch(json!({"op":"apply_batch","root":root,"events":[first,bad]})).is_err());
    let state = initialize(&root).unwrap();
    assert!(state["entries"].as_array().unwrap().is_empty());
    assert_eq!(state["changeCursor"], before);
    let events = json!([first, item_event(&note(2))]);
    assert_eq!(
        dispatch(json!({"op":"apply_batch","root":root,"events":events})).unwrap()["changed"],
        true
    );
    assert_eq!(
        dispatch(json!({"op":"apply_batch","root":root,"events":events})).unwrap()["changed"],
        false
    );
    assert_eq!(
        initialize(&root).unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let oversized = vec![first; 51];
    assert!(dispatch(json!({"op":"apply_batch","root":root,"events":oversized})).is_err());
    crate::tests::cleanup(&root);
}

#[test]
fn history_totals_survive_edits_moves_deletion_and_database_upgrade() {
    let root = crate::tests::root();
    for index in 0..3 {
        dispatch(json!({"op":"add","root":root,"item":note(index)})).unwrap();
    }
    let shared = database(&root).unwrap();
    {
        let db = shared.lock().unwrap();
        let summary = history::summaries(&db, None).unwrap();
        assert_eq!(summary["lanflow-self-chat"]["count"], 3);
        db.execute("UPDATE items SET body=json_set(body,'$.conversationId','optimized-conversation') WHERE id=?",[note(2)["id"].as_str().unwrap()]).unwrap();
        let summary = history::summaries(&db, None).unwrap();
        assert_eq!(summary["lanflow-self-chat"]["count"], 2);
        assert_eq!(summary["optimized-conversation"]["count"], 1);
        db.execute(
            "DELETE FROM items WHERE id=?",
            [note(1)["id"].as_str().unwrap()],
        )
        .unwrap();
        assert_eq!(
            history::summaries(&db, None).unwrap()["lanflow-self-chat"]["count"],
            1
        );
        db.execute_batch("DROP TRIGGER history_total_insert;DROP TRIGGER history_total_delete;DROP TRIGGER history_total_update;DROP TABLE history_totals;").unwrap();
    }
    drop(shared);
    dispatch(json!({"op":"close","root":root})).unwrap();
    let state = initialize(&root).unwrap();
    assert_eq!(state["history"]["lanflow-self-chat"]["count"], 1);
    assert_eq!(state["history"]["optimized-conversation"]["count"], 1);
    crate::tests::cleanup(&root);
}

#[test]
fn deletion_cache_invalidates_when_the_set_changes_without_changing_its_size() {
    let root = crate::tests::root();
    let shared = database(&root).unwrap();
    {
        let db = shared.lock().unwrap();
        db.execute("INSERT INTO deleted VALUES('deleted-original-id')", [])
            .unwrap();
        let old = reconciliation::deletion_state(&db).unwrap();
        db.execute("UPDATE deleted SET id='deleted-replaced-id'", [])
            .unwrap();
        let new = reconciliation::deletion_state(&db).unwrap();
        assert_eq!(old["count"], new["count"]);
        assert_ne!(old["hash"], new["hash"]);
        assert_eq!(new, reconciliation::deletion_state(&db).unwrap());
    }
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn transfer_feed_is_bounded_filtered_incremental_and_reports_removals() {
    let root = crate::tests::root();
    let shared = database(&root).unwrap();
    {
        let db = shared.lock().unwrap();
        for index in 0..450 {
            let mut item = note(index);
            item["kind"] = json!("file");
            item["size"] = json!(1);
            item["sha256"] = json!(digest(b"x"));
            item["name"] = json!("a.bin");
            let event = item_event(&item);
            transfers::enqueue(
                &db,
                if index < 401 { "device:a" } else { "device:b" },
                "upload",
                &json!({"sequence":index+1,"event":event}),
            )
            .unwrap();
        }
        let mut after = 0;
        let mut count = 0;
        loop {
            let page =
                transfers::updates(&db, &json!({"after":after,"endpoints":["device:a"]})).unwrap();
            assert!(page["items"].as_array().unwrap().len() <= 200);
            count += page["items"].as_array().unwrap().len();
            after = page["cursor"].as_i64().unwrap();
            if page["more"] != true {
                break;
            }
        }
        assert_eq!(count, 401);
        assert!(transfers::updates(&db,&json!({"after":after,"endpoints":["device:a"]})).unwrap()["items"].as_array().unwrap().is_empty());
        let event: String=db.query_row("SELECT event_id FROM transfer_jobs WHERE endpoint='device:a' ORDER BY sequence LIMIT 1",[],|r|r.get(0)).unwrap();
        transfers::complete(&db, "device:a", "upload", &event, 1).unwrap();
        let page =
            transfers::updates(&db, &json!({"after":after,"endpoints":["device:a"]})).unwrap();
        assert_eq!(page["removed"], json!([format!("device:a:upload:{event}")]));
        assert!(page["items"].as_array().unwrap().is_empty());
        let mut fresh = 0;
        let mut fresh_count = 0;
        let mut initial = Value::Null;
        loop {
            let page = transfers::updates(
                &db,
                &json!({"after":fresh,"endpoints":["device:a"],"initialThrough":initial}),
            )
            .unwrap();
            assert!(page["removed"].as_array().unwrap().is_empty());
            fresh_count += page["items"].as_array().unwrap().len();
            fresh = page["cursor"].as_i64().unwrap();
            initial = page["initialThrough"].clone();
            if page["more"] != true {
                break;
            }
        }
        assert_eq!(fresh_count, 400);
        let mut loading =
            transfers::updates(&db, &json!({"after":0,"endpoints":["device:a"]})).unwrap();
        let completing = loading["items"][0]["eventId"].as_str().unwrap().to_owned();
        transfers::complete(&db, "device:a", "upload", &completing, 1).unwrap();
        let mut removed = Vec::new();
        while loading["more"] == true {
            loading = transfers::updates(&db, &json!({"after":loading["cursor"],"endpoints":["device:a"],"initialThrough":loading["initialThrough"]})).unwrap();
            removed.extend(loading["removed"].as_array().unwrap().clone());
        }
        assert_eq!(
            removed,
            json!([format!("device:a:upload:{completing}")])
                .as_array()
                .unwrap()
                .clone()
        );
        assert_eq!(
            transfers::updates(&db, &json!({"after":i64::MAX,"endpoints":["device:a"]})).unwrap()["reset"],
            true
        );
    }
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn long_unicode_index_keeps_literal_short_queries_and_edits_correct() {
    let root = crate::tests::root();
    let mut item = note(0);
    item["text"] = json!(format!("{}A中b\0说明😀", "中".repeat(19_980)));
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    for query in ["中", "a中", "说明", "😀"] {
        let result = dispatch(json!({"op":"search_messages","root":root,"query":query})).unwrap();
        assert_eq!(result["total"], 1, "{query}");
    }
    dispatch(json!({"op":"edit_message","root":root,"id":item["id"],"text":"替换内容","name":""}))
        .unwrap();
    assert_eq!(
        dispatch(json!({"op":"search_messages","root":root,"query":"说明"})).unwrap()["total"],
        0
    );
    assert_eq!(
        dispatch(json!({"op":"search_messages","root":root,"query":"替换"})).unwrap()["total"],
        1
    );
    crate::tests::cleanup(&root);
}
