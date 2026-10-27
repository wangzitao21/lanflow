use super::*;

pub(super) fn snapshot_id(original: &str) -> String {
    digest(format!("favorite:{original}").as_bytes())
}

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS favorite_trash(id TEXT PRIMARY KEY,original_id TEXT NOT NULL,body TEXT NOT NULL,favorite_body TEXT NOT NULL,deleted_at TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS favorite_trash_date ON favorite_trash(deleted_at DESC,id DESC);
        CREATE INDEX IF NOT EXISTS favorite_trash_original ON favorite_trash(original_id);
        CREATE INDEX IF NOT EXISTS favorite_snapshot_id ON favorites(json_extract(body,'$.snapshotId'));
        CREATE INDEX IF NOT EXISTS favorite_item_digest ON favorites(json_extract(body,'$.item.sha256'));
        CREATE INDEX IF NOT EXISTS events_item_id ON events(json_extract(body,'$.item.id')) WHERE json_extract(body,'$.type')='item';")?;
    let legacy = db.prepare("SELECT event_id,body FROM favorites WHERE json_extract(body,'$.value')=1 AND json_type(body,'$.item') IS NULL")?
        .query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
        .collect::<std::result::Result<Vec<_>,_>>()?;
    for (event_id, body) in legacy {
        let favorite: Value = serde_json::from_str(&body)?;
        apply_state(
            db,
            &json!({"id":event_id,"type":"favorite","favorite":favorite}),
        )?;
    }
    let shared: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='shared_favorites')",
        [],
        |r| r.get(0),
    )?;
    if !shared {
        db.execute("INSERT OR IGNORE INTO trash SELECT original_id,json_set(body,'$.id',original_id),deleted_at FROM favorite_trash WHERE original_id IN (SELECT id FROM deleted)",[])?;
        db.execute("DELETE FROM favorite_trash WHERE original_id IN (SELECT id FROM deleted) OR original_id IN (SELECT id FROM items)",[])?;
        db.execute("UPDATE favorites SET body=json_set(body,'$.sourceValue',json_extract(body,'$.value'),'$.value',json('false'),'$.sourceDeleted',json('true')) WHERE id IN (SELECT id FROM deleted)",[])?;
        db.execute("INSERT INTO meta VALUES('shared_favorites','true')", [])?;
    }
    Ok(())
}

fn source_item(db: &Connection, original: &str) -> Result<Option<Value>> {
    for sql in [
        "SELECT body FROM items WHERE id=?",
        "SELECT body FROM trash WHERE id=?",
        "SELECT json_extract(body,'$.item') FROM events WHERE json_extract(body,'$.type')='item' AND json_extract(body,'$.item.id')=? ORDER BY sequence DESC LIMIT 1",
    ] {
        let body: Option<String> = db.query_row(sql, [original], |r| r.get(0)).optional()?;
        if let Some(body) = body {
            return Ok(Some(serde_json::from_str(&body)?));
        }
    }
    Ok(None)
}

