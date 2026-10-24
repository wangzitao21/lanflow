use super::*;

type Paths = HashMap<PathBuf, HashMap<String, Vec<String>>>;
static PATHS: OnceLock<Mutex<Paths>> = OnceLock::new();
type Organizers = HashMap<(PathBuf, String), std::sync::Weak<Mutex<()>>>;
static ORGANIZERS: OnceLock<Mutex<Organizers>> = OnceLock::new();
#[cfg(test)]
type CopyObservers = HashMap<PathBuf, Box<dyn FnOnce() + Send>>;
#[cfg(test)]
static COPY_OBSERVERS: OnceLock<Mutex<CopyObservers>> = OnceLock::new();

pub(super) fn organizer(root: &Path, digest: &str) -> Result<Arc<Mutex<()>>> {
    let mut all = ORGANIZERS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Attachment organizer unavailable")?;
    all.retain(|_, value| value.strong_count() > 0);
    let key = (root.to_owned(), digest.to_owned());
    if let Some(lock) = all.get(&key).and_then(std::sync::Weak::upgrade) {
        return Ok(lock);
    }
    let lock = Arc::new(Mutex::new(()));
    all.insert(key, Arc::downgrade(&lock));
    Ok(lock)
}

pub(super) fn forget(root: &Path) {
    if let Ok(mut paths) = PATHS.get_or_init(Default::default).lock() {
        paths.remove(root);
    }
}

pub(super) fn load(root: &Path, db: &Connection) -> Result<()> {
    let mut paths: HashMap<String, Vec<String>> = HashMap::new();
    let mut statement = db.prepare("SELECT digest,path FROM attachment_files ORDER BY rowid")?;
    for row in statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (digest, path) = row?;
        validate_relative(&path)?;
        paths.entry(digest).or_default().push(path);
    }
    PATHS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Attachment index unavailable")?
        .insert(root.to_path_buf(), paths);
    Ok(())
}

fn validate_relative(path: &str) -> Result<()> {
    let parts: Vec<_> = Path::new(path).components().collect();
    if parts.len() != 2
        || !matches!(parts[0].as_os_str().to_str(), Some("media" | "files"))
        || parts
            .iter()
            .any(|p| !matches!(p, std::path::Component::Normal(_)))
    {
        return Err("附件索引路径无效".into());
    }
    Ok(())
}

pub(super) fn path(root: &Path, digest: &str) -> PathBuf {
    if let Ok(all) = PATHS.get_or_init(Default::default).lock()
        && let Some(paths) = all.get(root).and_then(|paths| paths.get(digest))
    {
        for relative in paths {
            let path = root.join(relative);
            if fs::symlink_metadata(&path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            {
                return path;
            }
        }
        let pending = layout::pending(root).join(digest);
        if pending.is_file() {
            return pending;
        }
        if let Some(first) = paths.first() {
            return root.join(first);
        }
    }
    layout::pending(root).join(digest)
}

fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("file");
    let mut name: String = base
        .chars()
        .map(|c| {
            if c.is_control() || "<>:\"/\\|?*".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    name = name.trim_end_matches(['.', ' ']).to_owned();
    if name.is_empty() {
        name = "file".to_owned();
    }
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    if ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
    {
        name.insert(0, '_');
    }
    // Windows and Android also limit the UTF-8 byte length of a filename.
    while name.len() > 240 {
        name.remove(0);
    }
    name
}

fn remember(root: &Path, digest: &str, relative: &str) -> Result<()> {
    let mut all = PATHS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Attachment index unavailable")?;
    let paths = all
        .entry(root.to_path_buf())
        .or_default()
        .entry(digest.to_owned())
        .or_default();
    if !paths.iter().any(|path| path == relative) {
        paths.push(relative.to_owned());
    }
    Ok(())
}

fn verify_copy(root: &Path, source: &Path, target: &Path, digest: &str) -> Result<()> {
    #[cfg(test)]
    {
        let observer = COPY_OBSERVERS
            .get_or_init(Default::default)
            .lock()
            .unwrap()
            .remove(root);
        if let Some(observer) = observer {
            observer();
        }
    }
    if fs::symlink_metadata(source)?.file_type().is_symlink() {
        return Err("附件路径包含链接".into());
    }
    if target.exists() {
        if fs::symlink_metadata(target)?.file_type().is_symlink() {
            return Err("附件路径包含链接".into());
        }
        if !verified_files::check(target, digest, fs::metadata(source)?.len())? {
            // An interrupted fallback copy must not block the next startup.
            // Preserve its bytes before completing the reserved destination.
            if source == target {
                return Err("附件内容已改变，请重新导入原文件".into());
            }
            blobs::preserve_modified(root, target)?;
        } else {
            return Ok(());
        }
    }
    // A link followed by removing the private staging name is an atomic move
    // without overwriting a concurrent file or making a second data copy.
    if source.parent() == Some(layout::pending(root).as_path()) {
        if !verified_files::check(source, digest, fs::metadata(source)?.len())? {
            return Err("附件整理校验失败，原文件已保留".into());
        }
        if fs::hard_link(source, target).is_ok() {
            return Ok(());
        }
    }
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)?;
    let result = (|| -> Result<()> {
        let mut source = File::open(source)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0; 256 * 1024];
        loop {
            let count = source.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            output.write_all(&buffer[..count])?;
            hasher.update(&buffer[..count]);
        }
        output.sync_all()?;
        if hex::encode(hasher.finalize()) != digest {
            return Err("附件整理校验失败，原文件已保留".into());
        }
        Ok(())
    })();
    drop(output);
    if result.is_err() {
        let _ = fs::remove_file(target);
    }
    result
}

