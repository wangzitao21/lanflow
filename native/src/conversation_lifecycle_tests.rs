use super::*;
use crate::tests::{cleanup, root};

fn note(id: &str, owner: &str) -> Value {
    json!({"id":id,"conversationId":owner,"originId":"offline-device-123","originName":"Offline phone","createdAt":"2025-01-01T00:00:00Z","kind":"text","text":"Offline content","name":"","size":0,"sha256":""})
}

fn close_event(owner: &str) -> Value {
    json!({"id":"closed-conversation-event","type":"conversation","conversation":{"id":owner,"name":"Work","revision":10,"deleted":true}})
}

#[test]
fn closed_conversation_quarantines_late_messages_in_either_order() {
    for marker_first in [true, false] {
        let root = root();
        let owner = "old-work-conversation";
        let item = note("offline-message-123", owner);
        let changes = if marker_first {
            vec![close_event(owner), item_event(&item)]
        } else {
            vec![item_event(&item), close_event(owner)]
        };
        for event in changes {
            dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
            if !marker_first && event["type"] == "item" {
                dispatch(json!({"op":"set_favorites","root":root,"ids":[item["id"]],"value":true}))
                    .unwrap();
            }
        }
        let snapshot = initialize(&root).unwrap();
        assert!(snapshot["entries"].as_array().unwrap().is_empty());
        assert_eq!(snapshot["recoveryCount"], 1);
        let recovery = dispatch(json!({"op":"recovery_page","root":root})).unwrap();
        assert_eq!(recovery["items"][0]["item"], item);
        assert_eq!(recovery["items"][0]["conversationName"], "Work");
        dispatch(json!({"op":"apply","root":root,"event":item_event(&item)})).unwrap();
        assert_eq!(initialize(&root).unwrap()["recoveryCount"], 1);
        assert!(
            dispatch(json!({"op":"add","root":root,"item":note("local-message-1234",owner)}))
                .is_err()
        );
        dispatch(json!({"op":"close","root":root})).unwrap();
        assert_eq!(initialize(&root).unwrap()["recoveryCount"], 1);
        if !marker_first {
            let restored =
                dispatch(json!({"op":"recover_message","root":root,"id":item["id"]})).unwrap();
            let new_id = restored["entries"][0]["item"]["id"].as_str().unwrap();
            assert_eq!(restored["favorites"][new_id]["value"], true);
        }
        cleanup(&root);
    }
}

#[test]
fn known_deletions_stay_deleted_and_same_name_replacement_is_independent() {
    let root = root();
    let old = "old-work-conversation";
    let new = "new-work-conversation";
    let removed = note("removed-message-123", old);
    let late = note("offline-message-123", old);
    dispatch(json!({"op":"add","root":root,"item":removed})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":removed["id"]})).unwrap();
    dispatch(json!({"op":"delete_conversation","root":root,"conversationId":old})).unwrap();
    dispatch(json!({"op":"conversation","root":root,"id":new,"name":"Work"})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":item_event(&removed)})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":item_event(&late)})).unwrap();
    let before = initialize(&root).unwrap();
    assert_eq!(before["recoveryCount"], 1);
    assert!(
        dispatch(json!({"op":"recover_message","root":root,"id":late["id"],"conversationId":old}))
            .is_err()
    );
    assert_eq!(initialize(&root).unwrap(), before);
    let after =
        dispatch(json!({"op":"recover_message","root":root,"id":late["id"],"conversationId":new}))
            .unwrap();
    assert_eq!(after["recoveryCount"], 0);
    assert_eq!(after["entries"][0]["item"]["conversationId"], new);
    assert_ne!(after["entries"][0]["item"]["id"], late["id"]);
    assert_eq!(after["conversations"][old]["deleted"], true);
    dispatch(json!({"op":"apply","root":root,"event":item_event(&late)})).unwrap();
    assert_eq!(initialize(&root).unwrap()["recoveryCount"], 0);
    cleanup(&root);
}

