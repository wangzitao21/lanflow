use super::*;

pub(super) fn trash(root: &Path, db: &Connection) -> Result<Value> {
    let mut statement = db.prepare("SELECT id,body,deleted_at,source,original_id FROM (SELECT id,body,deleted_at,'conversation' AS source,NULL AS original_id FROM trash UNION ALL SELECT id,body,deleted_at,'favorite' AS source,original_id FROM favorite_trash) ORDER BY deleted_at DESC,id DESC")?;
    let rows = statement.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?,
        ))
    })?;
    let mut result = Vec::new();
    for row in rows {
        let (id, body, deleted_at, source, original) = row?;
        let item: Value = serde_json::from_str(&body)?;
        let available = item["kind"] == "text"
            || fs::metadata(attachments::path(root, string(&item, "sha256")?))
                .map(|m| m.len())
                .ok()
                == item["size"].as_u64();
        result.push(json!({"id":id,"source":source,"originalMessageId":original,"item": item, "deletedAt": deleted_at, "available": available}));
    }
    Ok(json!(result))
}

pub(super) fn trash_page(root: &Path, db: &Connection, request: &Value) -> Result<Value> {
    let limit = request["limit"].as_i64().unwrap_or(50).clamp(1, 100);
    let query = request["query"].as_str().unwrap_or("").trim();
    let at = request["after"]["at"].as_str().unwrap_or("");
    let after_id = request["after"]["id"].as_str().unwrap_or("");
    let after_source = request["after"]["source"].as_str().unwrap_or("");
    let rows_table = "(SELECT id,body,deleted_at,'conversation' AS source,NULL AS original_id FROM trash UNION ALL SELECT id,body,deleted_at,'favorite' AS source,original_id FROM favorite_trash)";
    let filter = "(?1='' OR instr(lower(json_extract(body,'$.text') || ' ' || json_extract(body,'$.name')),lower(?1))>0)";
    let total: i64 = db.query_row(
        &format!("SELECT count(*) FROM {rows_table} WHERE {filter}"),
        [query],
        |r| r.get(0),
    )?;
    let mut statement = db.prepare(&format!(
        "SELECT id,body,deleted_at,source,original_id FROM {rows_table} WHERE {filter} AND (?2='' OR deleted_at<?2 OR (deleted_at=?2 AND (id<?3 OR (id=?3 AND source<?4)))) ORDER BY deleted_at DESC,id DESC,source DESC LIMIT ?5"
    ))?;
    let rows = statement
        .query_map(params![query, at, after_id, after_source, limit + 1], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let more = rows.len() > limit as usize;
    let mut items = Vec::new();
    let mut cursor = Value::Null;
    for (id, body, at, source, original) in rows.into_iter().take(limit as usize) {
        let item: Value = serde_json::from_str(&body)?;
        let available = item["kind"] == "text"
            || fs::metadata(attachments::path(root, string(&item, "sha256")?))
                .map(|m| m.len())
                .ok()
                == item["size"].as_u64();
        cursor = json!({"at":at,"id":id,"source":source});
        items.push(json!({"id":id,"source":source,"originalMessageId":original,"item":item,"deletedAt":at,"available":available}));
    }
    Ok(json!({"items":items,"total":total,"more":more,"cursor":cursor}))
}

pub(super) fn restore(root: &Path, db: &mut Connection, target: &str) -> Result<()> {
    let body: Option<String> = db
        .query_row("SELECT body FROM trash WHERE id=?", [target], |r| r.get(0))
        .optional()?;
    let Some(body) = body else {
        return Ok(());
    };
    let mut item: Value = serde_json::from_str(&body)?;
    let was_favorite = item["_wasFavorite"] == true;
    // Keep the tombstone immutable for old/offline peers. A deterministic new
    // identity also makes a retry after a crash between these writes idempotent.
    let restored = digest(format!("restore:{target}").as_bytes());
    if deleted(db, &restored)? {
        return Err("此内容已恢复过，请在回收站中恢复较新的记录".into());
    }
    item["id"] = json!(restored);
    let tx=db.transaction()?;
    let existing: Option<String> = tx.query_row("SELECT body FROM items WHERE id=?",[string(&item,"id")?],|r| r.get(0)).optional()?;
    let item=if let Some(existing)=existing { events::normalize_item(&serde_json::from_str::<Value>(&existing)?)? } else {
        let item=events::normalize_item(&item)?;
        events::apply_transaction(root,&tx,&item_event(&item),None)?;
        item
    };
    if was_favorite { favorites::restore_mark(&tx,&item,target)?; }
    tx.execute("DELETE FROM trash WHERE id=?", [target])?;
    tx.commit()?;
    Ok(())
}

fn folder_size(path: &Path) -> Result<u64> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.into()),
    };
    #[cfg(windows)]
    let linked = {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    };
    #[cfg(not(windows))]
    let linked = meta.file_type().is_symlink();
    if linked {
        return Ok(0);
    }
    if meta.is_file() {
        return Ok(meta.len());
    }
    let mut total = 0;
    for child in fs::read_dir(path)? {
        total += folder_size(&child?.path())?;
    }
    Ok(total)
}