struct Prepared {
    digest: String,
    relative: String,
    source: Option<PathBuf>,
    verify: Option<u64>,
}

// Only pathname selection and durable reservation need the database lock.
// Never hash or copy attachment bytes while holding that lock.
fn prepare(root: &Path, db: &Connection, item: &Value) -> Result<Option<Prepared>> {
    if item["kind"] == "text" {
        return Ok(None);
    }
    let digest = string(item, "sha256")?;
    if !valid_digest(digest) {
        return Err("Invalid file digest".into());
    }
    let category = if matches!(item["kind"].as_str(), Some("image" | "video")) {
        "media"
    } else {
        "files"
    };
    let name = safe_name(string(item, "name")?);
    let existing: Option<String> = db
        .query_row(
            "SELECT path FROM attachment_files WHERE digest=? AND name=? AND category=?",
            params![digest, name, category],
            |r| r.get(0),
        )
        .optional()?;
    let pending = layout::pending(root).join(digest);
    let source = if pending.is_file() {
        pending.clone()
    } else {
        path(root, digest)
    };
    if fs::metadata(&source).map(|m| m.len()).ok() != item["size"].as_u64() {
        return Ok(existing.map(|relative| Prepared {
            digest: digest.to_owned(),
            relative,
            source: None,
            verify: None,
        }));
    }
    if let Some(relative) = &existing {
        if !pending.is_file() && root.join(relative).is_file() {
            if fs::symlink_metadata(root.join(relative))?
                .file_type()
                .is_symlink()
            {
                return Err("附件路径包含链接".into());
            }
            if source != root.join(relative) {
                return Ok(Some(Prepared {
                    digest: digest.to_owned(),
                    relative: relative.clone(),
                    source: Some(source),
                    verify: None,
                }));
            }
            return Ok(Some(Prepared {
                digest: digest.to_owned(),
                relative: relative.clone(),
                source: None,
                verify: item["size"].as_u64(),
            }));
        }
    }
    fs::create_dir_all(root.join(category))?;
    let relative = if let Some(relative) = existing {
        relative
    } else {
        let extension = Path::new(&name)
            .extension()
            .and_then(|v| v.to_str())
            .map(|v| format!(".{v}"))
            .unwrap_or_default();
        let stem = name.strip_suffix(&extension).unwrap_or(&name);
        let mut index = 1;
        loop {
            let candidate = if index == 1 {
                name.clone()
            } else {
                format!("{stem} ({index}){extension}")
            };
            let relative = format!("{category}/{candidate}");
            let reserved: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM attachment_files WHERE path=? COLLATE NOCASE)",
                [&relative],
                |r| r.get(0),
            )?;
            if !reserved && !root.join(&relative).exists() {
                db.execute(
                    "INSERT INTO attachment_files(digest,name,category,path,ready) VALUES(?,?,?,?,0)",
                    params![digest, name, category, relative],
                )?;
                break relative;
            }
            index += 1;
        }
    };
    validate_relative(&relative)?;
    Ok(Some(Prepared {
        digest: digest.to_owned(),
        relative,
        source: Some(source),
        verify: None,
    }))
}

