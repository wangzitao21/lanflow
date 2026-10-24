use super::*;

pub(super) fn database(root: &Path) -> Result<Database> {
    let mut all = DATABASES
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Database registry unavailable")?;
    if let Some(db) = all.get(root) {
        return Ok(db.clone());
    }
    layout::prepare(root)?;
    let mut db = Connection::open(layout::database(root))?;
    schema(&mut db, false)?;
    attachments::load(root, &db)?;
    let value = Arc::new(Mutex::new(db));
    all.insert(root.to_path_buf(), value.clone());
    Ok(value)
}

fn schema(db: &mut Connection, hub: bool) -> Result<()> {
    db.busy_timeout(Duration::from_secs(if hub { 30 } else { 15 }))?;
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")?;
    let tx = db.transaction()?;
    // Preserve both deployed layouts, including the NAS v2 item cursor. Only
    // additive tables are needed; no message or event is renumbered/replayed.
    tx.execute_batch(if hub {
        "CREATE TABLE IF NOT EXISTS items(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, body TEXT NOT NULL);"
    } else {
        "CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, sequence INTEGER NOT NULL, body TEXT NOT NULL);"
    })?;
    tx.execute_batch("
        CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS deleted(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, event_id TEXT NOT NULL, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, event_id TEXT NOT NULL, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS favorites(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, event_id TEXT NOT NULL, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS copies(item_id TEXT NOT NULL, endpoint TEXT NOT NULL, PRIMARY KEY(item_id,endpoint));
        CREATE TABLE IF NOT EXISTS seen(event_id TEXT NOT NULL, endpoint TEXT NOT NULL, PRIMARY KEY(event_id,endpoint));
        CREATE TABLE IF NOT EXISTS cursors(endpoint TEXT PRIMARY KEY, pushed INTEGER NOT NULL DEFAULT 0, pulled INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS attachment_files(digest TEXT NOT NULL,name TEXT NOT NULL,category TEXT NOT NULL,path TEXT NOT NULL UNIQUE COLLATE NOCASE,PRIMARY KEY(digest,name,category));
        CREATE TABLE IF NOT EXISTS trash(id TEXT PRIMARY KEY, body TEXT NOT NULL, deleted_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS transfer_jobs(endpoint TEXT NOT NULL, direction TEXT NOT NULL, event_id TEXT NOT NULL, sequence INTEGER NOT NULL, body TEXT NOT NULL, transferred INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'queued', error TEXT, retry_after INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(endpoint,direction,event_id));
        CREATE TABLE IF NOT EXISTS revision(value INTEGER NOT NULL);
        INSERT INTO revision SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM revision);
        CREATE TABLE IF NOT EXISTS content_revision(value INTEGER NOT NULL);
        INSERT INTO content_revision SELECT value FROM revision WHERE NOT EXISTS(SELECT 1 FROM content_revision);
        CREATE TABLE IF NOT EXISTS state_changes(kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(kind,id));
        CREATE INDEX IF NOT EXISTS state_changes_revision ON state_changes(revision);
        CREATE INDEX IF NOT EXISTS items_sequence ON items(sequence);
        CREATE INDEX IF NOT EXISTS items_sequence_id ON items(sequence,id);
        CREATE INDEX IF NOT EXISTS items_conversation_sequence ON items(COALESCE(json_extract(body,'$.conversationId'),'lanflow-self-chat'),sequence,json_extract(body,'$.originId')) WHERE json_valid(body);
        CREATE INDEX IF NOT EXISTS items_conversation_date ON items(COALESCE(json_extract(body,'$.conversationId'),'lanflow-self-chat'),julianday(json_extract(body,'$.createdAt')) DESC,id DESC) WHERE json_valid(body);
        CREATE INDEX IF NOT EXISTS items_kind_date ON items(json_extract(body,'$.kind'),julianday(json_extract(body,'$.createdAt')) DESC,id DESC) WHERE json_valid(body);
        CREATE INDEX IF NOT EXISTS items_date ON items(julianday(json_extract(body,'$.createdAt')) DESC,id DESC) WHERE json_valid(body);
        CREATE INDEX IF NOT EXISTS items_attachment_digest ON items(json_extract(body,'$.sha256')) WHERE json_valid(body);
        CREATE INDEX IF NOT EXISTS trash_date ON trash(deleted_at DESC,id DESC);
        CREATE INDEX IF NOT EXISTS transfer_item ON transfer_jobs(json_extract(body,'$.item.id'));
        INSERT OR IGNORE INTO meta SELECT 'state_journal_base',CAST(value AS TEXT) FROM revision;")?;
    tx.execute_batch(
        "UPDATE attachment_files SET
        category=CASE category WHEN '媒体' THEN 'media' WHEN '文件' THEN 'files' ELSE category END,
        path=CASE WHEN substr(path,1,3)='媒体/' THEN 'media/' || substr(path,4)
                  WHEN substr(path,1,3)='文件/' THEN 'files/' || substr(path,4) ELSE path END
        WHERE category IN ('媒体','文件') OR substr(path,1,3) IN ('媒体/','文件/');",
    )?;
    // Keep the latest changed revision per entity, not a second unbounded log.
    // Triggers make state changes and revision updates atomic, including copy
    // receipts written by the background synchronizer.
    for (table, kind, column) in [
        ("items", "item", "id"),
        ("copies", "item", "item_id"),
        ("profiles", "profile", "id"),
        ("conversations", "conversation", "id"),
        ("favorites", "favorite", "id"),
        ("deleted", "deleted", "id"),
    ] {
        for action in ["INSERT", "UPDATE", "DELETE"] {
            if table == "deleted" && action != "INSERT" {
                continue;
            }
            let row = if action == "DELETE" { "OLD" } else { "NEW" };
            let history = if table == "items" {
                // Replace older triggers in the same schema transaction.
                tx.execute_batch(&format!("DROP TRIGGER IF EXISTS state_{table}_{action};"))?;
                let record = |row: &str| {
                    format!(
                        "INSERT INTO state_changes(kind,id,revision) SELECT 'history',COALESCE(json_extract({row}.body,'$.conversationId'),'lanflow-self-chat'),(SELECT value FROM revision) WHERE json_valid({row}.body) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision;"
                    )
                };
                format!(
                    "{}{}",
                    record(row),
                    if action == "UPDATE" {
                        record("OLD")
                    } else {
                        String::new()
                    }
                )
            } else {
                String::new()
            };
            tx.execute_batch(&format!(
                "CREATE TRIGGER IF NOT EXISTS state_{table}_{action} AFTER {action} ON {table} BEGIN
                 UPDATE revision SET value=value+1;
                 INSERT INTO state_changes(kind,id,revision) VALUES('{kind}',{row}.{column},(SELECT value FROM revision))
                 ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision;
                 {history} END;"
            ))?;
            if table != "copies" {
                // Receipts still refresh the local snapshot, but only content
                // wakes other devices. Keep these triggers separate so an
                // older app can reopen the database without removing them.
                tx.execute_batch(&format!(
                    "CREATE TRIGGER IF NOT EXISTS content_{table}_{action} AFTER {action} ON {table} BEGIN
                     UPDATE content_revision SET value=value+1; END;"
                ))?;
            }
        }
    }
    tx.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS state_events_INSERT AFTER INSERT ON events BEGIN
        UPDATE revision SET value=value+1; END;
        CREATE TRIGGER IF NOT EXISTS content_events_INSERT AFTER INSERT ON events BEGIN
        UPDATE content_revision SET value=value+1; END;",
    )?;
    for (column, definition) in [
        ("retry_after", "INTEGER NOT NULL DEFAULT 0"),
        ("failures", "INTEGER NOT NULL DEFAULT 0"),
        ("error_category", "TEXT"),
        ("completed_at", "INTEGER NOT NULL DEFAULT 0"),
        ("last_attempt", "INTEGER NOT NULL DEFAULT 0"),
    ] {
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('transfer_jobs') WHERE name=?)",
            [column],
            |r| r.get(0),
        )?;
        if !exists {
            tx.execute(
                &format!("ALTER TABLE transfer_jobs ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    tx.execute_batch("CREATE INDEX IF NOT EXISTS transfer_schedule ON transfer_jobs(endpoint,state,retry_after,sequence);
        CREATE INDEX IF NOT EXISTS transfer_completed ON transfer_jobs(state,completed_at DESC);
        CREATE INDEX IF NOT EXISTS transfer_fair_schedule ON transfer_jobs(endpoint,last_attempt,sequence) WHERE state IN ('queued','failed');
        CREATE INDEX IF NOT EXISTS transfer_attempt_order ON transfer_jobs(last_attempt);")?;
    let attachment_ready: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('attachment_files') WHERE name='ready')",
        [],
        |r| r.get(0),
    )?;
    if !attachment_ready {
        tx.execute(
            "ALTER TABLE attachment_files ADD COLUMN ready INTEGER NOT NULL DEFAULT 1",
            [],
        )?;
    }
    tx.execute_batch("CREATE INDEX IF NOT EXISTS attachment_unfinished ON attachment_files(ready) WHERE ready=0;")?;
    let favorite_cursor: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('cursors') WHERE name='favorites_supported')", [], |r| r.get(0))?;
    if !favorite_cursor {
        tx.execute(
            "ALTER TABLE cursors ADD COLUMN favorites_supported INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    let snapshot_cursor: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('cursors') WHERE name='favorite_snapshots_supported')", [], |r|r.get(0))?;
    if !snapshot_cursor {
        tx.execute("ALTER TABLE cursors ADD COLUMN favorite_snapshots_supported INTEGER NOT NULL DEFAULT 0",[])?;
    }
    search::schema(&tx)?;
    favorites::schema(&tx)?;
    tx.commit()?;
    Ok(())
}

pub(super) fn insert_item(db: &Connection, id: &str, sequence: i64, body: &str) -> Result<()> {
    let nas_sequence: bool = db.query_row(
        "SELECT pk=1 FROM pragma_table_info('items') WHERE name='sequence'",
        [],
        |r| r.get(0),
    )?;
    if nas_sequence {
        db.execute(
            "INSERT OR IGNORE INTO items(id,body) VALUES(?,?)",
            params![id, body],
        )?;
    } else {
        db.execute(
            "INSERT OR IGNORE INTO items(id,sequence,body) VALUES(?,?,?)",
            params![id, sequence, body],
        )?;
    }
    Ok(())
}

#[cfg(feature = "hub")]
pub(super) fn open_hub(root: &Path) -> Result<Connection> {
    layout::prepare(root)?;
    let path = layout::database(root);
    let existed = path.exists();
    let mut db = Connection::open(&path)?;
    db.busy_timeout(Duration::from_secs(30))?;
    let has_meta: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta')",
        [],
        |r| r.get(0),
    )?;
    let migrated = has_meta
        && db.query_row(
            "SELECT EXISTS(SELECT 1 FROM meta WHERE key='rust_hub')",
            [],
            |r| r.get::<_, bool>(0),
        )?;
    if existed && !migrated {
        let backup = layout::system(root).join("inbox.pre-rust.sqlite3");
        if !backup.exists() {
            let pending = layout::system(root).join(format!("{}.backup.tmp", uuid::Uuid::new_v4()));
            let result = (|| -> Result<()> {
                let mut copy = Connection::open(&pending)?;
                rusqlite::backup::Backup::new(&db, &mut copy)?.run_to_completion(
                    128,
                    Duration::from_millis(5),
                    None,
                )?;
                drop(copy);
                fs::OpenOptions::new()
                    .write(true)
                    .open(&pending)?
                    .sync_all()?;
                fs::rename(&pending, &backup)?;
                blobs::sync_directory(root)?;
                Ok(())
            })();
            if result.is_err() {
                let _ = fs::remove_file(&pending);
            }
            result?;
        }
    }
    schema(&mut db, true)?;
    attachments::load(root, &db)?;
    if !migrated {
        let tx = db.transaction()?;
        // Older NAS versions have items but no event log. Existing events,
        // tombstones and their sequence numbers are left exactly as persisted.
        {
            let mut rows = tx.prepare("SELECT body FROM items ORDER BY sequence")?;
            for body in rows.query_map([], |r| r.get::<_, String>(0))? {
                let event = item_event(&serde_json::from_str::<Value>(&body?)?);
                tx.execute(
                    "INSERT OR IGNORE INTO events(id,body) VALUES(?,?)",
                    params![string(&event, "id")?, serde_json::to_string(&event)?],
                )?;
            }
        }
        tx.execute("INSERT INTO meta VALUES('rust_hub','true')", [])?;
        tx.commit()?;
    }
    attachments::organize_startup(root, &db)?;
    Ok(db)
}

pub(super) fn items_page(db: &Connection, after: i64) -> Result<Value> {
    if after < 0 {
        return Err("Invalid cursor".into());
    }
    let mut statement =
        db.prepare("SELECT sequence,body FROM items WHERE sequence>? ORDER BY sequence LIMIT 51")?;
    let records = statement
        .query_map([after], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut items = Vec::new();
    let mut cursor = after;
    for (sequence, body) in records.iter().take(50) {
        let mut item: Value = serde_json::from_str(body)?;
        item["sequence"] = json!(sequence);
        items.push(item);
        cursor = *sequence;
    }
    Ok(json!({"items":items,"cursor":cursor,"more":records.len()>50}))
}

pub(super) fn snapshot_since(db: &Connection, known_revision: Option<i64>) -> Result<Value> {
    let revision: i64 = db.query_row("SELECT value FROM revision", [], |r| r.get(0))?;
    if known_revision == Some(revision) {
        return Ok(json!({"revision":revision,"changeCursor":change_cursor(db)?,"unchanged":true}));
    }
    let base: String = db.query_row(
        "SELECT body FROM meta WHERE key='state_journal_base'",
        [],
        |r| r.get(0),
    )?;
    if let Some(after) = known_revision
        .filter(|after| *after >= base.parse().unwrap_or(i64::MAX) && *after < revision)
    {
        delta(db, after, revision)
    } else {
        snapshot(db)
    }
}

fn delta(db: &Connection, after: i64, revision: i64) -> Result<Value> {
    let mut entries = Vec::new();
    let mut removed = Vec::new();
    let mut rows = db.prepare(
        "SELECT c.id,i.sequence,i.body FROM state_changes c
        LEFT JOIN items i ON i.id=c.id WHERE c.kind='item' AND c.revision>? ORDER BY i.sequence",
    )?;
    let mut copies = db.prepare("SELECT endpoint FROM copies WHERE item_id=? ORDER BY endpoint")?;
    for row in rows.query_map([after], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Option<i64>>(1)?,
            r.get::<_, Option<String>>(2)?,
        ))
    })? {
        let (id, sequence, body) = row?;
        if let Some(body) = body {
            let endpoints = copies
                .query_map([&id], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            let item: Value = serde_json::from_str(&body)?;
            entries.push(json!({"sequence":sequence,"blobPath":attachments::item_path(db, &item)?,"item":item,"copies":endpoints}));
        } else {
            removed.push(id);
        }
    }
    let mut value = json!({"revision":revision,"changeCursor":change_cursor(db)?,"baseRevision":after,"delta":true,"entries":entries,"removed":removed});
    for (kind, table) in [
        ("profile", "profiles"),
        ("conversation", "conversations"),
        ("favorite", "favorites"),
    ] {
        let mut statement = db.prepare(&format!(
            "SELECT t.id,t.body FROM {table} t JOIN state_changes c ON c.id=t.id WHERE c.kind=? AND c.revision>?"
        ))?;
        let mut map = serde_json::Map::new();
        for row in statement.query_map(params![kind, after], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            let (id, body) = row?;
            let body = serde_json::from_str(&body)?;
            map.insert(
                id,
                if table == "favorites" {
                    favorites::for_client(db, body)?
                } else {
                    body
                },
            );
        }
        value[table] = Value::Object(map);
    }
    let mut statement =
        db.prepare("SELECT id FROM state_changes WHERE kind='deleted' AND revision>?")?;
    let deleted = statement
        .query_map([after], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    value["deleted"] = json!(deleted);
    value["history"] = history::summaries(db, Some(after))?;
    Ok(value)
}

pub(super) fn snapshot(db: &Connection) -> Result<Value> {
    snapshot_content(db, true)
}

fn snapshot_content(db: &Connection, history: bool) -> Result<Value> {
    let mut copies: HashMap<String, Vec<String>> = HashMap::new();
    let mut entries = Vec::new();
    if history {
        let mut stmt = db.prepare("SELECT item_id,endpoint FROM copies")?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (id, endpoint) = row?;
            copies.entry(id).or_default().push(endpoint);
        }
        let mut stmt = db.prepare("SELECT sequence,body FROM items ORDER BY sequence")?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (sequence, body) = row?;
            let item: Value = serde_json::from_str(&body)?;
            entries.push(json!({"sequence":sequence,"copies":copies.get(item["id"].as_str().unwrap_or("")),"item":item}));
        }
    }
    let mut profiles = serde_json::Map::new();
    let mut stmt = db.prepare("SELECT id,body FROM profiles")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (id, body) = row?;
        profiles.insert(id, serde_json::from_str(&body)?);
    }
    let mut tombstones = Vec::new();
    for row in db
        .prepare("SELECT id FROM deleted")?
        .query_map([], |r| r.get::<_, String>(0))?
    {
        tombstones.push(row?);
    }
    let meta: Option<String> = db
        .query_row("SELECT body FROM meta WHERE key='settings'", [], |r| {
            r.get(0)
        })
        .optional()?;
    let mut value: Value = serde_json::from_str(meta.as_deref().unwrap_or("{}"))?;
    value["entries"] = json!(entries);
    value["blobPaths"] = attachments::paths(db)?;
    value["profiles"] = json!(profiles);
    let mut conversations = serde_json::Map::new();
    let mut stmt = db.prepare("SELECT id,body FROM conversations")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (id, body) = row?;
        conversations.insert(id, serde_json::from_str(&body)?);
    }
    value["conversations"] = json!(conversations);
    let mut favorites = serde_json::Map::new();
    for row in db
        .prepare("SELECT id,body FROM favorites")?
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
    {
        let (id, body) = row?;
        favorites.insert(
            id,
            crate::favorites::for_client(db, serde_json::from_str(&body)?)?,
        );
    }
    value["favorites"] = json!(favorites);
    value["deleted"] = json!(tombstones);
    value["revision"] =
        json!(db.query_row("SELECT value FROM revision", [], |r| r.get::<_, i64>(0))?);
    value["changeCursor"] = json!(change_cursor(db)?);
    value["history"] = history::summaries(db, None)?;
    value["searchIndexPending"] = json!(short_search::pending(db)?);
    if !history {
        let (count, upper): (i64, i64) = db.query_row(
            "SELECT count(*),COALESCE(MAX(sequence),0) FROM items",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        value["bootstrap"] = json!({"count":count,"upper":upper});
    }
    Ok(value)
}

