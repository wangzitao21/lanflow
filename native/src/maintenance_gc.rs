use super::*;
use std::collections::HashSet;

fn add_digest(item: &Value, referenced: &mut HashSet<String>) {
    if let Some(digest) = item["sha256"].as_str().filter(|value| valid_digest(value)) {
        referenced.insert(digest.to_owned());
    }
}

fn references(db: &Connection) -> Result<HashSet<String>> {
    let mut referenced = HashSet::new();
    for table in ["items", "trash", "favorite_trash"] {
        let mut statement = db.prepare(&format!("SELECT body FROM {table}"))?;
        for body in statement.query_map([], |row| row.get::<_, String>(0))? {
            add_digest(&serde_json::from_str::<Value>(&body?)?, &mut referenced);
        }
    }
    let mut favorites = db.prepare("SELECT json_extract(body,'$.item') FROM favorites WHERE json_extract(body,'$.value')=1 AND json_type(body,'$.item')='object'")?;
    for body in favorites.query_map([], |row| row.get::<_, String>(0))? {
        add_digest(&serde_json::from_str::<Value>(&body?)?, &mut referenced);
    }
    let settings: Option<String> = db
        .query_row("SELECT body FROM meta WHERE key='settings'", [], |row| {
            row.get(0)
        })
        .optional()?;
    if let Some(settings) = settings {
        let settings: Value = serde_json::from_str(&settings)?;
        for list in settings["imageDrafts"]
            .as_object()
            .into_iter()
            .flat_map(|values| values.values())
        {
            for item in list.as_array().into_iter().flatten() {
                add_digest(item, &mut referenced);
            }
        }
        for item in settings["draftImages"].as_array().into_iter().flatten() {
            add_digest(item, &mut referenced);
        }
    }
    // Paused, retrying and cancelled jobs can still be resumed by the user.
    // Only completed history is no longer an active reference.
    let mut jobs = db.prepare("SELECT body FROM transfer_jobs WHERE state!='completed'")?;
    for body in jobs.query_map([], |row| row.get::<_, String>(0))? {
        let event: Value = serde_json::from_str(&body?)?;
        if let Some(item) = events::transfer_item(&event) {
            add_digest(item, &mut referenced);
        }
    }
    Ok(referenced)
}

fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn temporary_candidates(
    root: &Path,
    db: &Connection,
    referenced: &HashSet<String>,
) -> Result<Vec<PathBuf>> {
    let mut downloads = HashSet::new();
    let mut jobs =
        db.prepare("SELECT endpoint,body FROM transfer_jobs WHERE state!='completed'")?;
    for row in jobs.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (endpoint, body) = row?;
        let event: Value = serde_json::from_str(&body)?;
        if let Some(item) = events::transfer_item(&event) {
            downloads.insert(format!(
                "download-{}.part",
                digest(format!("{endpoint}:{}", string(item, "sha256")?).as_bytes())
            ));
        }
    }
    let mut candidates = Vec::new();
    for entry in fs::read_dir(layout::pending(root))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if valid_digest(&name)
            && !referenced.contains(&name)
            && fs::symlink_metadata(entry.path()).is_ok_and(|m| m.is_file() && !linked(&m))
            && hash_file(&entry.path()).is_ok_and(|actual| actual == name)
        {
            candidates.push(entry.path());
        }
    }
    for entry in fs::read_dir(layout::incoming(root))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let download = name
            .strip_prefix("download-")
            .and_then(|n| n.strip_suffix(".part"));
        let orphan_download = download.is_some_and(valid_digest) && !downloads.contains(&name);
        let staging = name
            .strip_suffix(".stage")
            .is_some_and(|n| uuid::Uuid::parse_str(n).is_ok())
            || name.strip_suffix(".part").is_some_and(|n| {
                uuid::Uuid::parse_str(n).is_ok()
                    || (n.len() == 24
                        && n.bytes()
                            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c)))
            });
        // Remote upload prefixes have no local job until metadata arrives. Keep
        // their restart capability for a week instead of deleting fresh uploads.
        let abandoned_upload = name
            .strip_suffix(".upload.part")
            .and_then(|n| n.split_once('.'))
            .is_some_and(|(sha, size)| {
                valid_digest(sha)
                    && size.parse::<u64>().is_ok()
                    && !referenced.contains(sha)
                    && entry
                        .metadata()
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|time| time.elapsed().ok())
                        .is_some_and(|age| age >= Duration::from_secs(7 * 24 * 60 * 60))
            });
        if orphan_download || staging || abandoned_upload {
            candidates.push(entry.path());
        }
    }
    Ok(candidates)
}

