use super::*;
use crate::tests::{cleanup, root};

#[test]
fn deleting_an_empty_conversation_publishes_a_durable_delta() {
    let root = root();
    let owner = "empty-conversation-123";
    let before =
        dispatch(json!({"op":"conversation","root":root,"id":owner,"name":"空会话"})).unwrap();
    let after = dispatch(json!({"op":"delete_conversation","root":root,"conversationId":owner,"knownRevision":before["revision"]})).unwrap();
    assert_eq!(after["delta"], true);
    assert_eq!(after["through"], 0);
    assert_eq!(after["conversations"][owner]["deleted"], true);
    assert!(after["changeCursor"].as_i64() > before["changeCursor"].as_i64());
    // Inspect the actual event log, which is forwarded by both devices and hubs.
    let shared = database(&root).unwrap();
    let body: String = shared
        .lock()
        .unwrap()
        .query_row(
            "SELECT body FROM events ORDER BY sequence DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let event: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(event["type"], "conversation");
    assert_eq!(event["conversation"]["deleted"], true);
    drop(shared);
    dispatch(json!({"op":"close","root":root})).unwrap();
    let reopened = initialize(&root).unwrap();
    assert_eq!(reopened["conversations"][owner]["deleted"], true);
    cleanup(&root);
}

#[test]
fn conversation_deletion_converges_with_out_of_order_metadata_and_replay() {
    let owner = "empty-conversation-123";
    let changes = [
        json!({"id":"conversation-create-123","type":"conversation","conversation":{"id":owner,"name":"Original","revision":1}}),
        json!({"id":"conversation-delete-123","type":"conversation","conversation":{"id":owner,"name":"Original","revision":2,"deleted":true}}),
        // An offline rename can have a higher clock and no knowledge of deletion.
        json!({"id":"conversation-rename-123","type":"conversation","conversation":{"id":owner,"name":"Renamed","revision":3,"deleted":false,"avatar":"book"}}),
    ];
    for order in [
        [0, 1, 2],
        [2, 1, 0],
        [1, 0, 2],
        [1, 2, 0],
        [0, 2, 1],
        [2, 0, 1],
    ] {
        let root = root();
        for index in order.into_iter().chain(order) {
            dispatch(json!({"op":"apply","root":root,"event":changes[index]})).unwrap();
        }
        let state = initialize(&root).unwrap();
        assert_eq!(state["conversations"][owner]["deleted"], true);
        assert_eq!(state["conversations"][owner]["name"], "Renamed");
        assert_eq!(state["conversations"][owner]["avatar"], "book");
        cleanup(&root);
    }
}
