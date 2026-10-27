use super::*;

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS message_edit_versions(event_id TEXT PRIMARY KEY,item_id TEXT NOT NULL,revision INTEGER NOT NULL,body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS edit_versions_item ON message_edit_versions(item_id,revision,event_id);
        CREATE TABLE IF NOT EXISTS message_edit_parents(event_id TEXT NOT NULL,parent_id TEXT NOT NULL,PRIMARY KEY(event_id,parent_id));
        CREATE INDEX IF NOT EXISTS edit_parents_parent ON message_edit_parents(parent_id);
        CREATE TABLE IF NOT EXISTS message_edit_heads(item_id TEXT NOT NULL,event_id TEXT NOT NULL,PRIMARY KEY(item_id,event_id));")?;
    let initialized: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='edit_graph_ready')",
        [],
        |r| r.get(0),
    )?;
    if !initialized {
        // Old records have no causal context. Preserve their current version as
        // the starting point, without turning historical edits into conflicts.
        db.execute("INSERT OR IGNORE INTO message_edit_versions SELECT event_id,id,revision,body FROM message_edits", [])?;
        db.execute(
            "INSERT OR IGNORE INTO message_edit_heads SELECT id,event_id FROM message_edits",
            [],
        )?;
        let targets = db
            .prepare("SELECT id FROM message_edits")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        for target in targets {
            project(db, &target)?;
        }
        db.execute("INSERT INTO meta VALUES('edit_graph_ready','true')", [])?;
    }
    Ok(())
}

pub(super) fn heads(db: &Connection, target: &str) -> Result<Vec<String>> {
    Ok(db
        .prepare("SELECT event_id FROM message_edit_heads WHERE item_id=? ORDER BY event_id")?
        .query_map([target], |r| r.get(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?)
}

fn ids(value: &Value) -> Result<Vec<String>> {
    let values = value
        .as_array()
        .filter(|values| values.len() <= 1024)
        .ok_or("Invalid edit context")?;
    let mut result = Vec::new();
    for value in values {
        result.push(
            value
                .as_str()
                .filter(|id| valid_id(id))
                .ok_or("Invalid edit context")?
                .to_owned(),
        );
    }
    result.sort();
    if result.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err("Duplicate edit context".into());
    }
    Ok(result)
}

pub(super) fn edit(root: &Path, db: &mut Connection, request: &Value) -> Result<()> {
    let target = id(request, "id")?;
    let body: String = db
        .query_row("SELECT body FROM items WHERE id=?", [&target], |r| r.get(0))
        .optional()?
        .ok_or("消息已删除，无法修改")?;
    let current: Value = serde_json::from_str(&body)?;
    let current_heads = heads(db, &target)?;
    let resolving = request["resolve"] == true;
    let parents = if resolving {
        let expected = ids(&request["heads"])?;
        if expected != current_heads {
            return Err("冲突版本已更新，请重新查看后选择".into());
        }
        expected
    } else if let Some(context) = request.get("parents") {
        ids(context)?
    } else {
        current_heads.clone()
    };
    if !resolving && parents == current_heads && conflicted(db, &target)? {
        return Err("请先选择或编辑这条消息的冲突版本".into());
    }
    let mut item = current.clone();
    if resolving && request["versionId"].is_string() {
        let selected = id(request, "versionId")?;
        if !current_heads.contains(&selected) {
            return Err("冲突版本已更新，请重新查看后选择".into());
        }
        let version: String = db.query_row(
            "SELECT body FROM message_edit_versions WHERE item_id=? AND event_id=?",
            params![target, selected],
            |r| r.get(0),
        )?;
        let version: Value = serde_json::from_str(&version)?;
        item["text"] = version["text"].clone();
        if item["kind"] != "text" {
            item["name"] = version["name"].clone();
        }
    } else {
        item["text"] = json!(string(request, "text")?);
        if item["kind"] != "text" {
            item["name"] = json!(string(request, "name")?);
        }
    }
    if item["kind"] == "text" && string(&item, "text")?.trim().is_empty() {
        return Err("消息内容不能为空".into());
    }
    if item["kind"] != "text" && string(&item, "name")?.trim().is_empty() {
        return Err("文件名不能为空".into());
    }
    validate_item(&item)?;
    if !resolving && item["text"] == current["text"] && item["name"] == current["name"] {
        return Ok(());
    }
    let previous: i64 = db.query_row(
        "SELECT COALESCE(MAX(revision),0) FROM message_edit_versions WHERE item_id=?",
        [&target],
        |r| r.get(0),
    )?;
    let event = json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"edit","target":target,
        "revision":Utc::now().timestamp_millis().max(previous.checked_add(1).ok_or("Invalid edit revision")?),
        "parents":parents,"text":item["text"],"name":item["name"],
        "editorId":request["editorId"].as_str().unwrap_or(string(&current,"originId")?),
        "editorName":request["editorName"].as_str().unwrap_or(string(&current,"originName")?),
        "editedAt":Utc::now().to_rfc3339()});
    apply(root, db, &event, None)?;
    Ok(())
}

