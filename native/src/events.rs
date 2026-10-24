use super::*;

pub(super) fn validate_item(v: &Value) -> Result<()> {
    id(v, "id")?;
    id(v, "originId")?;
    if v.get("conversationId").is_some() {
        id(v, "conversationId")?;
    }
    if let Some(quote) = v.get("quote") {
        id(quote, "id")?;
        if string(quote, "name")?.encode_utf16().count() > 60
            || string(quote, "text")?.encode_utf16().count() > 2000 {
            return Err("Invalid quote length".into());
        }
    }
    let name = string(v, "originName")?;
    if name.is_empty()
        || name.encode_utf16().count() > 60
        || string(v, "text")?.encode_utf16().count() > 20000
        || string(v, "name")?.encode_utf16().count() > 512
    {
        return Err("Invalid message length".into());
    }
    chrono::DateTime::parse_from_rfc3339(string(v, "createdAt")?)?;
    let size = v["size"].as_u64().ok_or("Invalid size")?;
    if size > MAX_FILE {
        return Err("File too large".into());
    }
    match string(v, "kind")? {
        "text"
            if size == 0
                && string(v, "sha256")?.is_empty()
                && !string(v, "text")?.trim().is_empty() => {}
        "image" | "video" | "file"
            if valid_digest(string(v, "sha256")?) && !string(v, "name")?.is_empty() => {}
        _ => return Err("Invalid message".into()),
    }
    Ok(())
}

pub(super) fn normalize_item(value: &Value) -> Result<Value> {
    validate_item(value)?;
    let mut item = serde_json::Map::new();
    for key in [
        "id",
        "originId",
        "originName",
        "createdAt",
        "kind",
        "text",
        "name",
        "size",
        "sha256",
    ] {
        item.insert(key.to_owned(), value[key].clone());
    }
    if let Some(conversation) = value.get("conversationId") {
        item.insert("conversationId".into(), conversation.clone());
    }
    if let Some(quote) = value.get("quote") {
        item.insert("quote".into(), json!({"id": quote["id"], "name": quote["name"], "text": quote["text"]}));
    }
    Ok(Value::Object(item))
}

pub(super) fn deleted(db: &Connection, item_id: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM deleted WHERE id=?)",
        [item_id],
        |r| r.get(0),
    )?)
}

pub(super) fn apply(
    root: &Path,
    db: &mut Connection,
    event: &Value,
    source: Option<&str>,
) -> Result<bool> {
    let tx = db.transaction()?;
    let changed = apply_transaction(root, &tx, event, source)?;
    tx.commit()?;
    Ok(changed)
}