#[test]
fn recovery_preserves_conflicting_offline_edits_and_groups_explicit_restores() {
    let root = root();
    let owner = "closed-work-conversation";
    let first = note("offline-message-123", owner);
    dispatch(json!({"op":"apply","root":root,"event":close_event(owner)})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":item_event(&first)})).unwrap();
    for (id, text) in [
        ("offline-edit-version-a", "Version A"),
        ("offline-edit-version-b", "Version B"),
    ] {
        dispatch(json!({"op":"apply","root":root,"event":{"id":id,"type":"edit","target":first["id"],"revision":1,"parents":[],"text":text,"name":""}})).unwrap();
    }
    assert_eq!(
        dispatch(json!({"op":"recovery_page","root":root})).unwrap()["items"][0]["versions"],
        2
    );
    let recovered = dispatch(json!({"op":"recover_message","root":root,"id":first["id"]})).unwrap();
    let destination = recovered["restoredConversationId"].clone();
    assert_ne!(destination, owner);
    assert_eq!(recovered["entries"].as_array().unwrap().len(), 2);
    for entry in recovered["entries"].as_array().unwrap() {
        assert_eq!(entry["item"]["conversationId"], destination);
    }
    let second = note("offline-message-456", owner);
    dispatch(json!({"op":"apply","root":root,"event":item_event(&second)})).unwrap();
    let again = dispatch(json!({"op":"recover_message","root":root,"id":second["id"]})).unwrap();
    assert_eq!(again["restoredConversationId"], destination);
    assert_eq!(again["entries"].as_array().unwrap().len(), 3);
    cleanup(&root);
}

#[test]
fn deleted_payloads_compact_without_losing_recovery_or_accepting_stale_collisions() {
    let root = root();
    let mut item = note("historical-message-123", "lanflow-self-chat");
    item["text"] = json!("Old payload ".repeat(1000));
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    let shared = database(&root).unwrap();
    {
        let db = shared.lock().unwrap();
        let bytes: i64 = db
            .query_row(
                "SELECT COALESCE(SUM(length(body)),0) FROM events",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(bytes < 500);
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM compacted_events", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    drop(shared);
    assert_eq!(
        dispatch(json!({"op":"trash","root":root})).unwrap()[0]["item"]["text"],
        item["text"]
    );
    dispatch(json!({"op":"close","root":root})).unwrap();
    dispatch(json!({"op":"maintenance_cleanup","root":root,"clearTrash":true})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":item_event(&item)})).unwrap();
    let state = initialize(&root).unwrap();
    assert!(state["entries"].as_array().unwrap().is_empty());
    assert!(
        dispatch(json!({"op":"trash","root":root}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    let mut collision = item_event(&item);
    collision["item"]["text"] = json!("different payload with the same event ID");
    assert!(dispatch(json!({"op":"apply","root":root,"event":collision})).is_err());
    assert_eq!(
        dispatch(json!({"op":"page","root":root,"after":0})).unwrap()["items"][0]["event"]["type"],
        "delete"
    );
    cleanup(&root);
}

#[test]
fn recovery_attachments_survive_cleanup_and_closed_trash_restores_into_new_identity() {
    let root = root();
    let owner = "closed-file-conversation";
    initialize(&root).unwrap();
    let source = root.join("fixture.bin");
    fs::write(&source, b"offline attachment").unwrap();
    let blob = dispatch(
        json!({"op":"import_file","root":root,"path":source,"name":"offline.bin","kind":"file"}),
    )
    .unwrap();
    let mut item = note("offline-file-message", owner);
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("offline.bin");
    item["sha256"] = blob["sha256"].clone();
    item["size"] = blob["size"].clone();
    dispatch(json!({"op":"apply","root":root,"event":close_event(owner)})).unwrap();
    dispatch(json!({"op":"apply","root":root,"event":item_event(&item)})).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    dispatch(json!({"op":"maintenance_cleanup","root":root,"clearTrash":true})).unwrap();
    assert_eq!(
        dispatch(json!({"op":"recovery_page","root":root})).unwrap()["items"][0]["available"],
        true
    );
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    let state = dispatch(json!({"op":"restore","root":root,"id":item["id"]})).unwrap();
    assert_eq!(state["recoveryCount"], 0);
    assert_ne!(state["entries"][0]["item"]["conversationId"], owner);
    assert_eq!(state["conversations"][owner]["deleted"], true);
    cleanup(&root);
}
