use super::*;

fn temporary() -> PathBuf {
    let root = std::env::temp_dir().join(format!("lanflow-layout-{}", uuid::Uuid::new_v4()));
    initialize(&root).unwrap();
    root
}

fn cleanup(root: &Path) {
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert!(root.starts_with(std::env::temp_dir()));
    fs::remove_dir_all(root).unwrap();
}

fn attachment(root: &Path, name: &str, kind: &str, bytes: &[u8]) -> Value {
    let source = root.join("source.tmp");
    fs::write(&source, bytes).unwrap();
    let stored =
        dispatch(json!({"op":"import_file","root":root,"path":source,"name":name,"kind":kind}))
            .unwrap();
    fs::remove_file(source).unwrap();
    json!({"id":uuid::Uuid::new_v4().simple().to_string(),"originId":"a".repeat(32),
        "originName":"本机","createdAt":now(),"kind":kind,"name":name,"size":bytes.len(),
        "sha256":stored["sha256"],"text":"","conversationId":"lanflow-self-chat"})
}

#[test]
fn readable_names_keep_exact_bytes_and_never_overwrite_collisions() {
    let root = temporary();
    fs::write(root.join("files/报告.zip"), b"user-owned").unwrap();
    let a = attachment(&root, "照片.png", "image", b"original png bytes");
    let b = attachment(&root, "照片.png", "image", b"different png bytes");
    let video = attachment(&root, "旅行.mp4", "video", b"original video bytes");
    let file = attachment(&root, "报告.zip", "file", b"archive bytes");
    let alias = attachment(&root, "照片副本.png", "image", b"original png bytes");
    for item in [&a, &b, &video, &file, &alias] {
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    }
    assert_eq!(
        fs::read(root.join("media/照片.png")).unwrap(),
        b"original png bytes"
    );
    assert_eq!(
        fs::read(root.join("media/照片 (2).png")).unwrap(),
        b"different png bytes"
    );
    assert_eq!(
        fs::read(root.join("media/照片副本.png")).unwrap(),
        b"original png bytes"
    );
    assert_eq!(
        fs::read(root.join("media/旅行.mp4")).unwrap(),
        b"original video bytes"
    );
    assert_eq!(
        fs::read(root.join("files/报告.zip")).unwrap(),
        b"user-owned"
    );
    assert_eq!(
        fs::read(root.join("files/报告 (2).zip")).unwrap(),
        b"archive bytes"
    );
    assert_eq!(fs::read_dir(layout::pending(&root)).unwrap().count(), 0);
    dispatch(json!({"op":"close","root":root})).unwrap();
    let reopened = initialize(&root).unwrap();
    assert_eq!(reopened["entries"].as_array().unwrap().len(), 5);
    assert_eq!(fs::read_dir(&root).unwrap().count(), 3);
    assert_eq!(
        fs::read(attachments::path(&root, a["sha256"].as_str().unwrap())).unwrap(),
        b"original png bytes"
    );
    fs::write(root.join("media/照片副本.png"), b"edited alias").unwrap();
    assert_eq!(
        fs::read(root.join("media/照片.png")).unwrap(),
        b"original png bytes"
    );
    cleanup(&root);
}