fn state(db: &Connection, original: &str) -> Result<Option<(String, Value)>> {
    let row: Option<(String, String)> = db
        .query_row(
            "SELECT event_id,body FROM favorites WHERE id=?",
            [original],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    row.map(|(event, body)| Ok((event, serde_json::from_str(&body)?)))
        .transpose()
}

fn time_for(revision: i64) -> String {
    chrono::DateTime::<Utc>::from_timestamp_micros(revision)
        .unwrap_or(chrono::DateTime::<Utc>::UNIX_EPOCH)
        .to_rfc3339_opts(chrono::SecondsFormat::Micros, true)
}

fn canonical<'a>(event: &'a str, favorite: &'a Value) -> &'a str {
    favorite["stateEventId"].as_str().unwrap_or(event)
}

fn insert_event(db: &Connection, event: &Value) -> Result<()> {
    let encoded = serde_json::to_string(event)?;
    let event_id = id(event, "id")?;
    let previous: Option<String> = db
        .query_row("SELECT body FROM events WHERE id=?", [&event_id], |r| {
            r.get(0)
        })
        .optional()?;
    if previous
        .as_ref()
        .is_some_and(|previous| previous != &encoded)
    {
        return Err(errors::api(
            409,
            "Favorite change conflicts with existing content",
        ));
    }
    db.execute(
        "INSERT OR IGNORE INTO events(id,body) VALUES(?,?)",
        params![event_id, encoded],
    )?;
    Ok(())
}

// User operations retain the deployed 'favorite' type. Legacy enrichment uses
// a separately negotiated type: old peers must keep comparing original IDs,
// while new peers compare stateEventId instead of the enrichment transport ID.
pub(super) fn apply_state(db: &Connection, event: &Value) -> Result<()> {
    let input = &event["favorite"];
    let original = id(input, "id")?;
    let value = input["value"].as_bool().ok_or("Invalid favorite state")?;
    let revision = input["revision"]
        .as_i64()
        .filter(|r| *r > 0)
        .ok_or("Invalid favorite revision")?;
    let event_id = id(event, "id")?;
    let state_id = canonical(&event_id, input);
    if !valid_id(state_id) {
        return Err("Invalid favorite state identity".into());
    }
    let previous = state(db, &original)?;
    let previous_item = previous
        .as_ref()
        .and_then(|(_, body)| body["item"].as_object().map(|_| body["item"].clone()));
    let supplied = input["item"].is_object();
    let item = if supplied {
        Some(input["item"].clone())
    } else if previous_item.is_some() {
        previous_item
    } else if value {
        source_item(db, &original)?
    } else {
        None
    };
    let snapshot = snapshot_id(&original);
    let mut body = json!({"id":original,"value":value,"revision":revision,"stateEventId":state_id,"snapshotId":snapshot});
    if let Some(mut item) = item {
        if supplied && (input["snapshotId"] != snapshot || item["id"] != snapshot) {
            return Err("Invalid favorite snapshot identity".into());
        }
        item["id"] = json!(snapshot);
        body["item"] = events::normalize_item(&item)?;
        // Legacy enrichment has a deterministic event ID. Its contents must
        // depend only on that operation, never on a peer's previously seen state.
        let saved = input["savedAt"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| time_for(revision));
        chrono::DateTime::parse_from_rfc3339(&saved)?;
        body["savedAt"] = json!(saved);
    }
    let transport_id = if !supplied && body["item"].is_object() {
        let enriched = json!({"id":digest(format!("favorite-snapshot:{state_id}").as_bytes()),"type":"favorite_snapshot","favorite":body});
        insert_event(db, &enriched)?;
        id(&enriched, "id")?
    } else {
        event_id.clone()
    };
    let wins = if let Some((old_id, old)) = &previous {
        let old_revision = old["revision"].as_i64().unwrap_or(0);
        let old_state = canonical(old_id, old);
        let old_value = old.get("sourceValue").unwrap_or(&old["value"]);
        let old_value = old_value
            .as_bool()
            .or_else(|| old_value.as_i64().map(|value| value != 0));
        if revision == old_revision && state_id == old_state && old_value != Some(value) {
            return Err(errors::api(409, "Favorite state identity conflicts"));
        }
        revision > old_revision
            || (revision == old_revision && state_id > old_state)
            || (revision == old_revision
                && state_id == old_state
                && body["item"].is_object()
                && !old["item"].is_object())
    } else {
        true
    };
    if !wins {
        return Ok(());
    }
    if deleted(db, &original)? {
        body["sourceValue"] = json!(value);
        body["sourceDeleted"] = json!(true);
        body["value"] = json!(false);
    }
    db.execute("INSERT INTO favorites(id,revision,event_id,body) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,event_id=excluded.event_id,body=excluded.body",
        params![original,revision,transport_id,body.to_string()])?;
    if value {
        db.execute("DELETE FROM favorite_trash WHERE id=?", [&snapshot])?;
    } else {
        // Removing a bookmark does not create another copy in the recycle bin.
        db.execute("DELETE FROM favorite_trash WHERE id=?", [&snapshot])?;
    }
    Ok(())
}

pub(super) fn hydrate_source(db: &Connection, original: &str) -> Result<()> {
    if let Some((event, body)) = state(db, original)?
        && body["value"] == true
        && !body["item"].is_object()
    {
        apply_state(db, &json!({"id":event,"type":"favorite","favorite":body}))?;
    }
    Ok(())
}

pub(super) fn for_client(db: &Connection, mut body: Value) -> Result<Value> {
    let original = string(&body, "id")?.to_owned();
    if deleted(db, &original)? {
        body["value"] = json!(false);
    }
    let current: Option<String> = db
        .query_row("SELECT body FROM items WHERE id=?", [&original], |r| {
            r.get(0)
        })
        .optional()?;
    if let Some(current) = current {
        let mut item: Value = serde_json::from_str(&current)?;
        item["id"] = json!(snapshot_id(&original));
        body["item"] = events::normalize_item(&item)?;
    }
    body["sourceExists"] = json!(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM items WHERE id=?)",
        [body["id"].as_str().unwrap_or("")],
        |r| r.get::<_, bool>(0)
    )?);
    if body["item"].is_object() && body["item"]["kind"] != "text" {
        body["blobPath"] = json!(attachments::item_path(db, &body["item"])?);
    }
    Ok(body)
}