pub(super) fn bootstrap_entries(db: &Connection, request: &Value) -> Result<Value> {
    let after = request["after"]["sequence"].as_i64().unwrap_or(-1);
    let after_id = request["after"]["id"].as_str().unwrap_or("");
    let upper = request["upper"]
        .as_i64()
        .filter(|v| *v >= 0)
        .ok_or("Invalid history boundary")?;
    let limit = request["limit"].as_i64().unwrap_or(1000).clamp(1, 1000);
    let mut statement = db.prepare("SELECT sequence,id,body FROM items WHERE sequence<=?1 AND (sequence>?2 OR (sequence=?2 AND id>?3)) ORDER BY sequence,id LIMIT ?4")?;
    let rows = statement
        .query_map(params![upper, after, after_id, limit + 1], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let more = rows.len() > limit as usize;
    let rows = &rows[..rows.len().min(limit as usize)];
    let mut copies: HashMap<String, Vec<String>> = HashMap::new();
    if !rows.is_empty() {
        let selected =
            serde_json::to_string(&rows.iter().map(|(_, id, _)| id).collect::<Vec<_>>())?;
        let mut statement = db.prepare(
            "SELECT item_id,endpoint FROM copies WHERE item_id IN (SELECT value FROM json_each(?))",
        )?;
        for row in statement.query_map([selected], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            let (id, endpoint) = row?;
            copies.entry(id).or_default().push(endpoint);
        }
    }
    let mut entries = Vec::with_capacity(rows.len());
    for (sequence, id, body) in rows {
        entries.push(json!({"sequence":sequence,"item":serde_json::from_str::<Value>(body)?,"copies":copies.get(id)}));
    }
    let cursor = rows
        .last()
        .map(|(sequence, id, _)| json!({"sequence":sequence,"id":id}));
    Ok(json!({"entries":entries,"cursor":cursor,"more":more}))
}

pub(super) fn change_cursor(db: &Connection) -> Result<i64> {
    // Seeded once from the old snapshot revision, so persisted watch cursors
    // never go backwards on upgrade. Attachment publication also advances it
    // without appending an event; copy receipts only advance the UI revision.
    Ok(db.query_row("SELECT value FROM content_revision", [], |r| r.get(0))?)
}

pub(super) fn page(db: &Connection, after: i64) -> Result<Value> {
    changes_page(db, after, true, true)
}

pub(super) fn requested_page(db: &Connection, after: i64, capabilities: &Value) -> Result<Value> {
    let supports = |name: &str| {
        capabilities
            .as_str()
            .is_some_and(|text| text.split(',').any(|value| value.trim() == name))
            || capabilities
                .as_array()
                .is_some_and(|values| values.iter().any(|value| value == name))
    };
    changes_page(
        db,
        after,
        supports("favorites"),
        supports("favoriteSnapshots"),
    )
}

fn changes_page(db: &Connection, after: i64, favorites: bool, snapshots: bool) -> Result<Value> {
    if after < 0 {
        return Err("Invalid cursor".into());
    }
    // Older clients reject unknown event kinds and require cursor to match the
    // last visible record, so optional events must be filtered before paging.
    let mut stmt = db.prepare("SELECT sequence,body FROM events WHERE sequence>?1 AND (?2 OR json_extract(body,'$.type')!='favorite') AND (?3 OR json_extract(body,'$.type')!='favorite_snapshot') ORDER BY sequence LIMIT 51")?;
    let rows = stmt
        .query_map(params![after, favorites, snapshots], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut items = Vec::new();
    let mut bytes = 0;
    let mut cursor = after;
    for (sequence, body) in &rows {
        if items.len() >= 50 || (bytes + body.len() > 4 * 1024 * 1024 && !items.is_empty()) {
            break;
        }
        bytes += body.len();
        cursor = *sequence;
        items.push(json!({"sequence":sequence,"event":serde_json::from_str::<Value>(body)?}));
    }
    Ok(
        json!({"items":items,"cursor":cursor,"more":rows.last().is_some_and(|r|r.0>cursor),"protocol":3,"capabilities":["favorites","favoriteSnapshots"]}),
    )
}

pub(super) fn initialize(root: &Path) -> Result<Value> {
    initialize_history(root, true)
}

pub(super) fn initialize_history(root: &Path, history: bool) -> Result<Value> {
    let shared = database(root)?;
    let mut db = shared.lock().map_err(|_| "Database unavailable")?;
    let migrated: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='imported')",
        [],
        |r| r.get(0),
    )?;
    if !migrated {
        let legacy = if layout::system(root).join("state.json").exists()
            || layout::system(root).join("state.backup.json").exists()
        {
            layout::system(root)
        } else {
            root.to_path_buf()
        };
        let primary = legacy.join("state.json");
        let backup = legacy.join("state.backup.json");
        let state = if primary.exists() || backup.exists() {
            [primary, backup]
                .into_iter()
                .filter_map(|p| fs::read(p).ok())
                .find_map(|b| serde_json::from_slice::<Value>(&b).ok())
                .ok_or("Previous message history cannot be read; original files were preserved")?
        } else {
            json!({})
        };
        for entry in state["entries"].as_array().into_iter().flatten() {
            apply(root, &mut db, &item_event(&entry["item"]), None)?;
        }
        let mut settings = state;
        if let Some(object) = settings.as_object_mut() {
            object.remove("entries");
            object.remove("cursors");
        }
        db.execute(
            "INSERT OR IGNORE INTO meta VALUES('settings',?)",
            [serde_json::to_string(&settings)?],
        )?;
        db.execute("INSERT INTO meta VALUES('imported','true')", [])?;
    }
    drop(db);
    attachments::organize(root, &shared)?;
    let db = shared.lock().map_err(|_| "Database unavailable")?;
    snapshot_content(&db, history)
}