#[test]
fn old_hashed_layout_migrates_messages_drafts_trash_and_partial_transfers() {
    let root = temporary();
    let item = attachment(&root, "旧照片.png", "image", b"legacy original");
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    dispatch(json!({"op":"save_meta","root":root,"value":{"drafts":{"self":"未发送"},"imageDrafts":{"self":[item.clone()]}}})).unwrap();
    dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
    {
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute("DELETE FROM attachment_files", []).unwrap();
    }
    dispatch(json!({"op":"close","root":root})).unwrap();
    let old = root.join("inbox");
    fs::rename(layout::system(&root), &old).unwrap();
    fs::create_dir_all(old.join("blobs")).unwrap();
    fs::create_dir_all(old.join("incoming")).unwrap();
    fs::rename(
        root.join("media/旧照片.png"),
        old.join("blobs").join(item["sha256"].as_str().unwrap()),
    )
    .unwrap();
    fs::write(old.join("incoming/resume.part"), b"download prefix").unwrap();
    let state = initialize(&root).unwrap();
    assert_eq!(state["drafts"]["self"], "未发送");
    assert_eq!(state["imageDrafts"]["self"][0], item);
    assert_eq!(
        fs::read(root.join("media/旧照片.png")).unwrap(),
        b"legacy original"
    );
    assert_eq!(
        fs::read(layout::incoming(&root).join("resume.part")).unwrap(),
        b"download prefix"
    );
    assert!(!old.exists());
    let trash = dispatch(json!({"op":"trash","root":root})).unwrap();
    assert_eq!(trash[0]["available"], true);
    let shared = database(&root).unwrap();
    assert_eq!(
        shared
            .lock()
            .unwrap()
            .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    drop(shared);
    cleanup(&root);
}

#[test]
fn reserved_path_recovers_an_interrupted_copy_without_losing_original_bytes() {
    let root = temporary();
    let item = attachment(&root, "中断.png", "image", b"complete original");
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    fs::rename(
        root.join("media/中断.png"),
        layout::pending(&root).join(item["sha256"].as_str().unwrap()),
    )
    .unwrap();
    fs::write(root.join("media/中断.png"), b"partial").unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    assert_eq!(
        fs::read(root.join("media/中断.png")).unwrap(),
        b"complete original"
    );
    let recovered = fs::read_dir(layout::system(&root).join("recovered"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(fs::read(recovered).unwrap(), b"partial");
    initialize(&root).unwrap();
    assert_eq!(fs::read_dir(root.join("media")).unwrap().count(), 1);
    cleanup(&root);
}

#[test]
fn attachment_names_cannot_escape_the_two_public_folders() {
    let root = temporary();
    attachment(&root, "../outside.txt", "file", b"safe original");
    attachment(&root, "CON.txt", "file", b"reserved original");
    assert_eq!(
        fs::read(root.join("files/outside.txt")).unwrap(),
        b"safe original"
    );
    assert_eq!(
        fs::read(root.join("files/_CON.txt")).unwrap(),
        b"reserved original"
    );
    assert!(!root.join("outside.txt").exists());
    cleanup(&root);
}

#[test]
fn reimport_repairs_changed_bytes_and_preserves_the_external_edit() {
    let root = temporary();
    let item = attachment(&root, "repair.bin", "file", b"ABCD");
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let target = root.join("files/repair.bin");
    for altered in [b"WXYZ".as_slice(), b"different length".as_slice()] {
        fs::write(&target, altered).unwrap();
        let imported = attachment(&root, "repair.bin", "file", b"ABCD");
        assert_eq!(imported["sha256"], item["sha256"]);
        assert_eq!(fs::read(&target).unwrap(), b"ABCD");
        let recovered = fs::read_dir(layout::system(&root).join("recovered"))
            .unwrap()
            .map(|entry| fs::read(entry.unwrap().path()).unwrap())
            .collect::<Vec<_>>();
        assert!(recovered.iter().any(|bytes| bytes == altered));
    }
    cleanup(&root);
}

#[test]
fn incoming_verified_copy_repairs_a_modified_local_attachment() {
    let root = temporary();
    let item = attachment(&root, "incoming.bin", "file", b"ABCD");
    let target = root.join("files/incoming.bin");
    fs::write(&target, b"WXYZ").unwrap();
    let upload =
        dispatch(json!({"op":"blob_begin","root":root,"digest":item["sha256"],"length":4}))
            .unwrap();
    fs::write(upload["path"].as_str().unwrap(), b"ABCD").unwrap();
    dispatch(json!({"op":"blob_finish","id":upload["id"]})).unwrap();
    assert_eq!(fs::read(&target).unwrap(), b"ABCD");
    assert_eq!(
        fs::read_dir(layout::system(&root).join("recovered"))
            .unwrap()
            .count(),
        1
    );
    cleanup(&root);
}

#[test]
fn repairing_a_maximum_length_filename_keeps_the_modified_copy() {
    let root = temporary();
    let name = format!("{}.bin", "a".repeat(236));
    let item = attachment(&root, &name, "file", b"ABCD");
    let target = root.join("files").join(&name);
    fs::write(&target, b"WXYZ").unwrap();
    let restored = attachment(&root, &name, "file", b"ABCD");
    assert_eq!(restored["sha256"], item["sha256"]);
    assert_eq!(fs::read(target).unwrap(), b"ABCD");
    let recovered = fs::read_dir(layout::system(&root).join("recovered"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap();
    assert!(recovered.file_name().to_string_lossy().len() <= 255);
    assert_eq!(fs::read(recovered.path()).unwrap(), b"WXYZ");
    cleanup(&root);
}

#[test]
fn upgrading_edited_aliases_opens_successfully_and_a_pending_original_repairs_every_alias() {
    let root = temporary();
    let first = attachment(&root, "first.bin", "file", b"ABCD");
    let second = attachment(&root, "second.bin", "file", b"ABCD");
    for item in [&first, &second] {
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    }
    fs::write(root.join("files/first.bin"), b"WXYZ").unwrap();
    fs::write(root.join("files/second.bin"), b"1234").unwrap();
    let shared = database(&root).unwrap();
    shared
        .lock()
        .unwrap()
        .execute("DELETE FROM meta WHERE key='attachments_organized'", [])
        .unwrap();
    drop(shared);
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    assert_eq!(fs::read(root.join("files/first.bin")).unwrap(), b"WXYZ");
    assert_eq!(fs::read(root.join("files/second.bin")).unwrap(), b"1234");
    fs::write(
        layout::pending(&root).join(first["sha256"].as_str().unwrap()),
        b"ABCD",
    )
    .unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    initialize(&root).unwrap();
    for name in ["first.bin", "second.bin"] {
        assert_eq!(fs::read(root.join("files").join(name)).unwrap(), b"ABCD");
    }
    assert_eq!(
        fs::read_dir(layout::system(&root).join("recovered"))
            .unwrap()
            .count(),
        2
    );
    cleanup(&root);
}

#[test]
fn recovery_never_moves_modified_bytes_into_an_external_directory_link() {
    let root = temporary();
    let outside = temporary();
    attachment(&root, "edited.bin", "file", b"ABCD");
    let original = root.join("files/edited.bin");
    fs::write(&original, b"WXYZ").unwrap();
    let link = layout::system(&root).join("recovered");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    #[cfg(windows)]
    {
        let result = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(&link)
            .arg(&outside)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    let source = root.join("source.bin");
    fs::write(&source, b"ABCD").unwrap();
    let before = fs::read_dir(&outside).unwrap().count();
    assert!(
        dispatch(
            json!({"op":"import_file","root":root,"path":source,"name":"edited.bin","kind":"file"})
        )
        .is_err()
    );
    assert_eq!(fs::read(&original).unwrap(), b"WXYZ");
    assert_eq!(fs::read_dir(&outside).unwrap().count(), before);
    #[cfg(unix)]
    fs::remove_file(link).unwrap();
    #[cfg(windows)]
    fs::remove_dir(link).unwrap();
    cleanup(&root);
    cleanup(&outside);
}
