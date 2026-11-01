use super::*;

fn setup() -> (PathBuf, Value, Value) {
    let root = crate::tests::root();
    let item = json!({"id":"forward-original-message","originId":"forward-original-device","originName":"Desktop","createdAt":"2026-10-29T00:00:00Z","kind":"text","text":"Original","name":"","size":0,"sha256":""});
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    dispatch(json!({"op":"conversation","root":root,"id":"forward-target-conversation","name":"Target"})).unwrap();
    let request = json!({"op":"forward_message","root":root,"id":item["id"],"conversationId":"forward-target-conversation","originId":"forward-original-device","originName":"Desktop","cut":true});
    (root, item, request)
}

#[test]
fn cut_forward_is_atomic_even_if_source_deletion_fails() {
    let (root, item, request) = setup();
    let shared = database(&root).unwrap();
    shared.lock().unwrap().execute_batch("CREATE TRIGGER fail_cut BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;").unwrap();
    assert!(dispatch(request.clone()).is_err());
    let snapshot = dispatch(json!({"op":"snapshot","root":root})).unwrap();
    assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["entries"][0]["item"]["id"], item["id"]);
    shared.lock().unwrap().execute_batch("DROP TRIGGER fail_cut;").unwrap();
    let snapshot = dispatch(request).unwrap();
    assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["entries"][0]["item"]["conversationId"], "forward-target-conversation");
    assert_ne!(snapshot["entries"][0]["item"]["id"], item["id"]);
    assert_eq!(dispatch(json!({"op":"trash","root":root})).unwrap().as_array().unwrap().len(), 1);
    dispatch(json!({"op":"close","root":root})).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn copy_forward_uses_latest_edited_content_and_preserves_original() {
    let (root, item, mut request) = setup();
    dispatch(json!({"op":"edit_message","root":root,"id":item["id"],"text":"Latest edit"})).unwrap();
    request["cut"] = json!(false);
    let snapshot = dispatch(request).unwrap();
    let entries = snapshot["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    assert!(entries.iter().all(|entry| entry["item"]["text"] == "Latest edit"));
    dispatch(json!({"op":"close","root":root})).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalid_destination_or_missing_attachment_cannot_remove_original() {
    let (root, item, mut request) = setup();
    request["conversationId"] = json!("missing-conversation-000");
    assert!(dispatch(request.clone()).is_err());
    request["conversationId"] = json!("lanflow-self-chat");
    assert!(dispatch(request.clone()).is_err());
    let file = root.join("source.png");
    fs::write(&file, b"example image bytes").unwrap();
    let imported = dispatch(json!({"op":"import_file","root":root,"path":file,"name":"image.png","kind":"image"})).unwrap();
    let attachment = json!({"id":"forward-missing-image","originId":"forward-original-device","originName":"Desktop","createdAt":"2026-10-29T00:00:00Z","kind":"image","text":"Caption","name":"image.png","size":19,"sha256":imported["sha256"]});
    dispatch(json!({"op":"add","root":root,"item":attachment})).unwrap();
    let path = attachments::item_path(&database(&root).unwrap().lock().unwrap(), &attachment).unwrap().unwrap();
    fs::remove_file(root.join(path)).unwrap();
    request["id"] = attachment["id"].clone();
    request["conversationId"] = json!("forward-target-conversation");
    assert!(dispatch(request).is_err());
    let entries = dispatch(json!({"op":"history_records","root":root,"ids":[item["id"],attachment["id"]]})).unwrap();
    assert_eq!(entries.as_array().unwrap().len(), 2);
    dispatch(json!({"op":"close","root":root})).unwrap();
    fs::remove_dir_all(root).unwrap();
}