fn finish(root: &Path, prepared: Option<Prepared>) -> Result<Option<String>> {
    let Some(Prepared {
        digest,
        relative,
        source,
        verify,
    }) = prepared
    else {
        return Ok(None);
    };
    if let Some(size) = verify
        && !verified_files::check(&root.join(&relative), &digest, size)?
    {
        return Err("附件内容已改变，请重新导入原文件".into());
    }
    if let Some(source) = source {
        let target = root.join(&relative);
        // Reserve the pathname durably before moving bytes. A restart can complete
        // a reserved-but-unfinished move using the unchanged staged original.
        verify_copy(root, &source, &target, &digest)?;
        blobs::sync_directory(target.parent().ok_or("Invalid attachment path")?)?;
        if source.parent() == Some(layout::pending(root).as_path()) {
            fs::remove_file(&source)?;
        }
    }
    remember(root, &digest, &relative)?;
    Ok(Some(relative))
}

pub(super) fn register(
    root: &Path,
    shared: &Mutex<Connection>,
    item: &Value,
) -> Result<Option<String>> {
    Ok(register_changed(root, shared, item)?.0)
}

pub(super) fn register_changed(
    root: &Path,
    shared: &Mutex<Connection>,
    item: &Value,
) -> Result<(Option<String>, bool)> {
    if item["kind"] == "text" {
        return Ok((None, false));
    }
    let lock = organizer(root, string(item, "sha256")?)?;
    let _organizing = lock
        .lock()
        .map_err(|_| "Attachment organizer unavailable")?;
    let prepared = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        prepare(root, &db, item)?
    };
    let published = prepared
        .as_ref()
        .is_some_and(|value| value.source.is_some());
    let path = finish(root, prepared)?;
    let changed = if let Some(path) = &path
        && root.join(path).is_file()
    {
        let mut db = shared.lock().map_err(|_| "Database unavailable")?;
        let tx = db.transaction()?;
        let became_ready = tx.execute(
            "UPDATE attachment_files SET ready=1 WHERE path=? AND ready=0",
            [path],
        )? > 0;
        let changed = if published || became_ready {
            // A repaired file or a delayed favorite blob can become available
            // after its event was already received. Publish that availability
            // atomically with ready, including recovery after a file move.
            let digest = string(item, "sha256")?;
            let items = tx.execute(
                "UPDATE items SET body=body WHERE json_valid(body) AND json_extract(body,'$.sha256')=?",
                [digest],
            )?;
            let favorites = tx.execute(
                "UPDATE favorites SET body=body WHERE json_extract(body,'$.item.sha256')=?",
                [digest],
            )?;
            items + favorites > 0
        } else {
            false
        };
        tx.commit()?;
        changed
    } else {
        false
    };
    Ok((path, changed))
}

pub(super) fn paths(db: &Connection) -> Result<Value> {
    let mut map = serde_json::Map::new();
    let mut rows = db.prepare("SELECT digest,path FROM attachment_files ORDER BY rowid")?;
    for row in rows.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (digest, path) = row?;
        map.entry(digest).or_insert(json!(path));
    }
    Ok(Value::Object(map))
}

pub(super) fn item_path(db: &Connection, item: &Value) -> Result<Option<String>> {
    Ok(db
        .query_row(
            "SELECT path FROM attachment_files WHERE digest=? ORDER BY rowid LIMIT 1",
            [item["sha256"].as_str().unwrap_or("")],
            |r| r.get(0),
        )
        .optional()?)
}