pub(super) fn cleanup(root: &Path, clear_trash: bool) -> Result<Value> {
    // The host blocks new edits, drains accepted work and closes the native
    // connection first. A direct call on a live store must fail safely.
    if let Some(all) = DATABASES.get()
        && all
            .lock()
            .map_err(|_| "Database unavailable")?
            .contains_key(root)
    {
        return Err("请先暂停并关闭当前存储会话".into());
    }
    layout::prepare(root)?;
    if blobs::has_writers(root)? {
        return Err("请先暂停并关闭当前文件传输".into());
    }
    backup::verify(root)?;
    let mut db = Connection::open_with_flags(
        layout::database(root),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
    )?;
    db.busy_timeout(Duration::from_secs(15))?;
    db.execute_batch("PRAGMA synchronous=FULL;")?;
    let cleared_trash = if clear_trash {
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let count =
            tx.execute("DELETE FROM trash", [])? + tx.execute("DELETE FROM favorite_trash", [])?;
        tx.execute("DELETE FROM transfer_jobs WHERE json_extract(body,'$.type') IN ('favorite','favorite_snapshot') AND NOT EXISTS(SELECT 1 FROM favorites f WHERE f.id=json_extract(transfer_jobs.body,'$.favorite.id') AND json_extract(f.body,'$.value')=1)", [])?;
        // Commit the user-requested removal before touching files. A rollback
        // must never resurrect trash whose original bytes were just removed.
        tx.commit()?;
        count
    } else {
        0
    };
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let referenced = references(&tx)?;
    let candidates = tx
        .prepare("SELECT digest,path FROM attachment_files")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let boundary = root.canonicalize()?;
    let mut released_bytes = 0u64;
    let mut removed_files = 0u64;
    let mut kept_files = 0u64;
    for (digest, relative) in candidates {
        if referenced.contains(&digest) {
            continue;
        }
        let parts = Path::new(&relative).components().collect::<Vec<_>>();
        if !valid_digest(&digest)
            || parts.len() != 2
            || !matches!(parts[0].as_os_str().to_str(), Some("media" | "files"))
            || parts
                .iter()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            kept_files += 1;
            continue;
        }
        let path = root.join(&relative);
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                tx.execute("DELETE FROM attachment_files WHERE path=?", [&relative])?;
                continue;
            }
            Err(_) => {
                kept_files += 1;
                continue;
            }
        };
        if !metadata.is_file()
            || linked(&metadata)
            || !path
                .canonicalize()
                .is_ok_and(|value| value.starts_with(&boundary))
            || !hash_file(&path).is_ok_and(|value| value == digest)
        {
            kept_files += 1;
            continue;
        }
        let unchanged = fs::symlink_metadata(&path).is_ok_and(|after| {
            after.is_file()
                && !linked(&after)
                && after.len() == metadata.len()
                && after.modified().ok() == metadata.modified().ok()
        });
        if !unchanged || fs::remove_file(&path).is_err() {
            kept_files += 1;
            continue;
        }
        tx.execute("DELETE FROM attachment_files WHERE path=?", [&relative])?;
        released_bytes += metadata.len();
        removed_files += 1;
    }
    for path in temporary_candidates(root, &tx, &referenced)? {
        let metadata = match fs::symlink_metadata(&path) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if !metadata.is_file()
            || linked(&metadata)
            || !path
                .canonicalize()
                .is_ok_and(|resolved| resolved.starts_with(&boundary))
        {
            kept_files += 1;
            continue;
        }
        if path.parent() == Some(layout::pending(root).as_path())
            && !hash_file(&path).is_ok_and(|sha| {
                path.file_name().and_then(|name| name.to_str()) == Some(sha.as_str())
            })
        {
            kept_files += 1;
            continue;
        }
        let unchanged = fs::symlink_metadata(&path).is_ok_and(|after| {
            after.is_file()
                && !linked(&after)
                && after.len() == metadata.len()
                && after.modified().ok() == metadata.modified().ok()
        });
        if !unchanged {
            kept_files += 1;
            continue;
        }
        if fs::remove_file(&path).is_ok() {
            released_bytes += metadata.len();
            removed_files += 1;
        } else {
            kept_files += 1;
        }
    }
    tx.commit()?;
    Ok(
        json!({"releasedBytes":released_bytes,"removedFiles":removed_files,
        "keptFiles":kept_files,"clearedTrash":cleared_trash}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_reclaims_orphans_but_preserves_resumable_jobs_and_recent_remote_uploads() {
        let root = crate::tests::root();
        initialize(&root).unwrap();
        let key = "device:gc-peer";
        let mut keep = Vec::new();
        let mut deleted_partial = PathBuf::new();
        for (index, state) in ["paused", "cancelled", "queued"].into_iter().enumerate() {
            let sha = digest(format!("payload-{index}").as_bytes());
            let item = json!({"id":format!("gc-message-{index:016}"),"originId":"device-gc-origin","originName":"Device","createdAt":now(),"kind":"file","text":"","name":"pending.bin","size":100,"sha256":sha});
            let event = item_event(&item);
            let shared = database(&root).unwrap();
            let db = shared.lock().unwrap();
            transfers::enqueue(
                &db,
                key,
                "download",
                &json!({"sequence":index+1,"event":event}),
            )
            .unwrap();
            db.execute(
                "UPDATE transfer_jobs SET state=? WHERE event_id=?",
                params![state, event["id"].as_str().unwrap()],
            )
            .unwrap();
            drop(db);
            drop(shared);
            let partial = layout::incoming(&root).join(format!(
                "download-{}.part",
                digest(format!("{key}:{sha}").as_bytes())
            ));
            fs::write(&partial, b"partial").unwrap();
            if state == "queued" {
                dispatch(json!({"op":"delete","root":root,"id":item["id"]})).unwrap();
                deleted_partial = partial;
            } else {
                keep.push(partial);
            }
        }
        let pending = layout::pending(&root).join(digest(b"orphan"));
        fs::write(&pending, b"orphan").unwrap();
        let stage = layout::incoming(&root).join(format!("{}.stage", uuid::Uuid::new_v4()));
        fs::write(&stage, b"staged").unwrap();
        let recent =
            layout::incoming(&root).join(format!("{}.100.upload.part", digest(b"remote recent")));
        fs::write(&recent, b"recent").unwrap();
        keep.push(recent);
        let old =
            layout::incoming(&root).join(format!("{}.100.upload.part", digest(b"remote old")));
        fs::write(&old, b"expired").unwrap();
        File::options()
            .write(true)
            .open(&old)
            .unwrap()
            .set_times(
                fs::FileTimes::new().set_modified(
                    std::time::SystemTime::now() - Duration::from_secs(8 * 24 * 60 * 60),
                ),
            )
            .unwrap();
        let unknown = layout::incoming(&root).join("user-important.txt");
        fs::write(&unknown, b"keep").unwrap();
        keep.push(unknown);
        dispatch(json!({"op":"close","root":root})).unwrap();
        let result = cleanup(&root, true).unwrap();
        assert_eq!(result["removedFiles"], 4);
        for removed in [pending, stage, old, deleted_partial] {
            assert!(!removed.exists(), "{}", removed.display());
        }
        for retained in keep {
            assert!(retained.exists(), "{}", retained.display());
        }
        crate::tests::cleanup(&root);
    }

    fn attachment(root: &Path, name: &str, bytes: &[u8]) -> Value {
        let source = root.join("source.tmp");
        fs::write(&source, bytes).unwrap();
        let stored = dispatch(
            json!({"op":"import_file","root":root,"path":source,"name":name,"kind":"file"}),
        )
        .unwrap();
        fs::remove_file(source).unwrap();
        json!({"id":uuid::Uuid::new_v4().simple().to_string(),"originId":"a".repeat(32),"originName":"本机",
            "createdAt":now(),"kind":"file","text":"","name":name,"size":bytes.len(),"sha256":stored["sha256"]})
    }

    #[test]
    fn cleanup_protects_live_trash_draft_transfer_user_and_modified_files() {
        let root = std::env::temp_dir().join(format!("lanflow-cleanup-{}", uuid::Uuid::new_v4()));
        initialize(&root).unwrap();
        let live = attachment(&root, "live.bin", b"live bytes");
        let trashed = attachment(&root, "trash.bin", b"trash bytes");
        let draft = attachment(&root, "draft.bin", b"draft bytes");
        let transfer = attachment(&root, "paused.bin", b"paused bytes");
        let modified = attachment(&root, "edited.bin", b"before");
        let orphan = attachment(&root, "orphan.bin", b"orphan bytes");
        for item in [&live, &trashed] {
            dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
        }
        let mut shared_live = live.clone();
        shared_live["id"] = json!(uuid::Uuid::new_v4().simple().to_string());
        dispatch(json!({"op":"add","root":root,"item":shared_live})).unwrap();
        dispatch(json!({"op":"delete","root":root,"id":shared_live["id"]})).unwrap();
        dispatch(json!({"op":"delete","root":root,"id":trashed["id"]})).unwrap();
        dispatch(json!({"op":"save_meta","root":root,"value":{"imageDrafts":{"self":[draft]}}}))
            .unwrap();
        {
            let shared = database(&root).unwrap();
            let db = shared.lock().unwrap();
            db.execute("INSERT INTO transfer_jobs(endpoint,direction,event_id,sequence,body,state) VALUES('offline','upload','paused-event-0001',1,?,'paused')", [item_event(&transfer).to_string()]).unwrap();
        }
        fs::write(root.join("files/edited.bin"), b"edited").unwrap();
        fs::write(root.join("files/user.txt"), b"unindexed user file").unwrap();
        assert!(cleanup(&root, true).is_err());
        assert!(root.join("files/orphan.bin").exists());
        dispatch(json!({"op":"close","root":root})).unwrap();
        let result = cleanup(&root, false).unwrap();
        assert_eq!(result["removedFiles"], 1);
        assert_eq!(result["releasedBytes"], orphan["size"]);
        assert_eq!(result["clearedTrash"], 0);
        assert_eq!(result["keptFiles"], 1);
        for name in [
            "live.bin",
            "trash.bin",
            "draft.bin",
            "paused.bin",
            "edited.bin",
            "user.txt",
        ] {
            assert!(root.join("files").join(name).exists(), "{name}");
        }
        let result = cleanup(&root, true).unwrap();
        assert_eq!(result["clearedTrash"], 2);
        assert_eq!(result["removedFiles"], 1);
        assert_eq!(result["releasedBytes"], trashed["size"]);
        assert_eq!(fs::read(root.join("files/edited.bin")).unwrap(), b"edited");
        let db = Connection::open(layout::database(&root)).unwrap();
        assert!(deleted(&db, trashed["id"].as_str().unwrap()).unwrap());
        assert_eq!(
            db.query_row("SELECT count(*) FROM trash", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM events", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            5
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM attachment_files WHERE digest=?",
                [modified["sha256"].as_str().unwrap()],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        drop(db);
        assert!(root.starts_with(std::env::temp_dir()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cleanup_never_follows_an_indexed_external_directory_link() {
        let root =
            std::env::temp_dir().join(format!("lanflow-cleanup-link-{}", uuid::Uuid::new_v4()));
        let outside =
            std::env::temp_dir().join(format!("lanflow-cleanup-outside-{}", uuid::Uuid::new_v4()));
        initialize(&root).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("keep.bin"), b"outside file").unwrap();
        attachment(&root, "linked.bin", b"original indexed file");
        let path = root.join("files").join("linked.bin");
        fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &path).unwrap();
        #[cfg(windows)]
        {
            let output = std::process::Command::new("cmd")
                .args(["/c", "mklink", "/J"])
                .arg(&path)
                .arg(&outside)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        dispatch(json!({"op":"close","root":root})).unwrap();
        let result = cleanup(&root, false).unwrap();
        assert_eq!(result["keptFiles"], 1);
        assert_eq!(result["releasedBytes"], 0);
        assert_eq!(fs::read(outside.join("keep.bin")).unwrap(), b"outside file");
        #[cfg(unix)]
        fs::remove_file(path).unwrap();
        #[cfg(windows)]
        fs::remove_dir(path).unwrap();
        assert!(root.starts_with(std::env::temp_dir()));
        assert!(outside.starts_with(std::env::temp_dir()));
        fs::remove_dir_all(root).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }
}
