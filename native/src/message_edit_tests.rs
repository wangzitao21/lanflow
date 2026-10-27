use super::*;
fn item() -> Value {
    json!({"id":"message-edit-original","originId":"device-edit-original","originName":"Phone","createdAt":"2026-10-25T00:00:00Z","kind":"text","text":"original","name":"","size":0,"sha256":""})
}
fn edit(id: &str, revision: i64, text: &str) -> Value {
    json!({"id":id,"type":"edit","target":"message-edit-original","revision":revision,"text":text,"name":""})
}

#[test]
fn edits_merge_before_or_after_the_original_and_do_not_revive_deletions() {
    for reverse in [false, true] {
        let root = crate::tests::root();
        let original = item_event(&item());
        let first = edit("message-edit-event-a", 10, "first");
        let second = edit("message-edit-event-b", 10, "winner");
        for event in if reverse {
            vec![second.clone(), first, original.clone()]
        } else {
            vec![original.clone(), first, second.clone()]
        } {
            dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
        }
        let state = initialize(&root).unwrap();
        assert_eq!(state["entries"][0]["item"]["text"], "winner");
        let sequence = state["entries"][0]["sequence"].clone();
        dispatch(json!({"op":"apply","root":root,"event":original})).unwrap();
        assert_eq!(
            initialize(&root).unwrap()["entries"][0]["sequence"],
            sequence
        );
        dispatch(json!({"op":"delete","root":root,"id":"message-edit-original"})).unwrap();
        dispatch(json!({"op":"apply","root":root,"event":edit("message-edit-event-c",11,"late")}))
            .unwrap();
        assert!(
            initialize(&root).unwrap()["entries"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        crate::tests::cleanup(&root);
    }
}

#[test]
fn old_message_receipts_cannot_mark_an_edited_message_as_synced() {
    let root = crate::tests::root();
    let original = item_event(&item());
    dispatch(json!({"op":"apply","root":root,"event":original,"source":"device:phone"})).unwrap();
    let changed = edit("message-edit-event-a", 10, "changed");
    let state = dispatch(json!({"op":"apply","root":root,"event":changed})).unwrap();
    assert!(
        state["entries"][0]["copies"]
            .as_array()
            .is_none_or(Vec::is_empty)
    );
    let state =
        dispatch(json!({"op":"apply","root":root,"event":original,"source":"device:phone"}))
            .unwrap();
    assert!(
        state["entries"][0]["copies"]
            .as_array()
            .is_none_or(Vec::is_empty)
    );
    let state = dispatch(json!({"op":"apply","root":root,"event":changed,"source":"device:phone"}))
        .unwrap();
    assert_eq!(state["entries"][0]["copies"], json!(["device:phone"]));
    crate::tests::cleanup(&root);
}

#[test]
fn edit_is_atomic_validated_and_filtered_for_older_peers() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
    assert!(
        dispatch(json!({"op":"edit_message","root":root,"id":"message-edit-original","text":""}))
            .is_err()
    );
    let changed = dispatch(
        json!({"op":"edit_message","root":root,"id":"message-edit-original","text":"updated"}),
    )
    .unwrap();
    assert_eq!(changed["entries"][0]["item"]["text"], "updated");
    let legacy = dispatch(json!({"op":"page","root":root,"after":0})).unwrap();
    assert_eq!(legacy["items"].as_array().unwrap().len(), 1);
    let modern =
        dispatch(json!({"op":"page","root":root,"after":0,"capabilities":"messageEdits"})).unwrap();
    assert_eq!(modern["items"].as_array().unwrap().len(), 2);
    crate::tests::cleanup(&root);
}

fn branch(id: &str, parents: &[&str], text: &str) -> Value {
    let mut value = edit(id, 100, text);
    value["parents"] = json!(parents);
    value
}

#[test]
fn concurrent_edits_are_retained_until_an_explicit_resolution_reaches_every_replica() {
    for reverse in [false, true] {
        let root = crate::tests::root();
        dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
        let a = branch("concurrent-edit-a", &[], "choice A");
        let b = branch("concurrent-edit-b", &[], "choice B");
        for event in if reverse {
            vec![b.clone(), a.clone()]
        } else {
            vec![a.clone(), b.clone()]
        } {
            dispatch(json!({"op":"apply","root":root,"event":event,"source":"device:remote"}))
                .unwrap();
        }
        let state = initialize(&root).unwrap();
        assert_eq!(state["conflicts"].as_array().unwrap().len(), 1);
        assert_eq!(
            state["conflicts"][0]["versions"].as_array().unwrap().len(),
            2
        );
        assert!(
            state["entries"][0]["copies"]
                .as_array()
                .is_none_or(Vec::is_empty)
        );
        dispatch(json!({"op":"close","root":root})).unwrap();
        let state = initialize(&root).unwrap();
        assert_eq!(state["conflicts"].as_array().unwrap().len(), 1);
        let resolved = dispatch(json!({"op":"resolve_message","root":root,"id":item()["id"],"heads":state["conflicts"][0]["heads"],"versionId":"concurrent-edit-a"})).unwrap();
        assert!(resolved["conflicts"].as_array().unwrap().is_empty());
        assert_eq!(resolved["entries"][0]["item"]["text"], "choice A");
        // Replaying either losing branch must never resurrect the issue.
        dispatch(json!({"op":"apply","root":root,"event":b})).unwrap();
        assert!(
            initialize(&root).unwrap()["conflicts"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        crate::tests::cleanup(&root);
    }
}

#[test]
fn sequential_and_identical_edits_are_not_conflicts_even_when_reordered() {
    for reverse in [false, true] {
        let root = crate::tests::root();
        dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
        let a = branch("sequential-edit-a", &[], "first");
        let b = branch("sequential-edit-b", &["sequential-edit-a"], "second");
        for event in if reverse { vec![b, a] } else { vec![a, b] } {
            dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
        }
        let identical = branch("sequential-edit-c", &["sequential-edit-a"], "second");
        dispatch(json!({"op":"apply","root":root,"event":identical})).unwrap();
        let state = initialize(&root).unwrap();
        assert!(state["conflicts"].as_array().unwrap().is_empty());
        assert_eq!(state["entries"][0]["item"]["text"], "second");
        crate::tests::cleanup(&root);
    }
}

#[test]
fn stale_resolution_cannot_overwrite_a_new_version_and_deletion_clears_every_branch() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
    for (id, text) in [("stale-version-aa", "a"), ("stale-version-bb", "b")] {
        dispatch(json!({"op":"apply","root":root,"event":branch(id,&[],text)})).unwrap();
    }
    let old = initialize(&root).unwrap()["conflicts"][0]["heads"].clone();
    dispatch(json!({"op":"apply","root":root,"event":branch("stale-version-cc",&[],"c")})).unwrap();
    assert!(dispatch(json!({"op":"resolve_message","root":root,"id":item()["id"],"heads":old,"text":"merged","name":""})).is_err());
    assert_eq!(
        initialize(&root).unwrap()["conflicts"][0]["versions"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    dispatch(json!({"op":"delete","root":root,"id":item()["id"]})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":branch("stale-version-dd",&[],"late")}))
        .unwrap();
    let state = initialize(&root).unwrap();
    assert!(state["entries"].as_array().unwrap().is_empty());
    assert!(state["conflicts"].as_array().unwrap().is_empty());
    crate::tests::cleanup(&root);
}

#[test]
fn resolutions_can_arrive_before_their_parents_and_concurrent_resolutions_remain_visible() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
    let a = branch("parent-version-aa", &[], "a");
    let b = branch("parent-version-bb", &[], "b");
    let resolution = branch(
        "resolved-version-a",
        &["parent-version-aa", "parent-version-bb"],
        "chosen A",
    );
    for event in [resolution, a, b] {
        dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
    }
    let state = initialize(&root).unwrap();
    assert!(state["conflicts"].as_array().unwrap().is_empty());
    assert_eq!(state["entries"][0]["item"]["text"], "chosen A");
    let other = branch(
        "resolved-version-b",
        &["parent-version-aa", "parent-version-bb"],
        "chosen B",
    );
    dispatch(json!({"op":"apply","root":root,"event":other})).unwrap();
    assert_eq!(
        initialize(&root).unwrap()["conflicts"][0]["versions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    crate::tests::cleanup(&root);
}

#[test]
fn legacy_database_upgrade_keeps_the_current_edit_as_a_single_starting_version() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":item()})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":edit("legacy-version-aa",1,"old current")}))
        .unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    {
        let db = Connection::open(layout::database(&root)).unwrap();
        short_search::register(&db).unwrap();
        db.execute_batch("DROP TABLE message_edit_heads; DROP TABLE message_edit_parents; DROP TABLE message_edit_versions; DELETE FROM meta WHERE key='edit_graph_ready'; UPDATE items SET body=json_remove(body,'$.editHeads');").unwrap();
    }
    let state = initialize(&root).unwrap();
    assert!(state["conflicts"].as_array().unwrap().is_empty());
    assert_eq!(state["entries"][0]["item"]["text"], "old current");
    assert_eq!(
        state["entries"][0]["item"]["editHeads"],
        json!(["legacy-version-aa"])
    );
    let next = dispatch(json!({"op":"edit_message","root":root,"id":item()["id"],"parents":["legacy-version-aa"],"text":"new edit"})).unwrap();
    assert!(next["conflicts"].as_array().unwrap().is_empty());
    assert_eq!(next["entries"][0]["item"]["text"], "new edit");
    crate::tests::cleanup(&root);
}