fn organization_items(db: &Connection) -> Result<Vec<Value>> {
    let bodies = db
        .prepare("SELECT body FROM items WHERE json_extract(body,'$.kind')!='text' UNION SELECT body FROM trash WHERE json_extract(body,'$.kind')!='text' UNION SELECT json_extract(body,'$.item') FROM favorites WHERE json_extract(body,'$.value')=1 AND json_extract(body,'$.item.kind')!='text' UNION SELECT body FROM favorite_trash WHERE json_extract(body,'$.kind')!='text'")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut items = bodies
        .iter()
        .map(|body| serde_json::from_str::<Value>(body))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let settings: Option<String> = db
        .query_row("SELECT body FROM meta WHERE key='settings'", [], |r| {
            r.get(0)
        })
        .optional()?;
    if let Some(settings) = settings {
        let settings: Value = serde_json::from_str(&settings)?;
        for images in settings["imageDrafts"]
            .as_object()
            .into_iter()
            .flat_map(|v| v.values())
        {
            for item in images.as_array().into_iter().flatten() {
                items.push(item.clone());
            }
        }
    }
    Ok(items)
}

pub(super) fn organize(root: &Path, shared: &Mutex<Connection>) -> Result<()> {
    let items = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        startup_items(root, &db)?
    };
    for item in items {
        register(root, shared, &item)?;
    }
    shared.lock().map_err(|_| "Database unavailable")?.execute(
        "INSERT OR REPLACE INTO meta VALUES('attachments_organized','1')",
        [],
    )?;
    Ok(())
}

// NAS startup has an exclusively owned connection before its server starts.
#[cfg(feature = "hub")]
pub(super) fn organize_startup(root: &Path, db: &Connection) -> Result<()> {
    for item in startup_items(root, db)? {
        if let Some(path) = finish(root, prepare(root, db, &item)?)?
            && root.join(&path).is_file()
        {
            db.execute(
                "UPDATE attachment_files SET ready=1 WHERE path=? AND ready=0",
                [path],
            )?;
        }
    }
    db.execute(
        "INSERT OR REPLACE INTO meta VALUES('attachments_organized','1')",
        [],
    )?;
    Ok(())
}

fn startup_items(root: &Path, db: &Connection) -> Result<Vec<Value>> {
    let migrated: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='attachments_organized')",
        [],
        |r| r.get(0),
    )?;
    let pending = fs::read_dir(layout::pending(root))?.next().is_some();
    let mut items = if !migrated || pending {
        organization_items(db)?
    } else {
        Vec::new()
    };
    // Interrupted reservations are durable, so ordinary starts need not parse
    // every historical message or stat every already-organized attachment.
    let mut statement =
        db.prepare("SELECT digest,name,category FROM attachment_files WHERE ready=0")?;
    for row in statement.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })? {
        let (digest, name, category) = row?;
        if let Ok(metadata) = fs::metadata(path(root, &digest)) {
            items.push(json!({"sha256":digest,"name":name,"kind":if category=="media" {"image"} else {"file"},"size":metadata.len()}));
        }
    }
    let mut selected = Vec::new();
    let mut identities = std::collections::HashSet::new();
    for item in items {
        let sha = string(&item, "sha256")?;
        let name = safe_name(string(&item, "name")?);
        let category = if matches!(item["kind"].as_str(), Some("image" | "video")) {
            "media"
        } else {
            "files"
        };
        if !identities.insert((sha.to_owned(), name.clone(), category)) {
            continue;
        }
        let organized: Option<(String, bool)> = db
            .query_row(
                "SELECT path,ready FROM attachment_files WHERE digest=? AND name=? AND category=?",
                params![sha, name, category],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        // Upgrading a healthy layout must remain possible even if a user has
        // externally edited an existing attachment. Verify at use/import time;
        // a staged original always takes precedence so it can repair all aliases.
        let primary = organized
            .as_ref()
            .is_some_and(|(relative, _)| root.join(relative) == path(root, sha));
        if !layout::pending(root).join(sha).is_file()
            && organized.as_ref().is_some_and(|(path, ready)| {
                *ready
                    && fs::symlink_metadata(root.join(path))
                        .is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            })
        {
            continue;
        }
        selected.push((!primary, item));
    }
    // Repair the canonical indexed copy before consuming its staged original;
    // other aliases can then use that verified copy even if they were edited too.
    selected.sort_by_key(|(secondary, _)| *secondary);
    Ok(selected.into_iter().map(|(_, item)| item).collect())
}

#[cfg(test)]
#[path = "attachment_performance_tests.rs"]
mod performance_tests;
