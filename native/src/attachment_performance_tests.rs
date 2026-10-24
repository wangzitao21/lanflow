use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn watch_copy(root: &Path, observed: &Arc<AtomicUsize>) {
    let shared = database(root).unwrap();
    let observed = observed.clone();
    COPY_OBSERVERS.get_or_init(Default::default).lock().unwrap().insert(root.to_owned(), Box::new(move || {
        let db = shared.try_lock().expect("attachment byte IO must not hold the database lock");
        db.execute("INSERT INTO meta VALUES('concurrent-draft','ready') ON CONFLICT(key) DO UPDATE SET body='ready'", []).unwrap();
        observed.fetch_add(1, Ordering::SeqCst);
    }));
}

#[test]
fn import_add_drafts_and_startup_release_database_during_byte_io() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let source = root.join("source.tmp");
    fs::write(&source, b"original attachment bytes").unwrap();
    let observed = Arc::new(AtomicUsize::new(0));
    watch_copy(&root, &observed);
    let imported = dispatch(
        json!({"op":"import_file","root":root,"path":source,"name":"import.bin","kind":"file"}),
    )
    .unwrap();
    let item = json!({"id":"attachment-item-1234","originId":"device-origin-1234","originName":"Desktop","createdAt":now(),"kind":"file","text":"","name":"added.bin","size":imported["size"],"sha256":imported["sha256"]});
    watch_copy(&root, &observed);
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let mut draft = item.clone();
    draft["name"] = json!("draft.bin");
    watch_copy(&root, &observed);
    dispatch(json!({"op":"save_meta","root":root,"value":{"imageDrafts":{"self":[draft]}}}))
        .unwrap();
    fs::copy(
        &source,
        layout::pending(&root).join(imported["sha256"].as_str().unwrap()),
    )
    .unwrap();
    watch_copy(&root, &observed);
    initialize(&root).unwrap();
    assert_eq!(observed.load(Ordering::SeqCst), 4);
    for name in ["import.bin", "added.bin", "draft.bin"] {
        assert_eq!(
            fs::read(root.join("files").join(name)).unwrap(),
            b"original attachment bytes"
        );
    }
    crate::tests::cleanup(&root);
}

#[test]
fn concurrent_registration_of_identical_staged_bytes_preserves_each_alias() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let bytes = vec![42_u8; 512 * 1024];
    let sha = digest(&bytes);
    fs::write(layout::pending(&root).join(&sha), &bytes).unwrap();
    let shared = database(&root).unwrap();
    let mut workers = Vec::new();
    for index in 0..8 {
        let root = root.clone();
        let shared = shared.clone();
        let sha = sha.clone();
        workers.push(std::thread::spawn(move || register(&root, &shared, &json!({"kind":"file","name":format!("alias-{index}.bin"),"sha256":sha,"size":512*1024})).unwrap()));
    }
    for worker in workers {
        let path = worker.join().unwrap().unwrap();
        assert_eq!(hash_file(&root.join(path)).unwrap(), sha);
    }
    assert_eq!(fs::read_dir(root.join("files")).unwrap().count(), 8);
    assert_eq!(fs::read_dir(layout::pending(&root)).unwrap().count(), 0);
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn routine_startup_skips_organized_history_and_recovers_unfinished_aliases() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let source = root.join("source.bin");
    fs::write(&source, b"complete bytes").unwrap();
    let imported = dispatch(
        json!({"op":"import_file","root":root,"path":source,"name":"original.bin","kind":"file"}),
    )
    .unwrap();
    let shared = database(&root).unwrap();
    let db = shared.lock().unwrap();
    assert!(startup_items(&root, &db).unwrap().is_empty());
    db.execute("INSERT INTO attachment_files(digest,name,category,path,ready) VALUES(?,'alias.bin','files','files/alias.bin',0)", [imported["sha256"].as_str().unwrap()]).unwrap();
    assert_eq!(startup_items(&root, &db).unwrap().len(), 1);
    drop(db);
    drop(shared);
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    assert_eq!(
        fs::read(root.join("files/alias.bin")).unwrap(),
        b"complete bytes"
    );
    let shared = database(&root).unwrap();
    assert!(
        startup_items(&root, &shared.lock().unwrap())
            .unwrap()
            .is_empty()
    );
    drop(shared);
    crate::tests::cleanup(&root);
}
