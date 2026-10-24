use super::*;

pub(super) fn system(root: &Path) -> PathBuf {
    root.join("system")
}
pub(super) fn incoming(root: &Path) -> PathBuf {
    system(root).join("cache/incoming")
}
pub(super) fn previews(root: &Path) -> PathBuf {
    system(root).join("cache/previews")
}
pub(super) fn pending(root: &Path) -> PathBuf {
    system(root).join("pending")
}
pub(super) fn database(root: &Path) -> PathBuf {
    system(root).join("messages.sqlite3")
}

fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // Junctions are reparse points too, but are not always reported as symlinks.
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn check_tree(path: &Path, recursive: bool) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if linked(&metadata) {
        return Err("数据目录包含链接，原文件已保留".into());
    }
    if recursive && metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            check_tree(&entry?.path(), true)?;
        }
    }
    Ok(())
}

fn check_merge(source: &Path, target: &Path) -> Result<()> {
    if !source.exists() || !target.exists() {
        return Ok(());
    }
    if source.is_dir() && target.is_dir() {
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            check_merge(&entry.path(), &target.join(entry.file_name()))?;
        }
    } else if !source.is_file() || !target.is_file() || hash_file(source)? != hash_file(target)? {
        return Err(format!("存储目录有同名的不同数据，已保留两份：{}", source.display()).into());
    }
    Ok(())
}

fn migrate_database(root: &Path, source: &Path) -> Result<()> {
    if !source.is_file() {
        return Ok(());
    }
    let target = database(root);
    let source_id = source.canonicalize()?.to_string_lossy().to_string();
    if target.exists() {
        let db = Connection::open(&target)?;
        let origin: Option<String> = db
            .query_row("SELECT body FROM meta WHERE key='layout_source'", [], |r| {
                r.get(0)
            })
            .optional()
            .unwrap_or(None);
        if origin.as_deref() != Some(source_id.as_str()) {
            return Err("检测到两份不同的消息数据库，原文件已保留".into());
        }
    } else {
        let pending = system(root).join(format!("{}.database.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<()> {
            let original = Connection::open(source)?;
            let mut copy = Connection::open(&pending)?;
            rusqlite::backup::Backup::new(&original, &mut copy)?.run_to_completion(
                128,
                Duration::from_millis(5),
                None,
            )?;
            copy.execute_batch(
                "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,body TEXT NOT NULL);",
            )?;
            copy.execute("INSERT INTO meta VALUES('layout_source',?) ON CONFLICT(key) DO UPDATE SET body=excluded.body", [&source_id])?;
            let integrity: String = copy.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
            if integrity != "ok" {
                return Err("旧数据库迁移校验失败，原数据库已保留".into());
            }
            drop(copy);
            drop(original);
            fs::OpenOptions::new()
                .write(true)
                .open(&pending)?
                .sync_all()?;
            fs::rename(&pending, &target)?;
            blobs::sync_directory(&system(root))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&pending);
        }
        result?;
    }
    // An old reader can keep the original database locked on Windows. The
    // verified SQLite backup is complete, including committed WAL frames.
    // Leave that old copy in place until its handle closes; never replay it.
    let archive = system(root).join("legacy");
    fs::create_dir_all(&archive)?;
    for suffix in ["", "-wal", "-shm"] {
        let old = PathBuf::from(format!("{}{suffix}", source.display()));
        if old.exists() {
            let destination = archive.join(old.file_name().ok_or("Invalid legacy path")?);
            if !destination.exists() {
                let _ = fs::rename(old, destination);
            }
        }
    }
    Ok(())
}

// Every step is repeatable after interruption. Never replace different content.
pub(super) fn relocate(source: &Path, target: &Path) -> Result<()> {
    check_tree(source, false)?;
    if !source.exists() {
        return Ok(());
    }
    // Check the whole move before mutating it: an identical parent database
    // must not be removed before a conflicting WAL or sibling is discovered.
    check_tree(source, true)?;
    check_tree(target, true)?;
    check_merge(source, target)?;
    relocate_checked(source, target)
}

