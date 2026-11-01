use super::*;

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS conversation_recovery(id TEXT PRIMARY KEY,sequence INTEGER NOT NULL,body TEXT NOT NULL,received_at TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS recovery_order ON conversation_recovery(received_at DESC,id DESC);
        CREATE INDEX IF NOT EXISTS recovery_conversation ON conversation_recovery(json_extract(body,'$.conversationId'));")?;
    for action in ["INSERT", "UPDATE", "DELETE"] {
        db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS recovery_revision_{action} AFTER {action} ON conversation_recovery BEGIN UPDATE revision SET value=value+1; END;"))?;
    }
    // Upgrade already-deleted conversations without throwing away their late messages.
    db.execute("INSERT OR IGNORE INTO conversation_recovery SELECT i.id,i.sequence,i.body,? FROM items i JOIN conversations c ON c.id=json_extract(i.body,'$.conversationId') WHERE c.id!='lanflow-self-chat' AND json_extract(c.body,'$.deleted')=1", [Utc::now().to_rfc3339()])?;
    db.execute(
        "DELETE FROM items WHERE id IN (SELECT id FROM conversation_recovery)",
        [],
    )?;
    Ok(())
}

pub(super) fn closed(db: &Connection, owner: &str) -> Result<bool> {
    // The built-in self chat is a permanent destination; its menu clears history.
    Ok(owner != "lanflow-self-chat" && db.query_row(
        "SELECT EXISTS(SELECT 1 FROM conversations WHERE id=? AND json_extract(body,'$.deleted')=1)",
        [owner], |r| r.get(0),
    )?)
}

pub(super) fn quarantine(db: &Connection, owner: &str) -> Result<()> {
    if !closed(db, owner)? {
        return Ok(());
    }
    db.execute("INSERT OR IGNORE INTO conversation_recovery SELECT id,sequence,body,?1 FROM items WHERE json_extract(body,'$.conversationId')=?2", params![Utc::now().to_rfc3339(),owner])?;
    db.execute(
        "DELETE FROM items WHERE json_extract(body,'$.conversationId')=?",
        [owner],
    )?;
    db.execute("UPDATE favorites SET body=body WHERE id IN (SELECT id FROM conversation_recovery WHERE json_extract(body,'$.conversationId')=?)",[owner])?;
    Ok(())
}

pub(super) fn insert(db: &Connection, id: &str, sequence: i64, body: &str) -> Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO conversation_recovery VALUES(?,?,?,?)",
        params![id, sequence, body, Utc::now().to_rfc3339()],
    )?;
    db.execute("UPDATE favorites SET body=body WHERE id=?", [id])?;
    Ok(())
}

pub(super) fn count(db: &Connection) -> Result<i64> {
    Ok(
        db.query_row("SELECT COUNT(*) FROM conversation_recovery", [], |r| {
            r.get(0)
        })?,
    )
}

pub(super) fn page(root: &Path, db: &Connection, request: &Value) -> Result<Value> {
    let limit = request["limit"].as_i64().unwrap_or(50).clamp(1, 100);
    let at = request["after"]["at"].as_str().unwrap_or("");
    let after_id = request["after"]["id"].as_str().unwrap_or("");
    let rows = db.prepare("SELECT r.id,r.body,r.received_at,c.body FROM conversation_recovery r LEFT JOIN conversations c ON c.id=json_extract(r.body,'$.conversationId') WHERE ?1='' OR r.received_at<?1 OR (r.received_at=?1 AND r.id<?2) ORDER BY r.received_at DESC,r.id DESC LIMIT ?3")?
        .query_map(params![at,after_id,limit+1], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,Option<String>>(3)?)))?
        .collect::<std::result::Result<Vec<_>,_>>()?;
    let more = rows.len() > limit as usize;
    let mut items = Vec::new();
    let mut cursor = Value::Null;
    for (id, body, at, conversation) in rows.into_iter().take(limit as usize) {
        let item: Value = serde_json::from_str(&body)?;
        let conversation: Value = serde_json::from_str(conversation.as_deref().unwrap_or("{}"))?;
        let available = item["kind"] == "text"
            || attachments::item_path(db, &item)?.is_some_and(|path| {
                fs::metadata(root.join(path))
                    .is_ok_and(|m| m.is_file() && Some(m.len()) == item["size"].as_u64())
            });
        cursor = json!({"at":at,"id":id});
        items.push(json!({"id":id,"item":item,"blobPath":attachments::item_path(db,&item)?,"conversationName":conversation["name"],"receivedAt":at,"available":available,"versions":variants(db,&item)?.len()}));
    }
    Ok(json!({"items":items,"total":count(db)?,"more":more,"cursor":cursor}))
}

