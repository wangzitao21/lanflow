use super::*;

struct CachedSearch {
    root: PathBuf,
    revision: i64,
    key: String,
    offset: i64,
    total: i64,
    ids: Arc<Vec<String>>,
}
static RESULTS: OnceLock<Mutex<std::collections::VecDeque<CachedSearch>>> = OnceLock::new();
const WINDOW_SIZE: i64 = 1000;

pub(super) fn forget(root: &Path) {
    if let Some(results) = RESULTS.get()
        && let Ok(mut results) = results.lock()
    {
        results.retain(|entry| entry.root != root);
    }
}

fn result_page(entry: &CachedSearch, offset: i64, limit: i64) -> Value {
    let begin = usize::try_from(offset.saturating_sub(entry.offset))
        .unwrap_or(usize::MAX)
        .min(entry.ids.len());
    let end = begin.saturating_add(limit as usize).min(entry.ids.len());
    let next = offset.saturating_add((end - begin) as i64);
    json!({"ids":&entry.ids[begin..end],"total":entry.total,"more":next<entry.total,"nextOffset":next})
}

pub(super) fn schema(db: &Connection) -> Result<()> {
    let mut existed: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='message_search' AND type='table')",
        [],
        |r| r.get(0),
    )?;
    let documents: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='message_search_documents' AND type='table')", [], |r| r.get(0))?;
    if existed && !documents {
        // Replace only an earlier derived index; message/event data is untouched.
        db.execute_batch("DROP TRIGGER IF EXISTS search_items_INSERT; DROP TRIGGER IF EXISTS search_items_DELETE;
            DROP TRIGGER IF EXISTS search_items_UPDATE_DELETE; DROP TRIGGER IF EXISTS search_items_UPDATE_INSERT;
            DROP TABLE message_search; DROP VIEW IF EXISTS message_search_content;")?;
        existed = false;
    }
    // A stable integer mapping supports old databases with repeated sequences
    // and survives VACUUM. The external view keeps message bodies in items only.
    db.execute_batch("CREATE TABLE IF NOT EXISTS message_search_documents(document_id INTEGER PRIMARY KEY AUTOINCREMENT,item_id TEXT NOT NULL UNIQUE);
        CREATE VIEW IF NOT EXISTS message_search_content AS
        SELECT d.document_id,COALESCE(json_extract(i.body,'$.text'),'') AS text,COALESCE(json_extract(i.body,'$.name'),'') AS name
        FROM message_search_documents d JOIN items i ON i.id=d.item_id WHERE json_valid(i.body);
        CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(text,name,
            content='message_search_content',content_rowid='document_id',tokenize='trigram',detail=none,columnsize=0);
        CREATE TRIGGER IF NOT EXISTS search_items_INSERT AFTER INSERT ON items WHEN json_valid(NEW.body) BEGIN
            INSERT OR IGNORE INTO message_search_documents(item_id) VALUES(NEW.id);
            INSERT INTO message_search(rowid,text,name) SELECT document_id,COALESCE(json_extract(NEW.body,'$.text'),''),COALESCE(json_extract(NEW.body,'$.name'),'') FROM message_search_documents WHERE item_id=NEW.id;
        END;
        CREATE TRIGGER IF NOT EXISTS search_items_DELETE AFTER DELETE ON items WHEN json_valid(OLD.body) BEGIN
            INSERT INTO message_search(message_search,rowid,text,name) SELECT 'delete',document_id,COALESCE(json_extract(OLD.body,'$.text'),''),COALESCE(json_extract(OLD.body,'$.name'),'') FROM message_search_documents WHERE item_id=OLD.id;
            DELETE FROM message_search_documents WHERE item_id=OLD.id;
        END;
        CREATE TRIGGER IF NOT EXISTS search_items_UPDATE_DELETE BEFORE UPDATE ON items WHEN json_valid(OLD.body) BEGIN
            INSERT INTO message_search(message_search,rowid,text,name) SELECT 'delete',document_id,COALESCE(json_extract(OLD.body,'$.text'),''),COALESCE(json_extract(OLD.body,'$.name'),'') FROM message_search_documents WHERE item_id=OLD.id;
            DELETE FROM message_search_documents WHERE item_id=OLD.id;
        END;
        CREATE TRIGGER IF NOT EXISTS search_items_UPDATE_INSERT AFTER UPDATE ON items WHEN json_valid(NEW.body) BEGIN
            INSERT OR IGNORE INTO message_search_documents(item_id) VALUES(NEW.id);
            INSERT INTO message_search(rowid,text,name) SELECT document_id,COALESCE(json_extract(NEW.body,'$.text'),''),COALESCE(json_extract(NEW.body,'$.name'),'') FROM message_search_documents WHERE item_id=NEW.id;
        END;")?;
    if !existed {
        db.execute("INSERT OR IGNORE INTO message_search_documents(item_id) SELECT id FROM items WHERE json_valid(body)", [])?;
        db.execute(
            "INSERT INTO message_search(message_search) VALUES('rebuild')",
            [],
        )?;
    }
    short_search::schema(db)
}

fn candidate_query(query: &str) -> Option<String> {
    let chars: Vec<char> = query.chars().collect();
    if chars.len() < 3 || query.contains('\0') {
        return None;
    }
    // A compact, position-free trigram index gives a candidate superset. The
    // original literal predicate below decides the final match, including
    // punctuation and column boundaries. Bound work for very long queries.
    let windows = chars.len() - 2;
    let count = windows.min(8);
    let mut terms = Vec::new();
    for sample in 0..count {
        let index = if count == 1 {
            0
        } else {
            sample * (windows - 1) / (count - 1)
        };
        let gram: String = chars[index..index + 3].iter().collect();
        let term = format!("\"{}\"", gram.replace('"', "\"\""));
        if !terms.contains(&term) {
            terms.push(term);
        }
    }
    Some(terms.join(" AND "))
}

pub(super) fn messages(root: &Path, db: &Connection, request: &Value) -> Result<Value> {
    let query = request["query"].as_str().unwrap_or("").trim();
    if query.encode_utf16().count() > 20_000 {
        return Err("Search text is too long".into());
    }
    let mut short = short_search::query(query);
    if short.is_some() && short_search::pending(db)? {
        short = None;
    }
    let compact = short.is_some()
        && !request["favoritesOnly"].as_bool().unwrap_or(false)
        && [
            "conversationId",
            "kind",
            "originId",
            "afterDate",
            "beforeDate",
        ]
        .iter()
        .all(|key| !request[*key].is_string());
    let mut filters = if short.is_some() {
        Vec::new()
    } else {
        vec!["json_valid(i.body)".to_owned()]
    };
    let mut values: Vec<rusqlite::types::Value> = Vec::new();
    let candidates = short.clone().or_else(|| candidate_query(query));
    let search_table = if short.is_some() {
        "message_short_search"
    } else {
        "message_search"
    };
    if let Some(candidates) = &candidates {
        filters.push(format!("{search_table} MATCH ?"));
        values.push(candidates.clone().into());
    }
    if !query.is_empty() && short.is_none() {
        filters.push("(instr(lower(json_extract(i.body,'$.text')),lower(?))>0 OR instr(lower(json_extract(i.body,'$.name')),lower(?))>0)".to_owned());
        values.extend([query.to_owned().into(), query.to_owned().into()]);
    }
    if let Some(conversation) = request["conversationId"].as_str() {
        if !valid_id(conversation) {
            return Err("Invalid conversation ID".into());
        }
        filters.push(
            "COALESCE(json_extract(i.body,'$.conversationId'),'lanflow-self-chat')=?".to_owned(),
        );
        values.push(conversation.to_owned().into());
    }
    if let Some(kind) = request["kind"].as_str() {
        if !matches!(kind, "text" | "image" | "video" | "file") {
            return Err("Invalid message kind".into());
        }
        filters.push("json_extract(i.body,'$.kind')=?".to_owned());
        values.push(kind.to_owned().into());
    }
    if let Some(origin) = request["originId"].as_str() {
        if !valid_id(origin) {
            return Err("Invalid origin ID".into());
        }
        filters.push("json_extract(i.body,'$.originId')=?".to_owned());
        values.push(origin.to_owned().into());
    }
    for (field, operator) in [("afterDate", ">="), ("beforeDate", "<")] {
        if let Some(date) = request[field].as_str() {
            chrono::DateTime::parse_from_rfc3339(date)?;
            filters.push(format!(
                "julianday(json_extract(i.body,'$.createdAt')){operator}julianday(?)"
            ));
            values.push(date.to_owned().into());
        }
    }
    if request["favoritesOnly"].as_bool().unwrap_or(false) {
        filters.push(
            "i.id IN (SELECT id FROM favorites WHERE json_extract(body,'$.value')=1)".to_owned(),
        );
    }
    let filter = filters.join(" AND ");
    let hint = if request["conversationId"].is_string() {
        "INDEXED BY items_conversation_date"
    } else if request["kind"].is_string() {
        "INDEXED BY items_kind_date"
    } else if request["favoritesOnly"].as_bool().unwrap_or(false) {
        // Let SQLite resolve the small favorite-ID set through the primary key.
        ""
    } else if query.is_empty()
        || request["afterDate"].is_string()
        || request["beforeDate"].is_string()
    {
        "INDEXED BY items_date"
    } else {
        // A date-ordered full scan performs random table lookups for a literal
        // search. Sequential reads plus sorting the matches are cheaper.
        "NOT INDEXED"
    };
    let source = if candidates.is_some() {
        // Keep candidate lookup ahead of metadata filters even without ANALYZE.
        format!(
            "{search_table} CROSS JOIN message_search_documents d ON d.document_id={search_table}.rowid{}",
            if compact {
                ""
            } else {
                " CROSS JOIN items i ON i.id=d.item_id"
            }
        )
    } else {
        format!("items i {hint}")
    };
    let offset = request["offset"].as_i64().unwrap_or(0).max(0);
    let limit = request["limit"].as_i64().unwrap_or(50).clamp(1, 200);
    let mut cache_key = None;
    if !query.is_empty() {
        let revision: i64 = db.query_row("SELECT value FROM revision", [], |r| r.get(0))?;
        // The SQL and bound filter values capture every search filter, while
        // offset/limit deliberately share a result set across consecutive pages.
        let key = format!("{source}:{filter}:{values:?}");
        let mut cache = RESULTS
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "Search cache unavailable")?;
        if let Some(index) = cache.iter().position(|entry| {
            entry.root == root
                && entry.revision == revision
                && entry.key == key
                && offset >= entry.offset
                && (offset.saturating_add(limit)
                    <= entry.offset.saturating_add(entry.ids.len() as i64)
                    || entry.offset.saturating_add(entry.ids.len() as i64) >= entry.total)
        }) {
            let entry = cache.remove(index).unwrap();
            let response = result_page(&entry, offset, limit);
            cache.push_back(entry);
            return Ok(response);
        }
        cache_key = Some((revision, key));
    }
    let filter_parameters = values.len();
    let selected_id = if compact { "d.item_id" } else { "i.id" };
    let selected_date = if compact {
        "d.created"
    } else {
        "julianday(json_extract(i.body,'$.createdAt'))"
    };
    let mut total = if query.is_empty() {
        Some(db.query_row(
            &format!("SELECT COUNT(*) FROM {source} WHERE {filter}"),
            rusqlite::params_from_iter(values.iter()),
            |r| r.get::<_, i64>(0),
        )?)
    } else {
        None
    };
    // Preserve the original count/top-N plan. Prefetch a small window, never
    // every match: broad first pages stay bounded and nearby pages share work.
    values.extend([
        if cache_key.is_some() {
            WINDOW_SIZE.into()
        } else {
            limit.into()
        },
        offset.into(),
    ]);
    let sql = if query.is_empty() {
        format!(
            "SELECT i.id,0 FROM {source} WHERE {filter} ORDER BY julianday(json_extract(i.body,'$.createdAt')) DESC,i.id DESC LIMIT ? OFFSET ?"
        )
    } else {
        // Evaluate the literal predicate once, then count and sort only compact
        // IDs/timestamps. Do not keep message bodies in the window's temp rows.
        format!("WITH matches AS MATERIALIZED (SELECT {selected_id} AS id,{selected_date} AS created FROM {source} WHERE {filter})
            SELECT id,COUNT(*) OVER() FROM matches ORDER BY created DESC,id DESC LIMIT ? OFFSET ?")
    };
    let mut statement = db.prepare(&sql)?;
    let mut ids = Vec::new();
    for row in statement.query_map(rusqlite::params_from_iter(values.iter()), |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
    })? {
        let (id, count) = row?;
        if total.is_none() {
            total = Some(count);
        }
        ids.push(id);
    }
    let total = match total {
        Some(count) => count,
        None if offset == 0 => 0,
        None => db.query_row(
            &format!("SELECT COUNT(*) FROM {source} WHERE {filter}"),
            rusqlite::params_from_iter(values[..filter_parameters].iter()),
            |r| r.get::<_, i64>(0),
        )?,
    };
    if let Some((revision, key)) = cache_key {
        let entry = CachedSearch {
            root: root.to_owned(),
            revision,
            key,
            offset,
            total,
            ids: Arc::new(ids),
        };
        let response = result_page(&entry, offset, limit);
        let mut cache = RESULTS
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "Search cache unavailable")?;
        cache.retain(|entry| entry.root != root || entry.revision == revision);
        while cache.len() >= 8 {
            cache.pop_front();
        }
        cache.push_back(entry);
        return Ok(response);
    }
    let next = offset.saturating_add(ids.len() as i64);
    Ok(json!({"ids":ids,"total":total,"more":next<total,"nextOffset":next}))
}

#[cfg(test)]
#[path = "search_tests.rs"]
mod tests;