pub(super) fn apply_edit(db: &Connection, event: &Value) -> Result<()> {
    let target = id(event, "target")?;
    let event_id = id(event, "id")?;
    let revision = event["revision"]
        .as_i64()
        .filter(|v| *v > 0)
        .ok_or("Invalid edit revision")?;
    if string(event, "text")?.encode_utf16().count() > 20000
        || string(event, "name")?.encode_utf16().count() > 512
    {
        return Err("Invalid message length".into());
    }
    if let Some(editor) = event.get("editorId") {
        if !editor.as_str().is_some_and(valid_id) {
            return Err("Invalid edit author".into());
        }
        if string(event, "editorName")?.encode_utf16().count() > 60 {
            return Err("Invalid edit author".into());
        }
    }
    if let Some(time) = event.get("editedAt") {
        chrono::DateTime::parse_from_rfc3339(time.as_str().ok_or("Invalid edit time")?)?;
    }
    let previous_heads = heads(db, &target)?;
    let parents = event.get("parents").map(ids).transpose()?;
    let foreign_child: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM message_edit_parents p JOIN message_edit_versions v ON v.event_id=p.event_id WHERE p.parent_id=? AND v.item_id!=?)", params![event_id,target], |r| r.get(0))?;
    if foreign_child {
        return Err("Edit context belongs to another message".into());
    }
    if let Some(parents) = &parents {
        for parent in parents {
            let foreign: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM message_edit_versions WHERE event_id=? AND item_id!=?)", params![parent,target], |r| r.get(0))?;
            let cycle: bool = db.query_row("WITH RECURSIVE ancestors(id) AS (SELECT ?1 UNION SELECT p.parent_id FROM message_edit_parents p JOIN ancestors a ON p.event_id=a.id) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id=?2)", params![parent,event_id], |r| r.get(0))?;
            if foreign || cycle {
                return Err("Invalid edit ancestry".into());
            }
        }
    }
    db.execute(
        "INSERT OR IGNORE INTO message_edit_versions VALUES(?,?,?,?)",
        params![event_id, target, revision, serde_json::to_string(event)?],
    )?;
    if let Some(parents) = parents {
        for parent in parents {
            db.execute(
                "INSERT OR IGNORE INTO message_edit_parents VALUES(?,?)",
                params![event_id, parent],
            )?;
        }
    } else {
        // Legacy history remains linear. It cannot claim to observe a modern
        // edit whose causal context the older client did not preserve.
        let legacy = db.prepare("SELECT event_id FROM message_edit_versions WHERE item_id=? AND json_type(body,'$.parents') IS NULL ORDER BY revision,event_id")?
            .query_map([&target], |r| r.get::<_,String>(0))?.collect::<std::result::Result<Vec<_>,_>>()?;
        for pair in legacy.windows(2) {
            db.execute(
                "INSERT OR IGNORE INTO message_edit_parents VALUES(?,?)",
                params![pair[1], pair[0]],
            )?;
        }
    }
    db.execute("DELETE FROM message_edit_heads WHERE item_id=?", [&target])?;
    db.execute("INSERT INTO message_edit_heads SELECT v.item_id,v.event_id FROM message_edit_versions v WHERE v.item_id=? AND NOT EXISTS(SELECT 1 FROM message_edit_parents p WHERE p.parent_id=v.event_id)", [&target])?;
    if heads(db, &target)? != previous_heads {
        project(db, &target)?;
        db.execute("DELETE FROM copies WHERE item_id=?", [&target])?;
    }
    Ok(())
}