pub(super) fn linked(_: &Connection) -> Result<bool> {
    Ok(true)
}

pub(super) fn source_changed(db: &Connection, original: &str) -> Result<()> {
    if deleted(db, original)? {
        db.execute("UPDATE favorites SET body=json_set(body,'$.sourceValue',COALESCE(json_extract(body,'$.sourceValue'),json_extract(body,'$.value')),'$.value',json('false'),'$.sourceDeleted',json('true')) WHERE id=?",[original])?;
        db.execute("INSERT OR IGNORE INTO trash SELECT original_id,json_set(body,'$.id',original_id),deleted_at FROM favorite_trash WHERE original_id=?",[original])?;
        db.execute("DELETE FROM favorite_trash WHERE original_id=?", [original])?;
        db.execute(
            "DELETE FROM transfer_jobs WHERE json_extract(body,'$.favorite.id')=?",
            [original],
        )?;
    } else {
        db.execute("UPDATE favorites SET body=body WHERE id=?", [original])?;
    }
    Ok(())
}

pub(super) fn archive_source(db: &Connection, original: &str) -> Result<()> {
    let saved: Option<String> = db.query_row("SELECT json_extract(body,'$.item') FROM favorites WHERE id=? AND json_type(body,'$.item')='object'",[original],|r| r.get(0)).optional()?;
    if let Some(saved) = saved {
        let mut item: Value = serde_json::from_str(&saved)?;
        item["id"] = json!(original);
        item = message_edits::edited_item(db, &item)?;
        db.execute(
            "INSERT OR IGNORE INTO trash VALUES(?,?,?)",
            params![original, item.to_string(), Utc::now().to_rfc3339()],
        )?;
    }
    Ok(())
}

fn selected(ids: &Value) -> Result<std::collections::BTreeSet<String>> {
    let values = ids
        .as_array()
        .filter(|v| v.len() <= 100_000)
        .ok_or("Invalid favorite selection")?;
    values
        .iter()
        .map(|v| {
            v.as_str()
                .filter(|id| valid_id(id))
                .map(str::to_owned)
                .ok_or_else(|| "Invalid favorite ID".into())
        })
        .collect()
}

fn emit(
    db: &Connection,
    original: &str,
    value: bool,
    snapshot: Option<Value>,
    saved: Option<String>,
) -> Result<()> {
    let previous = state(db, original)?;
    let revision = Utc::now().timestamp_micros().max(
        previous
            .as_ref()
            .map_or(0, |(_, v)| v["revision"].as_i64().unwrap_or(0))
            + 1,
    );
    let event_id = uuid::Uuid::new_v4().simple().to_string();
    let mut favorite = json!({"id":original,"value":value,"revision":revision,"stateEventId":event_id,"snapshotId":snapshot_id(original)});
    if let Some(mut item) = snapshot {
        item["id"] = favorite["snapshotId"].clone();
        favorite["item"] = events::normalize_item(&item)?;
        favorite["savedAt"] = json!(saved.unwrap_or_else(|| time_for(revision)));
    }
    let event = json!({"id":event_id,"type":"favorite","favorite":favorite});
    insert_event(db, &event)?;
    apply_state(db, &event)
}

pub(super) fn remove_original(db: &Connection, original: &str) -> Result<()> {
    hydrate_source(db, original)?;
    let Some((_, body)) = state(db, original)? else {
        return Ok(());
    };
    if body["value"] != true {
        return Ok(());
    }
    emit(
        db,
        original,
        false,
        body["item"].is_object().then(|| body["item"].clone()),
        body["savedAt"].as_str().map(str::to_owned),
    )
}