fn variants(db: &Connection, item: &Value) -> Result<Vec<(String, Value)>> {
    let heads = db.prepare("SELECT v.event_id,v.body FROM message_edit_heads h JOIN message_edit_versions v ON v.event_id=h.event_id WHERE h.item_id=? ORDER BY v.event_id")?
        .query_map([string(item,"id")?], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
        .collect::<std::result::Result<Vec<_>,_>>()?;
    if heads.is_empty() {
        return Ok(vec![(String::new(), item.clone())]);
    }
    let mut result = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (id, body) in heads {
        let edit: Value = serde_json::from_str(&body)?;
        if !seen.insert((edit["text"].to_string(), edit["name"].to_string())) {
            continue;
        }
        let mut value = item.clone();
        value["text"] = edit["text"].clone();
        if value["kind"] != "text" {
            value["name"] = edit["name"].clone();
        }
        result.push((id, value));
    }
    Ok(result)
}

pub(super) fn destination(
    root: &Path,
    tx: &Connection,
    old: &str,
    requested: Option<&str>,
) -> Result<String> {
    if let Some(target) = requested {
        if !valid_id(target)
            || closed(tx, target)?
            || (target != "lanflow-self-chat"
                && !tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM conversations WHERE id=?)",
                    [target],
                    |r| r.get::<_, bool>(0),
                )?)
        {
            return Err("目标会话已删除或不存在，请重新选择".into());
        }
        return Ok(target.to_owned());
    }
    // Restoring never removes the old deletion marker or reuses its identity.
    let original: Option<String> = tx
        .query_row("SELECT body FROM conversations WHERE id=?", [old], |r| {
            r.get(0)
        })
        .optional()?;
    let original: Value = serde_json::from_str(original.as_deref().unwrap_or("{}"))?;
    let mut name = String::new();
    for c in original["name"].as_str().unwrap_or("会话").chars() {
        if name.encode_utf16().count() + c.len_utf16() > 35 {
            break;
        }
        name.push(c);
    }
    name.push_str("（恢复）");
    let mut target = digest(format!("restore-conversation:{old}").as_bytes());
    while closed(tx, &target)? {
        target = digest(format!("restore-conversation:{target}").as_bytes());
    }
    if tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM conversations WHERE id=?)",
        [&target],
        |r| r.get::<_, bool>(0),
    )? {
        return Ok(target);
    }
    let mut conversation =
        json!({"id":target,"name":name,"revision":Utc::now().timestamp_micros()});
    for key in ["avatar", "avatarColor"] {
        if let Some(value) = original.get(key) {
            conversation[key] = value.clone();
        }
    }
    events::apply_transaction(
        root,
        tx,
        &json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"conversation","conversation":conversation}),
        None,
    )?;
    Ok(target)
}

pub(super) fn restore(root: &Path, db: &mut Connection, request: &Value) -> Result<Option<String>> {
    let source = id(request, "id")?;
    let tx = db.transaction()?;
    let body: Option<String> = tx
        .query_row(
            "SELECT body FROM conversation_recovery WHERE id=?",
            [&source],
            |r| r.get(0),
        )
        .optional()?;
    let Some(body) = body else {
        return Ok(None);
    };
    let item: Value = serde_json::from_str(&body)?;
    if item["kind"] != "text" {
        let path = attachments::item_path(&tx, &item)?.ok_or("文件尚未下载完成")?;
        if !fs::metadata(root.join(path))
            .is_ok_and(|m| m.is_file() && Some(m.len()) == item["size"].as_u64())
        {
            return Err("文件尚未下载完成".into());
        }
    }
    let owner = destination(
        root,
        &tx,
        string(&item, "conversationId")?,
        request["conversationId"].as_str(),
    )?;
    let favorite = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM favorites WHERE id=? AND json_extract(body,'$.value')=1)",
        [&source],
        |r| r.get::<_, bool>(0),
    )?;
    for (version, mut restored) in variants(&tx, &item)? {
        restored["id"] = json!(digest(format!("recover:{source}:{version}").as_bytes()));
        restored["conversationId"] = json!(owner);
        let restored = events::normalize_item(&restored)?;
        events::apply_transaction(root, &tx, &item_event(&restored), None)?;
        if favorite {
            favorites::restore_mark(&tx, &restored, &source)?;
        }
    }
    events::delete_transaction(root, &tx, &source)?;
    tx.execute("DELETE FROM trash WHERE id=?", [&source])?;
    tx.commit()?;
    Ok(Some(owner))
}