fn project(db: &Connection, target: &str) -> Result<()> {
    // This is only a deterministic preview. Competing versions remain intact
    // and the message is not called synchronized until the user resolves it.
    db.execute("INSERT INTO message_edits SELECT v.item_id,v.revision,v.event_id,v.body FROM message_edit_heads h JOIN message_edit_versions v ON v.event_id=h.event_id WHERE h.item_id=? ORDER BY v.revision DESC,v.event_id DESC LIMIT 1 ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,event_id=excluded.event_id,body=excluded.body", [target])?;
    let body: Option<String> = db
        .query_row("SELECT body FROM items WHERE id=?", [target], |r| r.get(0))
        .optional()?;
    if let Some(body) = body {
        let updated = edited_item(db, &serde_json::from_str(&body)?)?;
        db.execute(
            "UPDATE items SET body=? WHERE id=?",
            params![serde_json::to_string(&updated)?, target],
        )?;
        favorites::source_changed(db,target)?;
    }
    Ok(())
}

pub(super) fn conflicted(db: &Connection, target: &str) -> Result<bool> {
    Ok(db.query_row("SELECT COUNT(DISTINCT json_array(json_extract(v.body,'$.text'),json_extract(v.body,'$.name')))>1 FROM message_edit_heads h JOIN message_edit_versions v ON v.event_id=h.event_id WHERE h.item_id=?", [target], |r| r.get(0))?)
}

pub(super) fn conflicts(db: &Connection) -> Result<Value> {
    let targets = db.prepare("SELECT h.item_id FROM message_edit_heads h JOIN message_edit_versions v ON v.event_id=h.event_id JOIN items i ON i.id=h.item_id GROUP BY h.item_id HAVING COUNT(DISTINCT json_array(json_extract(v.body,'$.text'),json_extract(v.body,'$.name')))>1 ORDER BY h.item_id")?
        .query_map([], |r| r.get::<_,String>(0))?.collect::<std::result::Result<Vec<_>,_>>()?;
    let mut result = Vec::new();
    for target in targets {
        let item: String =
            db.query_row("SELECT body FROM items WHERE id=?", [&target], |r| r.get(0))?;
        let rows = db.prepare("SELECT v.body FROM message_edit_heads h JOIN message_edit_versions v ON v.event_id=h.event_id WHERE h.item_id=? ORDER BY v.revision DESC,v.event_id DESC")?
            .query_map([&target], |r| r.get::<_,String>(0))?.collect::<std::result::Result<Vec<_>,_>>()?;
        let versions = rows
            .iter()
            .map(|body| serde_json::from_str::<Value>(body))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        result.push(json!({"id":target,"item":serde_json::from_str::<Value>(&item)?,"heads":heads(db,&target)?,"versions":versions}));
    }
    Ok(json!(result))
}

pub(super) fn edited_item(db: &Connection, item: &Value) -> Result<Value> {
    let mut result = item.clone();
    let target = string(item, "id")?;
    let body: Option<String> = db
        .query_row("SELECT body FROM message_edits WHERE id=?", [target], |r| {
            r.get(0)
        })
        .optional()?;
    if let Some(body) = body {
        let edit: Value = serde_json::from_str(&body)?;
        result["text"] = edit["text"].clone();
        if result["kind"] != "text" {
            result["name"] = edit["name"].clone();
        }
        result["editHeads"] = json!(heads(db, target)?);
        validate_item(&result)?;
    }
    Ok(result)
}

pub(super) fn mark_copy(db: &Connection, item: &str, endpoint: &str) -> Result<bool> {
    if conflicted(db, item)? {
        return Ok(false);
    }
    Ok(db.execute("INSERT OR IGNORE INTO copies SELECT ?1,?2 WHERE EXISTS(SELECT 1 FROM items WHERE id=?1) AND NOT EXISTS(SELECT 1 FROM message_edit_heads h WHERE h.item_id=?1 AND NOT EXISTS(SELECT 1 FROM seen s WHERE s.event_id=h.event_id AND s.endpoint=?2))", params![item,endpoint])? > 0)
}
