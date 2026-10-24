use super::*;

#[test]
fn bounded_history_bootstrap_survives_deletion_and_same_sequence_rows() {
    let root = std::env::temp_dir().join(format!("lanflow-bootstrap-{}", uuid::Uuid::new_v4()));
    initialize(&root).unwrap();
    let shared = database(&root).unwrap();
    {
        let mut db = shared.lock().unwrap();
        let tx = db.transaction().unwrap();
        for index in 0..1005 {
            let id = format!("bootstrap-item-{index:08}");
            let item = json!({"id":id,"originId":"a".repeat(32),"originName":"Source","createdAt":now(),"kind":"text","text":format!("history {index}"),"name":"","size":0,"sha256":""});
            tx.execute(
                "INSERT INTO items(id,sequence,body) VALUES(?,?,?)",
                params![id, index / 2 + 1, item.to_string()],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO copies VALUES(?,?)",
                params![id, "device:bootstrap-target"],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    let meta = dispatch(json!({"op":"open_paged","root":root})).unwrap();
    assert_eq!(meta["entries"].as_array().unwrap().len(), 0);
    assert_eq!(meta["bootstrap"]["count"], 1005);
    let mut after = Value::Null;
    let mut ids = std::collections::HashSet::new();
    loop {
        let page = dispatch(json!({"op":"bootstrap_entries","root":root,"after":after,"upper":meta["bootstrap"]["upper"],"limit":1000})).unwrap();
        for record in page["entries"].as_array().unwrap() {
            assert!(ids.insert(record["item"]["id"].as_str().unwrap().to_owned()));
            assert_eq!(record["copies"][0], "device:bootstrap-target");
        }
        if page["more"] != true {
            break;
        }
        after = page["cursor"].clone();
        dispatch(json!({"op":"delete","root":root,"id":"bootstrap-item-00001004"})).unwrap();
    }
    assert_eq!(ids.len(), 1004);
    let delta =
        dispatch(json!({"op":"snapshot","root":root,"knownRevision":meta["revision"]})).unwrap();
    assert!(
        delta["removed"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == "bootstrap-item-00001004")
    );
    drop(shared);
    dispatch(json!({"op":"close","root":root})).unwrap();
    fs::remove_dir_all(root).unwrap();
}
