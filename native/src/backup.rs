use super::*;

fn checked_connection(root: &Path) -> Result<Connection> {
    let path = layout::database(root);
    if !path.is_file() {
        return Err("备份缺少消息数据库".into());
    }
    let db = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    db.busy_timeout(Duration::from_secs(15))?;
    let check: String = db.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if check != "ok" {
        return Err("消息数据库校验未通过，原数据保留".into());
    }
    for name in ["items", "events", "meta"] {
        let present: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
            [name],
            |r| r.get(0),
        )?;
        if !present {
            return Err("备份缺少必要的消息数据".into());
        }
    }
    Ok(db)
}

pub(super) fn verify(root: &Path) -> Result<Value> {
    checked_connection(root)?;
    Ok(json!(true))
}

pub(super) fn database(root: &Path, path: &Path) -> Result<Value> {
    let original = checked_connection(root)?;
    // Reserve the exact output before opening SQLite; never truncate a prior backup.
    let reserved = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    drop(reserved);
    let result = (|| -> Result<()> {
        let mut copy = Connection::open(path)?;
        rusqlite::backup::Backup::new(&original, &mut copy)?.run_to_completion(
            128,
            Duration::from_millis(5),
            None,
        )?;
        let check: String = copy.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        if check != "ok" {
            return Err("消息数据库校验未通过，原数据保留".into());
        }
        copy.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")?;
        drop(copy);
        fs::OpenOptions::new().write(true).open(path)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(path);
    }
    result?;
    Ok(json!(true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_backup_includes_committed_wal_and_never_overwrites_an_output() {
        let root = std::env::temp_dir().join(format!("lanflow-backup-{}", uuid::Uuid::new_v4()));
        initialize(&root).unwrap();
        let shared = super::super::database(&root).unwrap();
        let db = shared.lock().unwrap();
        db.execute_batch(
            "PRAGMA wal_autocheckpoint=0; INSERT INTO meta VALUES('backup-test','kept');",
        )
        .unwrap();
        let output = root.join("snapshot.sqlite3");
        database(&root, &output).unwrap();
        let saved = Connection::open(&output).unwrap();
        assert_eq!(
            saved
                .query_row("SELECT body FROM meta WHERE key='backup-test'", [], |r| {
                    r.get::<_, String>(0)
                })
                .unwrap(),
            "kept"
        );
        assert!(database(&root, &output).is_err());
        drop(saved);
        drop(db);
        drop(shared);
        dispatch(json!({"op":"close", "root":root})).unwrap();
        assert!(root.starts_with(std::env::temp_dir()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn verification_rejects_missing_empty_and_damaged_databases() {
        let root =
            std::env::temp_dir().join(format!("lanflow-backup-invalid-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(layout::system(&root)).unwrap();
        assert!(verify(&root).is_err());
        assert!(!layout::database(&root).exists());
        File::create(layout::database(&root)).unwrap();
        assert!(verify(&root).is_err());
        fs::write(layout::database(&root), b"damaged SQLite").unwrap();
        assert!(verify(&root).is_err());
        assert!(root.starts_with(std::env::temp_dir()));
        fs::remove_dir_all(root).unwrap();
    }
}