pub(super) fn set(_root: &Path, db: &mut Connection, ids: &Value, value: bool) -> Result<()> {
    let ids = selected(ids)?;
    let tx = db.transaction()?;
    for original in ids {
        if !value {
            if state(&tx, &original)?.is_some_and(|(_, v)| v["value"] == true) {
                remove_original(&tx, &original)?;
            }
            continue;
        }
        if state(&tx, &original)?.is_some_and(|(_, v)| v["value"] == true && v["item"].is_object())
        {
            continue;
        }
        let body: Option<String> = tx
            .query_row("SELECT body FROM items WHERE id=?", [&original], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(body) = body {
            emit(
                &tx,
                &original,
                true,
                Some(serde_json::from_str(&body)?),
                None,
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub(super) fn remove(root: &Path, db: &mut Connection, ids: &Value) -> Result<()> {
    let ids = selected(ids)?;
    let tx = db.transaction()?;
    let link = linked(&tx)?;
    for snapshot in ids {
        let original: Option<String> = tx.query_row("SELECT id FROM favorites WHERE json_extract(body,'$.snapshotId')=? AND json_extract(body,'$.value')=1", [&snapshot], |r|r.get(0)).optional()?;
        if let Some(original) = original {
            remove_original(&tx, &original)?;
            if link {
                events::delete_transaction(root, &tx, &original)?;
                tx.execute(
                    "UPDATE trash SET body=json_set(body,'$._wasFavorite',json('true')) WHERE id=?",
                    [&original],
                )?;
            }
        }
    }
    tx.commit()?;
    Ok(())
}

pub(super) fn restore(root: &Path, db: &mut Connection, ids: &Value) -> Result<()> {
    let ids = selected(ids)?;
    let tx = db.transaction()?;
    for snapshot in ids {
        let mut saved: Option<String> = tx
            .query_row(
                "SELECT favorite_body FROM favorite_trash WHERE id=?",
                [&snapshot],
                |r| r.get(0),
            )
            .optional()?;
        if saved.is_none() {
            saved = tx.query_row("SELECT body FROM favorites WHERE json_extract(body,'$.snapshotId')=? AND id IN (SELECT id FROM trash) AND id IN (SELECT id FROM deleted)",[&snapshot],|r| r.get(0)).optional()?;
        }
        if let Some(saved) = saved {
            let saved: Value = serde_json::from_str(&saved)?;
            let item = &saved["item"];
            if item["kind"] != "text"
                && fs::metadata(attachments::path(root, string(item, "sha256")?))
                    .map(|m| m.len())
                    .ok()
                    != item["size"].as_u64()
            {
                return Err("收藏附件尚未下载完成".into());
            }
            let original = string(&saved, "id")?;
            let removed = deleted(&tx, original)?;
            let restored = if removed {
                digest(format!("restore:{original}").as_bytes())
            } else {
                original.to_owned()
            };
            if deleted(&tx, &restored)? {
                return Err("此内容已恢复过，请在回收站中恢复较新的记录".into());
            }
            let existing: Option<String> = tx
                .query_row("SELECT body FROM items WHERE id=?", [&restored], |r| {
                    r.get(0)
                })
                .optional()?;
            let mut canonical = if let Some(existing) = existing {
                serde_json::from_str::<Value>(&existing)?
            } else {
                let trash: Option<String> = tx
                    .query_row("SELECT body FROM trash WHERE id=?", [original], |r| {
                        r.get(0)
                    })
                    .optional()?;
                let mut canonical = trash
                    .map(|body| serde_json::from_str::<Value>(&body))
                    .transpose()?
                    .unwrap_or_else(|| item.clone());
                canonical["id"] = json!(restored);
                canonical = events::normalize_item(&canonical)?;
                events::apply_transaction(root, &tx, &item_event(&canonical), None)?;
                canonical
            };
            canonical["id"] = json!(restored);
            emit(
                &tx,
                &restored,
                true,
                Some(canonical),
                saved["savedAt"].as_str().map(str::to_owned),
            )?;
            tx.execute("DELETE FROM favorite_trash WHERE id=?", [&snapshot])?;
            if removed {
                tx.execute("DELETE FROM trash WHERE id=?", [original])?;
            }
        }
    }
    tx.commit()?;
    Ok(())
}

pub(super) fn restore_mark(db: &Connection, item: &Value, previous: &str) -> Result<()> {
    let saved =
        state(db, previous)?.and_then(|(_, body)| body["savedAt"].as_str().map(str::to_owned));
    emit(db, string(item, "id")?, true, Some(item.clone()), saved)
}

pub(super) fn retained(db: &Connection, event: &Value) -> Result<bool> {
    let favorite = &event["favorite"];
    if !favorite["item"].is_object() {
        return Ok(false);
    }
    if deleted(db, string(favorite, "id")?)? {
        return Ok(false);
    }
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM favorites WHERE id=?1 AND json_extract(body,'$.value')=1) OR EXISTS(SELECT 1 FROM favorite_trash WHERE original_id=?1)", [string(favorite,"id")?], |r|r.get(0))?)
}

pub(super) fn touch(db: &Connection, event: &Value) -> Result<()> {
    db.execute(
        "UPDATE favorites SET body=body WHERE id=?",
        [string(&event["favorite"], "id")?],
    )?;
    Ok(())
}