fn apply_transaction(
    root: &Path,
    tx: &Connection,
    event: &Value,
    source: Option<&str>,
) -> Result<bool> {
    let event_id = id(event, "id")?;
    let kind = string(event, "type")?;
    if !matches!(
        kind,
        "item" | "delete" | "profile" | "conversation" | "favorite" | "favorite_snapshot"
    ) {
        return Err("Unknown change type".into());
    }
    let body = serde_json::to_string(event)?;
    let existing: Option<String> = tx
        .query_row("SELECT body FROM events WHERE id=?", [&event_id], |r| {
            r.get(0)
        })
        .optional()?;
    if existing.as_ref().is_some_and(|old| old != &body) {
        return Err(errors::api(
            409,
            "Change ID conflicts with existing content",
        ));
    }
    if existing.is_some() {
        let mut changed = false;
        if let Some(source) = source {
            tx.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![event_id, source],
            )?;
            if kind == "item" {
                changed = tx.execute(
                    "INSERT OR IGNORE INTO copies VALUES(?,?)",
                    params![string(&event["item"], "id")?, source],
                )? > 0;
            }
        }
        return Ok(changed);
    }
    match kind {
        "item" => {
            let normalized = normalize_item(&event["item"])?;
            let item = &normalized;
            let item_id = string(item, "id")?;
            let encoded = serde_json::to_string(item)?;
            let old: Option<String> = tx
                .query_row("SELECT body FROM items WHERE id=?", [item_id], |r| r.get(0))
                .optional()?;
            if old.as_ref().is_some_and(|v| v != &encoded) {
                return Err(errors::api(
                    409,
                    "Message ID conflicts with existing content",
                ));
            }
            if !deleted(&tx, item_id)? && string(item, "kind")? != "text" {
                let path = attachments::path(root, string(item, "sha256")?);
                if fs::metadata(path).map(|m| m.len()).ok() != item["size"].as_u64() {
                    return Err(errors::api(409, "File is not complete"));
                }
            }
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event_id, body],
            )?;
            let sequence = tx.last_insert_rowid();
            // A tombstone always wins, even if an offline device replays an old item.
            if !deleted(&tx, item_id)? {
                storage::insert_item(&tx, item_id, sequence, &encoded)?;
            }
            if let Some(source) = source {
                tx.execute(
                    "INSERT OR IGNORE INTO copies VALUES(?,?)",
                    params![item_id, source],
                )?;
            }
            favorites::hydrate_source(tx, item_id)?;
        }
        "delete" => {
            let target = id(event, "target")?;
            favorites::hydrate_source(tx, &target)?;
            tx.execute(
                "INSERT OR IGNORE INTO trash SELECT id,body,? FROM items WHERE id=?",
                params![Utc::now().to_rfc3339(), target],
            )?;
            tx.execute(
                "DELETE FROM transfer_jobs WHERE json_extract(body,'$.item.id')=?",
                [&target],
            )?;
            tx.execute("INSERT OR IGNORE INTO deleted VALUES(?)", [&target])?;
            tx.execute("DELETE FROM items WHERE id=?", [&target])?;
            tx.execute("DELETE FROM copies WHERE item_id=?", [&target])?;
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event_id, body],
            )?;
        }
        "conversation" => {
            let conversation = &event["conversation"];
            let owner = id(conversation, "id")?;
            let name = string(conversation, "name")?;
            let revision = conversation["revision"]
                .as_i64()
                .filter(|v| *v > 0)
                .ok_or("Invalid conversation revision")?;
            if name.trim().is_empty() || name.encode_utf16().count() > 40 {
                return Err("Invalid conversation name".into());
            }
            tx.execute("INSERT INTO conversations VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,event_id=excluded.event_id,body=excluded.body WHERE excluded.revision>conversations.revision OR (excluded.revision=conversations.revision AND excluded.event_id>conversations.event_id)",
                params![owner,revision,event_id,serde_json::to_string(conversation)?])?;
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event_id, body],
            )?;
        }
        "favorite" | "favorite_snapshot" => {
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event_id, body],
            )?;
            favorites::apply_state(tx, event)?;
        }
        "profile" => {
            let profile = &event["profile"];
            let owner = id(profile, "id")?;
            let name = string(profile, "name")?;
            let avatar = string(profile, "avatar")?;
            if name.trim().is_empty()
                || name.encode_utf16().count() > 60
                || avatar.len() > 400000
                || !avatar
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"+/=".contains(&c))
            {
                return Err("Invalid device profile".into());
            }
            let revision = profile["revision"]
                .as_i64()
                .filter(|v| *v > 0)
                .ok_or("Invalid profile revision")?;
            tx.execute("INSERT INTO profiles VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,event_id=excluded.event_id,body=excluded.body WHERE excluded.revision > profiles.revision OR (excluded.revision=profiles.revision AND excluded.event_id>profiles.event_id)", params![owner,revision,event_id,serde_json::to_string(profile)?])?;
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event_id, body],
            )?;
        }
        _ => unreachable!(),
    }
    if let Some(source) = source {
        tx.execute(
            "INSERT OR IGNORE INTO seen VALUES(?,?)",
            params![event_id, source],
        )?;
    }
    Ok(true)
}

pub(super) fn delete_many(root: &Path, db: &mut Connection, ids: &Value) -> Result<()> {
    let values = ids.as_array().ok_or("Invalid message selection")?;
    if values.len() > 100_000 {
        return Err("Too many selected messages".into());
    }
    let mut targets = std::collections::HashSet::new();
    for value in values {
        let target = value
            .as_str()
            .filter(|v| valid_id(v))
            .ok_or("Invalid message ID")?;
        targets.insert(target.to_owned());
    }
    let tx = db.transaction()?;
    let link = favorites::linked(&tx)?;
    for target in targets {
        favorites::hydrate_source(&tx, &target)?;
        if link {
            favorites::remove_original(&tx, &target)?;
        }
        delete_transaction(root, &tx, &target)?;
    }
    tx.commit()?;
    Ok(())
}

pub(super) fn delete_transaction(root: &Path, db: &Connection, target: &str) -> Result<()> {
    let event =
        json!({"id":digest(format!("delete:{target}").as_bytes()),"type":"delete","target":target});
    apply_transaction(root, db, &event, None)?;
    Ok(())
}

pub(super) fn set_favorites(
    root: &Path,
    db: &mut Connection,
    ids: &Value,
    value: bool,
) -> Result<()> {
    favorites::set(root, db, ids, value)
}

pub(super) fn transfer_item(event: &Value) -> Option<&Value> {
    if event["type"] == "item" {
        Some(&event["item"])
    } else if is_favorite(event) && event["favorite"]["item"].is_object() {
        Some(&event["favorite"]["item"])
    } else {
        None
    }
}

pub(super) fn is_favorite(event: &Value) -> bool {
    matches!(
        event["type"].as_str(),
        Some("favorite" | "favorite_snapshot")
    )
}

pub(super) fn item_event(item: &Value) -> Value {
    json!({"id":digest(format!("item:{}",item["id"].as_str().unwrap_or("")).as_bytes()),"type":"item","item":item})
}