fn relocate_checked(source: &Path, target: &Path) -> Result<()> {
    if !source.exists() {
        return Ok(());
    }
    if linked(&fs::symlink_metadata(source)?) {
        return Err("数据目录包含链接，原文件已保留".into());
    }
    if !target.exists() {
        fs::create_dir_all(target.parent().ok_or("Invalid storage path")?)?;
        fs::rename(source, target)?;
        return Ok(());
    }
    if linked(&fs::symlink_metadata(target)?) {
        return Err("数据目录包含链接，原文件已保留".into());
    }
    if source.is_dir() && target.is_dir() {
        let mut entries = fs::read_dir(source)?.collect::<std::io::Result<Vec<_>>>()?;
        // Complete the entire directory migration before opening SQLite.
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            relocate_checked(&entry.path(), &target.join(entry.file_name()))?;
        }
        fs::remove_dir(source)?;
    } else if source.is_file() && target.is_file() && hash_file(source)? == hash_file(target)? {
        fs::remove_file(source)?;
    } else {
        return Err(format!("存储目录有同名的不同数据，已保留两份：{}", source.display()).into());
    }
    Ok(())
}

pub(super) fn prepare(root: &Path) -> Result<()> {
    prepare_inner(root, false)
}

pub(super) fn prepare_device(root: &Path) -> Result<()> {
    prepare_inner(root, true)
}

