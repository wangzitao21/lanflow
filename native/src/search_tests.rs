use super::*;

fn note(index: usize, text: &str) -> Value {
    json!({"id":format!("search-message-{index:016}"),"originId":"device-test-origin","originName":"Desktop","createdAt":"2026-10-22T00:00:00.000Z","kind":"text","text":text,"name":"","size":0,"sha256":""})
}

fn found(root: &Path, query: &str) -> Vec<String> {
    let result =
        dispatch(json!({"op":"search_messages","root":root,"query":query,"limit":200})).unwrap();
    result["ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| id.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn short_index_upgrade_is_resumable_and_search_never_omits_unindexed_history() {
    let root = crate::tests::root();
    for index in 0..30 {
        dispatch(json!({"op":"add","root":root,"item":note(index,"索引说明")})).unwrap();
    }
    {
        let shared = database(&root).unwrap();
        shared
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE message_short_search;")
            .unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    let opened = initialize(&root).unwrap();
    assert_eq!(opened["searchIndexPending"], true);
    assert_eq!(found(&root, "说明").len(), 30);
    let partial = dispatch(json!({"op":"search_index_step","root":root,"limit":7})).unwrap();
    assert_eq!(partial["done"], false);
    dispatch(json!({"op":"add","root":root,"item":note(31,"新说明")})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":note(0,"")["id"]})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    for _ in 0..10 {
        if dispatch(json!({"op":"search_index_step","root":root,"limit":7})).unwrap()["done"]
            == true
        {
            break;
        }
    }
    let shared = database(&root).unwrap();
    assert!(!short_search::pending(&shared.lock().unwrap()).unwrap());
    let results = found(&root, "说明");
    assert_eq!(results.len(), 30);
    assert!(!results.contains(&note(0, "")["id"].as_str().unwrap().to_owned()));
    assert!(results.contains(&note(31, "")["id"].as_str().unwrap().to_owned()));
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn trigram_candidates_preserve_literal_unicode_and_short_search_semantics() {
    let root = crate::tests::root();
    let cases = [
        "中文测试消息",
        "literal%_X",
        "a\"b",
        "x*y",
        "[x]",
        "hello OR world",
        "AND",
        "😀界🙂",
        "a\tb",
        "a\nb",
        "zero\0tail",
        "a   b",
        "REPORT.PDF",
        "中文\0说明",
        "A中b",
        "📄报告",
    ];
    let mut items = Vec::new();
    for (index, text) in cases.into_iter().enumerate() {
        let item = note(index, &format!("prefix {text} suffix"));
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        items.push(item);
    }
    for query in cases.into_iter().chain([
        "中",
        "中文",
        "中文测",
        "%_",
        "\"",
        "*",
        "or",
        "report.pdf",
        "tail",
        "fix 中文",
        "does not exist",
        "说明",
        "a中",
        "中B",
        "📄",
        "📄报",
    ]) {
        let mut expected = items
            .iter()
            .filter(|item| {
                item["text"]
                    .as_str()
                    .unwrap()
                    .to_ascii_lowercase()
                    .contains(&query.trim().to_ascii_lowercase())
            })
            .map(|item| item["id"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        expected.sort_by(|a, b| b.cmp(a));
        assert_eq!(found(&root, query), expected, "query: {query:?}");
    }
    let very_long = "a".repeat(1500);
    let long = note(99, &very_long);
    dispatch(json!({"op":"add","root":root,"item":long})).unwrap();
    assert_eq!(found(&root, &very_long), vec![long["id"].as_str().unwrap()]);
    crate::tests::cleanup(&root);
}

#[test]
fn search_migration_rebuilds_existing_messages_and_tracks_delete_restore_and_vacuum() {
    let root = crate::tests::root();
    for index in 0..4 {
        dispatch(json!({"op":"add","root":root,"item":note(index,"historical needle value")}))
            .unwrap();
    }
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute_batch("DROP TRIGGER search_items_INSERT; DROP TRIGGER search_items_DELETE; DROP TRIGGER search_items_UPDATE_DELETE; DROP TRIGGER search_items_UPDATE_INSERT; DROP TABLE message_search; DROP VIEW message_search_content;").unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    assert_eq!(found(&root, "needle").len(), 4);
    let removed = note(1, "historical needle value");
    dispatch(json!({"op":"delete_many","root":root,"ids":[removed["id"],note(2,"")["id"]]}))
        .unwrap();
    assert_eq!(found(&root, "needle").len(), 2);
    dispatch(json!({"op":"restore","root":root,"id":removed["id"]})).unwrap();
    assert_eq!(found(&root, "needle").len(), 3);
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute_batch("VACUUM;").unwrap();
        db.execute(
            "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
            [],
        )
        .unwrap();
        let mut changed = note(3, "changed phrase instead");
        changed["createdAt"] = json!("2026-10-23T00:00:00.000Z");
        db.execute(
            "UPDATE items SET body=? WHERE id=?",
            params![changed.to_string(), changed["id"].as_str().unwrap()],
        )
        .unwrap();
        db.execute(
            "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
            [],
        )
        .unwrap();
    }
    assert_eq!(found(&root, "needle").len(), 2);
    assert_eq!(
        found(&root, "changed phrase"),
        vec![note(3, "")["id"].as_str().unwrap()]
    );
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(found(&root, "needle").len(), 2);
    crate::tests::cleanup(&root);
}

#[test]
fn filename_candidates_and_combined_filters_stay_consistent() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let source = root.join("source.bin");
    fs::write(&source, b"original file bytes").unwrap();
    let blob = dispatch(json!({"op":"import_file","root":root,"path":source,"name":"Sample_report%_X.txt","kind":"file"})).unwrap();
    let mut file = note(1, "");
    file["kind"] = json!("file");
    file["name"] = json!("Sample_report%_X.txt");
    file["size"] = blob["size"].clone();
    file["sha256"] = blob["sha256"].clone();
    dispatch(json!({"op":"add","root":root,"item":file})).unwrap();
    assert_eq!(
        found(&root, "REPORT%_X"),
        vec![file["id"].as_str().unwrap()]
    );
    let filtered = dispatch(json!({"op":"search_messages","root":root,"query":"report%_X","conversationId":"lanflow-self-chat","kind":"file"})).unwrap();
    assert_eq!(filtered["total"], 1);
    let missing = dispatch(json!({"op":"search_messages","root":root,"query":"report%_X","conversationId":"lanflow-self-chat","kind":"text"})).unwrap();
    assert_eq!(missing["total"], 0);
    crate::tests::cleanup(&root);
}

#[test]
fn repeated_legacy_sequences_have_independent_search_documents() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let left = note(1, "unique left token");
    let right = note(2, "unique right token");
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        for item in [&left, &right] {
            db.execute(
                "INSERT INTO items(id,sequence,body) VALUES(?,1,?)",
                params![item["id"].as_str().unwrap(), item.to_string()],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
            [],
        )
        .unwrap();
    }
    assert_eq!(
        found(&root, "left token"),
        vec![left["id"].as_str().unwrap()]
    );
    assert_eq!(
        found(&root, "right token"),
        vec![right["id"].as_str().unwrap()]
    );
    dispatch(json!({"op":"delete","root":root,"id":left["id"]})).unwrap();
    assert_eq!(found(&root, "unique"), vec![right["id"].as_str().unwrap()]);
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert_eq!(found(&root, "unique"), vec![right["id"].as_str().unwrap()]);
    crate::tests::cleanup(&root);
}

#[test]
fn cached_short_search_pages_invalidate_on_edits_and_keep_filters_separate() {
    let root = crate::tests::root();
    for index in 0..12 {
        dispatch(json!({"op":"add","root":root,"item":note(index,"中文 common term")})).unwrap();
    }
    let first =
        dispatch(json!({"op":"search_messages","root":root,"query":"中","limit":5})).unwrap();
    let second =
        dispatch(json!({"op":"search_messages","root":root,"query":"中","limit":5,"offset":5}))
            .unwrap();
    assert_eq!(first["total"], 12);
    assert_eq!(second["total"], 12);
    assert!(
        !first["ids"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| second["ids"].as_array().unwrap().contains(id))
    );
    let filtered =
        dispatch(json!({"op":"search_messages","root":root,"query":"中","favoritesOnly":true}))
            .unwrap();
    assert_eq!(filtered["total"], 0);
    dispatch(json!({"op":"set_favorites","root":root,"ids":[note(0,"")["id"]],"value":true}))
        .unwrap();
    let filtered =
        dispatch(json!({"op":"search_messages","root":root,"query":"中","favoritesOnly":true}))
            .unwrap();
    assert_eq!(filtered["total"], 1);
    dispatch(json!({"op":"delete","root":root,"id":note(11,"")["id"]})).unwrap();
    let updated =
        dispatch(json!({"op":"search_messages","root":root,"query":"中","offset":10})).unwrap();
    assert_eq!(updated["total"], 11);
    assert_eq!(updated["ids"].as_array().unwrap().len(), 1);
    assert_eq!(updated["more"], false);
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert!(
        RESULTS
            .get()
            .unwrap()
            .lock()
            .unwrap()
            .iter()
            .all(|entry| entry.root != root)
    );
    assert_eq!(found(&root, "中").len(), 11);
    crate::tests::cleanup(&root);
}

#[test]
fn broad_search_windows_preserve_totals_and_cross_window_page_boundaries() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let shared = database(&root).unwrap();
    let mut db = shared.lock().unwrap();
    let tx = db.transaction().unwrap();
    for index in 0..5000 {
        let item = note(index, "中文 common broad search");
        storage::insert_item(
            &tx,
            item["id"].as_str().unwrap(),
            index as i64,
            &item.to_string(),
        )
        .unwrap();
    }
    tx.commit().unwrap();
    drop(db);
    let reader = Connection::open_with_flags(
        layout::database(&root),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let first = messages(&root, &reader, &json!({"query":"中","limit":50})).unwrap();
    assert_eq!(first["total"], 5000);
    assert_eq!(first["ids"].as_array().unwrap().len(), 50);
    assert!(
        RESULTS
            .get()
            .unwrap()
            .lock()
            .unwrap()
            .iter()
            .all(|entry| entry.ids.len() <= WINDOW_SIZE as usize)
    );
    let crossing = messages(
        &root,
        &reader,
        &json!({"query":"中","offset":950,"limit":200}),
    )
    .unwrap();
    assert_eq!(crossing["ids"].as_array().unwrap().len(), 200);
    assert_eq!(crossing["ids"][0], note(4049, "")["id"]);
    assert_eq!(crossing["ids"][199], note(3850, "")["id"]);
    let last = messages(
        &root,
        &reader,
        &json!({"query":"中","offset":4950,"limit":200}),
    )
    .unwrap();
    assert_eq!(last["ids"].as_array().unwrap().len(), 50);
    assert_eq!(last["more"], false);
    assert_eq!(
        messages(&root, &reader, &json!({"query":"中","offset":6000})).unwrap()["total"],
        5000
    );
    // Window caching still needs only a short-lived read-only storage connection.
    assert!(reader.execute("DELETE FROM items", []).is_err());
    drop(reader);
    drop(shared);
    crate::tests::cleanup(&root);
}