fn clear_previews(path: &Path, boundary: &Path, skipped: &mut u64) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    // Do not follow junctions/symlinks or remove files outside this cache.
    if meta.file_type().is_symlink() || !path.canonicalize()?.starts_with(boundary) {
        *skipped += 1;
        return Ok(());
    }
    if meta.is_dir() {
        for entry in fs::read_dir(path)? {
            clear_previews(&entry?.path(), boundary, skipped)?;
        }
        if path != boundary {
            let _ = fs::remove_dir(path);
        }
    } else if meta.is_file() && fs::remove_file(path).is_err() {
        // A preview open in another Windows application can be retried later.
        *skipped += 1;
    }
    Ok(())
}

pub(super) fn storage(root: &Path, clear: bool) -> Result<Value> {
    let shared = database(root)?;
    let root = root.canonicalize()?;
    let preview = layout::previews(&root);
    let mut skipped = 0;
    if clear && preview.exists() {
        let resolved = preview.canonicalize()?;
        if !resolved.starts_with(&root) || fs::symlink_metadata(&preview)?.file_type().is_symlink()
        {
            return Err("预览缓存位置异常，未清理任何内容".into());
        }
        clear_previews(&resolved, &resolved, &mut skipped)?;
    }
    let blobs = folder_size(&root.join("media"))?
        + folder_size(&root.join("files"))?
        + folder_size(&layout::pending(&root))?;
    let cache = folder_size(&preview)?;
    let partial = folder_size(&layout::incoming(&root))?;
    let recovered = folder_size(&layout::system(&root).join("recovered"))?;
    let database_bytes = [
        "messages.sqlite3",
        "messages.sqlite3-wal",
        "messages.sqlite3-shm",
    ]
    .iter()
    .map(|name| {
        fs::metadata(layout::system(&root).join(name))
            .map(|m| m.len())
            .unwrap_or(0)
    })
    .sum::<u64>();
    // Include retained user edits, legacy received files, device settings and
    // any other real files in the selected storage root. Never follow links.
    let known = blobs + cache + partial + database_bytes + recovered;
    let total = folder_size(&root)?.max(known);
    let other = total.saturating_sub(known);
    let db = shared.lock().map_err(|_| "Database unavailable")?;
    let count: i64 = db.query_row("SELECT count(*) FROM items", [], |r| r.get(0))?;
    let deleted_count: i64 = db.query_row(
        "SELECT (SELECT count(*) FROM trash)+(SELECT count(*) FROM favorite_trash)",
        [],
        |r| r.get(0),
    )?;
    Ok(
        json!({"blobs":blobs,"cache":cache,"partial":partial,"database":database_bytes,
        "recovered":recovered,"other":other,"total":total,"messages":count,"deleted":deleted_count,"skipped":skipped}),
    )
}