fn prepare_inner(root: &Path, device_data: bool) -> Result<()> {
    static PREPARING: Mutex<()> = Mutex::new(());
    let _preparing = PREPARING
        .lock()
        .map_err(|_| "Storage migration unavailable")?;
    check_tree(root, false)?;
    fs::create_dir_all(root)?;
    let sys = system(root);
    let legacy = [
        "系统",
        "inbox",
        "媒体",
        "文件",
        "blobs",
        "incoming",
        "open",
        "messages.sqlite3",
        "inbox.sqlite3",
        "received",
        "downloads",
    ];
    let device_names = [
        "identity.json",
        "state.json",
        "state.backup.json",
        "state.pending.json",
    ];
    let migrating = legacy.iter().any(|name| root.join(name).exists())
        || (device_data && device_names.iter().any(|name| root.join(name).exists()))
        || [
            "设备",
            "缓存",
            "待整理",
            "旧版",
            "恢复的文件",
            "blobs",
            "incoming",
            "open",
        ]
        .iter()
        .any(|name| sys.join(name).exists())
        || ["接收", "打开", "旧版接收"]
            .iter()
            .any(|name| sys.join("cache").join(name).exists());
    // Validate ancestors before creating a lock, cache, or database. Inspect
    // whole trees only during upgrades so ordinary starts stay independent of
    // attachment count.
    for name in legacy
        .into_iter()
        .chain(["system", "media", "files"])
        .chain(device_names.into_iter().filter(|_| device_data))
    {
        check_tree(&root.join(name), migrating)?;
    }
    for name in [
        "device",
        "cache",
        "cache/incoming",
        "cache/previews",
        "cache/legacy_received",
        "pending",
        "legacy",
        "recovered",
        "messages.sqlite3",
        ".layout.lock",
    ] {
        check_tree(&sys.join(name), false)?;
    }
    fs::create_dir_all(&sys)?;
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(sys.join(".layout.lock"))?;
    lock.lock()?;
    // A copied/moved modern layout can contain its old empty coordination
    // file. Do not hash the live Windows lock when merging those directories.
    for old in [root.join("系统"), root.join("inbox")] {
        let stale_lock = old.join(".layout.lock");
        if fs::metadata(&stale_lock).is_ok_and(|metadata| metadata.is_file() && metadata.len() == 0)
        {
            fs::remove_file(stale_lock)?;
        }
    }
    relocate(&root.join("系统"), &sys)?;
    relocate(&root.join("inbox"), &sys)?;
    fs::create_dir_all(&sys)?;
    for (from, to) in [("媒体", "media"), ("文件", "files")] {
        relocate(&root.join(from), &root.join(to))?;
    }
    for (from, to) in [
        ("设备", "device"),
        ("缓存", "cache"),
        ("待整理", "pending"),
        ("旧版", "legacy"),
        ("恢复的文件", "recovered"),
    ] {
        relocate(&sys.join(from), &sys.join(to))?;
    }
    for (from, to) in [
        ("接收", "incoming"),
        ("打开", "previews"),
        ("旧版接收", "legacy_received"),
    ] {
        relocate(&sys.join("cache").join(from), &sys.join("cache").join(to))?;
    }
    if device_data {
        for name in [
            "identity.json",
            "state.json",
            "state.backup.json",
            "state.pending.json",
        ] {
            relocate(&root.join(name), &sys.join("device").join(name))?;
        }
    }
    for old in [root.to_path_buf(), sys.clone()] {
        for (from, to) in [
            ("blobs", pending(root)),
            ("incoming", incoming(root)),
            ("open", previews(root)),
        ] {
            relocate(&old.join(from), &to)?;
        }
    }
    migrate_database(root, &root.join("messages.sqlite3"))?;
    migrate_database(root, &root.join("inbox.sqlite3"))?;
    relocate(
        &root.join("inbox.pre-rust.sqlite3"),
        &sys.join("inbox.pre-rust.sqlite3"),
    )?;
    for name in ["received", "downloads"] {
        relocate(&root.join(name), &sys.join("legacy").join(name))?;
    }
    for directory in [
        incoming(root),
        previews(root),
        sys.join("device"),
        pending(root),
        root.join("media"),
        root.join("files"),
    ] {
        fs::create_dir_all(&directory)?;
        if linked(&fs::symlink_metadata(&directory)?)
            || !directory.canonicalize()?.starts_with(root.canonicalize()?)
        {
            return Err("数据目录包含外部链接，原文件已保留".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary() -> PathBuf {
        let root = std::env::temp_dir().join(format!("lanflow-english-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn cleanup(root: &Path) {
        dispatch(json!({"op":"close", "root":root})).unwrap();
        assert!(root.starts_with(std::env::temp_dir()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn chinese_layout_migrates_original_names_drafts_trash_and_device_files() {
        let root = temporary();
        initialize(&root).unwrap();
        let source = root.join("source.tmp");
        fs::write(&source, b"original bytes").unwrap();
        let stored = dispatch(json!({"op":"import_file", "root":root, "path":source, "name":"设备.png", "kind":"image"})).unwrap();
        fs::remove_file(source).unwrap();
        let item = json!({"id":"a".repeat(32),"originId":"b".repeat(32),"originName":"旧设备",
            "createdAt":now(),"kind":"image","name":"设备.png","size":14,
            "sha256":stored["sha256"],"text":"","conversationId":"lanflow-self-chat"});
        dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        dispatch(json!({"op":"save_meta","root":root,"value":{"drafts":{"self":"未发送"},"imageDrafts":{"self":[item.clone()]}}})).unwrap();
        dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
        {
            let shared = super::super::database(&root).unwrap();
            let db = shared.lock().unwrap();
            db.execute(
                "UPDATE attachment_files SET category='媒体',path='媒体/' || substr(path,7)",
                [],
            )
            .unwrap();
        }
        dispatch(json!({"op":"close","root":root})).unwrap();
        fs::write(
            system(&root).join("device/identity.json"),
            b"original identity",
        )
        .unwrap();
        fs::write(
            system(&root).join("device/state.json"),
            b"bindings and device state",
        )
        .unwrap();
        fs::write(incoming(&root).join("resume.part"), b"resumable prefix").unwrap();
        fs::rename(system(&root).join("device"), system(&root).join("设备")).unwrap();
        fs::rename(incoming(&root), system(&root).join("cache/接收")).unwrap();
        fs::rename(previews(&root), system(&root).join("cache/打开")).unwrap();
        fs::rename(system(&root).join("cache"), system(&root).join("缓存")).unwrap();
        fs::rename(pending(&root), system(&root).join("待整理")).unwrap();
        fs::rename(system(&root), root.join("系统")).unwrap();
        fs::rename(root.join("media"), root.join("媒体")).unwrap();
        fs::rename(root.join("files"), root.join("文件")).unwrap();
        for _ in 0..2 {
            let state = initialize(&root).unwrap();
            assert_eq!(state["drafts"]["self"], "未发送");
            assert_eq!(state["imageDrafts"]["self"][0]["name"], "设备.png");
            assert_eq!(
                fs::read(root.join("media/设备.png")).unwrap(),
                b"original bytes"
            );
            assert_eq!(
                fs::read(system(&root).join("device/identity.json")).unwrap(),
                b"original identity"
            );
            assert_eq!(
                fs::read(system(&root).join("device/state.json")).unwrap(),
                b"bindings and device state"
            );
            assert_eq!(
                fs::read(incoming(&root).join("resume.part")).unwrap(),
                b"resumable prefix"
            );
            let trash = dispatch(json!({"op":"trash","root":root})).unwrap();
            assert_eq!(trash[0]["available"], true);
            assert_eq!(fs::read_dir(&root).unwrap().count(), 3);
            dispatch(json!({"op":"close","root":root})).unwrap();
        }
        cleanup(&root);
    }

    #[test]
    fn conflicting_merge_preserves_every_source_before_moving_any_sibling() {
        let root = temporary();
        fs::create_dir_all(root.join("系统/设备")).unwrap();
        fs::create_dir_all(root.join("system/设备")).unwrap();
        fs::write(root.join("系统/a.txt"), b"still in original directory").unwrap();
        fs::write(root.join("系统/设备/identity.json"), b"old identity").unwrap();
        fs::write(
            root.join("system/设备/identity.json"),
            b"different identity",
        )
        .unwrap();
        assert!(prepare(&root).is_err());
        assert_eq!(
            fs::read(root.join("系统/a.txt")).unwrap(),
            b"still in original directory"
        );
        assert_eq!(
            fs::read(root.join("系统/设备/identity.json")).unwrap(),
            b"old identity"
        );
        assert_eq!(
            fs::read(root.join("system/设备/identity.json")).unwrap(),
            b"different identity"
        );
        cleanup(&root);
    }

    #[test]
    fn concurrent_preparation_migrates_device_identity_only_once() {
        let root = temporary();
        fs::write(root.join("identity.json"), b"one device identity").unwrap();
        fs::write(root.join("state.json"), b"one binding history").unwrap();
        let threads = (0..8)
            .map(|_| {
                let root = root.clone();
                std::thread::spawn(move || prepare_device(&root).unwrap())
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(
            fs::read(system(&root).join("device/identity.json")).unwrap(),
            b"one device identity"
        );
        assert_eq!(
            fs::read(system(&root).join("device/state.json")).unwrap(),
            b"one binding history"
        );
        assert!(!root.join("identity.json").exists());
        cleanup(&root);
    }

    #[test]
    fn generic_nas_layout_preserves_root_identity_owned_by_external_tls_setup() {
        let root = temporary();
        fs::write(root.join("identity.json"), b"external TLS identity").unwrap();
        prepare(&root).unwrap();
        prepare(&root).unwrap();
        assert_eq!(
            fs::read(root.join("identity.json")).unwrap(),
            b"external TLS identity"
        );
        assert!(!system(&root).join("device/identity.json").exists());
        cleanup(&root);
    }

    #[test]
    fn external_system_link_is_rejected_before_writing_or_moving_user_data() {
        let root = temporary();
        let outside = temporary();
        fs::write(outside.join("untouched.txt"), b"outside data").unwrap();
        let link = root.join("system");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        #[cfg(windows)]
        {
            let output = std::process::Command::new("cmd")
                .args(["/c", "mklink", "/J"])
                .arg(&link)
                .arg(&outside)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        fs::write(root.join("identity.json"), b"stay local").unwrap();
        assert!(prepare(&root).is_err());
        assert_eq!(fs::read(root.join("identity.json")).unwrap(), b"stay local");
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 1);
        #[cfg(unix)]
        fs::remove_file(link).unwrap();
        #[cfg(windows)]
        fs::remove_dir(link).unwrap();
        cleanup(&root);
        cleanup(&outside);
    }
}
