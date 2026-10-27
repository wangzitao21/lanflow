use super::*;

pub(super) fn schema(db: &Connection) -> Result<()> {
    let existed: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='transfer_changes')",
        [],
        |r| r.get(0),
    )?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS transfer_clock(value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS transfer_changes(endpoint TEXT NOT NULL,direction TEXT NOT NULL,event_id TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(endpoint,direction,event_id));
        CREATE INDEX IF NOT EXISTS transfer_changes_revision ON transfer_changes(revision);
        CREATE INDEX IF NOT EXISTS transfer_changes_endpoint_revision ON transfer_changes(endpoint,revision);")?;
    if !existed {
        db.execute_batch("INSERT INTO transfer_clock SELECT COALESCE(MAX(rowid),0) FROM transfer_jobs;
            INSERT INTO transfer_changes SELECT endpoint,direction,event_id,rowid FROM transfer_jobs;")?;
    }
    for action in ["INSERT", "UPDATE", "DELETE"] {
        let row = if action == "DELETE" { "OLD" } else { "NEW" };
        db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS transfer_changes_{action} AFTER {action} ON transfer_jobs BEGIN
            UPDATE transfer_clock SET value=value+1;
            INSERT INTO transfer_changes VALUES({row}.endpoint,{row}.direction,{row}.event_id,(SELECT value FROM transfer_clock))
            ON CONFLICT(endpoint,direction,event_id) DO UPDATE SET revision=excluded.revision; END;"))?;
    }
    Ok(())
}

pub(super) fn updates(db: &Connection, request: &Value) -> Result<Value> {
    let head: i64 = db.query_row("SELECT value FROM transfer_clock", [], |r| r.get(0))?;
    let requested = request["after"].as_i64().unwrap_or(0).max(0);
    let after = if requested > head { 0 } else { requested };
    // Keep removals that happen during a paged initial load: an earlier page
    // may already contain the job. Older removals need not be replayed.
    let initial = if after == 0 {
        Some(head)
    } else {
        request["initialThrough"]
            .as_i64()
            .filter(|value| *value >= 0 && *value <= head)
    };
    let endpoints = request["endpoints"]
        .as_array()
        .filter(|values| values.len() <= 256)
        .ok_or("Invalid transfer endpoints")?;
    if endpoints.iter().any(|e| !e.is_string()) {
        return Err("Invalid transfer endpoints".into());
    }
    let mut statement = db.prepare("SELECT c.endpoint,c.direction,c.event_id,c.revision,j.body,j.transferred,j.state,j.error,j.retry_after,j.error_category,j.completed_at
        FROM transfer_changes c LEFT JOIN transfer_jobs j ON j.endpoint=c.endpoint AND j.direction=c.direction AND j.event_id=c.event_id
        WHERE c.revision>?1 AND c.endpoint IN (SELECT value FROM json_each(?2))
        AND (?3 IS NULL OR c.revision>?3 OR (j.state IS NOT NULL AND j.state NOT IN ('completed','dismissed')))
        ORDER BY c.revision LIMIT 201")?;
    let rows = statement
        .query_map(
            params![after, serde_json::to_string(endpoints)?, initial],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<i64>>(5)?,
                    r.get::<_, Option<String>>(6)?,
                    r.get::<_, Option<String>>(7)?,
                    r.get::<_, Option<i64>>(8)?,
                    r.get::<_, Option<String>>(9)?,
                    r.get::<_, Option<i64>>(10)?,
                ))
            },
        )?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let more = rows.len() > 200;
    let mut cursor = after;
    let mut items = Vec::new();
    let mut removed = Vec::new();
    for (
        endpoint,
        direction,
        event_id,
        revision,
        body,
        transferred,
        state,
        error,
        retry,
        category,
        completed,
    ) in rows.into_iter().take(200)
    {
        cursor = revision;
        if body.is_none()
            || state
                .as_deref()
                .is_some_and(|v| matches!(v, "completed" | "dismissed"))
        {
            removed.push(json!(format!("{endpoint}:{direction}:{event_id}")));
            continue;
        }
        let event: Value = serde_json::from_str(body.as_deref().unwrap())?;
        items.push(json!({"endpoint":endpoint,"direction":direction,"eventId":event_id,
            "item":events::transfer_item(&event).ok_or("Invalid transfer event")?,"transferred":transferred,"state":state,"error":error,
            "retryAfter":retry.filter(|v|*v>0),"errorCategory":category,"completedAt":completed.filter(|v|*v>0)}));
    }
    let mut result = json!({"items":items,"removed":removed,"cursor":if more {cursor} else {head},"more":more,"reset":requested>head});
    if more && initial.is_some() {
        result["initialThrough"] = json!(initial);
    }
    Ok(result)
}

pub(super) fn scheduled(db: &Connection, key: &str) -> Result<Vec<(String, String, String, u64)>> {
    let mut statement = db.prepare("SELECT direction,event_id,body,transferred FROM transfer_jobs WHERE endpoint=? AND state IN ('queued','failed') AND retry_after<=? ORDER BY last_attempt,sequence LIMIT 4")?;
    Ok(statement
        .query_map(params![key, Utc::now().timestamp()], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get::<_, i64>(3)?.max(0) as u64,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?)
}

pub(super) fn attempted(db: &Connection, key: &str, direction: &str, event: &str) -> Result<()> {
    // A durable monotonic turn survives clock changes and process restarts.
    db.execute("UPDATE transfer_jobs SET last_attempt=(SELECT COALESCE(MAX(last_attempt),0)+1 FROM transfer_jobs) WHERE endpoint=? AND direction=? AND event_id=? AND state IN ('queued','failed')", params![key,direction,event])?;
    Ok(())
}

pub(super) fn queue_outgoing(db: &Connection, key: &str, after: i64) -> Result<()> {
    // Persist pending files even when the remote endpoint cannot be reached.
    // Stored events are already validated. One statement avoids a separate
    // fully durable transaction for every queued attachment in a large import.
    db.execute("INSERT OR IGNORE INTO transfer_jobs(endpoint,direction,event_id,sequence,body)
        SELECT ?1,'upload',id,sequence,body FROM events WHERE sequence>?2
        AND json_extract(body,'$.type')='item' AND json_extract(body,'$.item.kind')!='text'
        AND NOT EXISTS(SELECT 1 FROM seen WHERE seen.event_id=events.id AND endpoint=?1)
        AND NOT EXISTS(SELECT 1 FROM deleted WHERE deleted.id=json_extract(events.body,'$.item.id'))",
        params![key,after])?;
    Ok(())
}

pub(super) fn enqueue(db: &Connection, key: &str, direction: &str, record: &Value) -> Result<()> {
    let event = &record["event"];
    validate_item(events::transfer_item(event).ok_or("Invalid transfer event")?)?;
    db.execute(
        "INSERT OR IGNORE INTO transfer_jobs(endpoint,direction,event_id,sequence,body) VALUES(?,?,?,?,?)",
        params![key, direction, id(event,"id")?, record["sequence"].as_i64().ok_or("Invalid sequence")?, serde_json::to_string(event)?],
    )?;
    Ok(())
}

pub(super) fn queue_favorites(
    db: &Connection,
    key: &str,
    after: i64,
    snapshots: bool,
) -> Result<()> {
    db.execute("INSERT OR IGNORE INTO transfer_jobs(endpoint,direction,event_id,sequence,body)
        SELECT ?1,'upload',e.id,e.sequence,e.body FROM events e WHERE e.sequence>?2
        AND (json_extract(e.body,'$.type')='favorite' OR (?3 AND json_extract(e.body,'$.type')='favorite_snapshot'))
        AND json_extract(e.body,'$.favorite.item.kind')!='text'
        AND NOT EXISTS(SELECT 1 FROM seen WHERE seen.event_id=e.id AND endpoint=?1)
        AND (EXISTS(SELECT 1 FROM favorites f WHERE f.id=json_extract(e.body,'$.favorite.id') AND json_extract(f.body,'$.value')=1)
            OR EXISTS(SELECT 1 FROM favorite_trash t WHERE t.original_id=json_extract(e.body,'$.favorite.id')))",params![key,after,snapshots])?;
    Ok(())
}

pub(super) fn queue_missing_favorites(root: &Path, db: &Connection, key: &str) -> Result<()> {
    let mut statement = db.prepare("SELECT e.sequence,e.body FROM favorites f JOIN events e ON e.id=f.event_id WHERE NOT EXISTS(SELECT 1 FROM deleted d WHERE d.id=f.id) AND json_extract(f.body,'$.item.kind')!='text' AND (json_extract(f.body,'$.value')=1 OR EXISTS(SELECT 1 FROM favorite_trash t WHERE t.original_id=f.id))")?;
    let rows = statement
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    for (sequence, body) in rows {
        let event: Value = serde_json::from_str(&body)?;
        let Some(item) = events::transfer_item(&event) else {
            continue;
        };
        if fs::metadata(attachments::path(root, string(item, "sha256")?))
            .map(|m| m.len())
            .ok()
            != item["size"].as_u64()
        {
            enqueue(
                db,
                key,
                "download",
                &json!({"sequence":sequence,"event":event}),
            )?;
            db.execute("UPDATE transfer_jobs SET state='queued',transferred=0,completed_at=0 WHERE endpoint=? AND direction='download' AND event_id=? AND state='completed'",params![key,string(&event,"id")?])?;
        }
    }
    Ok(())
}

pub(super) fn list(db: &Connection) -> Result<Value> {
    query(
        db,
        "state NOT IN ('completed','dismissed')",
        "sequence,endpoint,direction,event_id",
        -1,
        0,
    )
}

pub(super) fn complete_local_downloads(root: &Path, shared: &Database) -> Result<()> {
    let jobs = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let mut statement = db.prepare("SELECT endpoint,event_id,body FROM transfer_jobs WHERE direction='download' AND state IN ('queued','failed')")?;
        statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?
    };
    for (key, event_id, body) in jobs {
        let event: Value = serde_json::from_str(&body)?;
        let Some(item) = events::transfer_item(&event) else {
            continue;
        };
        let hash = string(item, "sha256")?;
        let size = item["size"].as_u64().ok_or("Invalid file size")?;
        if !verified_files::check(&attachments::path(root, hash), hash, size)? {
            continue;
        }
        attachments::register(root, shared, item)?;
        let mut db = shared.lock().map_err(|_| "Database unavailable")?;
        if !active(&db, &key, "download", &event_id)? {
            continue;
        }
        // A different route already supplied these bytes. No request to this
        // possibly offline source is needed, and no remote receipt is invented.
        apply(root, &mut db, &event, None)?;
        if events::is_favorite(&event) {
            favorites::touch(&db, &event)?;
        }
        complete(&db, &key, "download", &event_id, size)?;
    }
    Ok(())
}

pub(super) fn page(db: &Connection, request: &Value) -> Result<Value> {
    let filter = match request["scope"].as_str().unwrap_or("completed") {
        "active" => "state NOT IN ('completed','dismissed')",
        "completed" => "state='completed'",
        "all" => "state!='dismissed'",
        _ => return Err("Invalid transfer scope".into()),
    };
    let offset = request["offset"].as_i64().unwrap_or(0).max(0);
    let limit = request["limit"].as_i64().unwrap_or(50).clamp(1, 200);
    let total: i64 = db.query_row(
        &format!("SELECT COUNT(*) FROM transfer_jobs WHERE {filter}"),
        [],
        |r| r.get(0),
    )?;
    let items = query(
        db,
        filter,
        "(state='completed'),completed_at DESC,sequence DESC,endpoint,direction,event_id",
        limit,
        offset,
    )?;
    let next = offset.saturating_add(items.as_array().map_or(0, |items| items.len()) as i64);
    Ok(json!({"items":items,"total":total,"more":next<total,"nextOffset":next}))
}

fn query(db: &Connection, filter: &str, order: &str, limit: i64, offset: i64) -> Result<Value> {
    let mut statement = db.prepare(&format!("SELECT endpoint,direction,event_id,body,transferred,state,error,retry_after,error_category,completed_at FROM transfer_jobs WHERE {filter} ORDER BY {order} LIMIT ? OFFSET ?"))?;
    let mut result = Vec::new();
    for row in statement.query_map(params![limit, offset], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, String>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, i64>(7)?,
            r.get::<_, Option<String>>(8)?,
            r.get::<_, i64>(9)?,
        ))
    })? {
        let (
            endpoint,
            direction,
            event_id,
            body,
            transferred,
            state,
            error,
            retry_after,
            error_category,
            completed_at,
        ) = row?;
        let event: Value = serde_json::from_str(&body)?;
        result.push(
            json!({"endpoint":endpoint,"direction":direction,"eventId":event_id,
            "item":events::transfer_item(&event).ok_or("Invalid transfer event")?,"transferred":transferred,"state":state,"error":error,
            "retryAfter":(retry_after>0).then_some(retry_after),"errorCategory":error_category,
            "completedAt":(completed_at>0).then_some(completed_at)}),
        );
    }
    Ok(json!(result))
}

pub(super) fn action(db: &Connection, request: &Value) -> Result<Value> {
    let state = match string(request, "action")? {
        "pause" => "paused",
        "cancel" => "cancelled",
        "retry" => "queued",
        "delete" => "dismissed",
        _ => return Err("Unknown transfer action".into()),
    };
    let changed = db.execute(
        "UPDATE transfer_jobs SET state=?1,error=NULL,error_category=NULL,retry_after=0,failures=0 WHERE endpoint=?2 AND direction=?3 AND event_id=?4 AND (state!='completed' OR ?1='dismissed')",
        params![state,string(request,"endpoint")?,string(request,"direction")?,id(request,"eventId")?],
    )?;
    Ok(json!(changed > 0))
}

pub(super) fn active(db: &Connection, key: &str, direction: &str, event_id: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT state IN ('queued','failed') FROM transfer_jobs WHERE endpoint=? AND direction=? AND event_id=?",
        params![key,direction,event_id], |r| r.get(0),
    ).optional()?.unwrap_or(false))
}

pub(super) fn progress(
    db: &Connection,
    key: &str,
    direction: &str,
    event_id: &str,
    bytes: u64,
    error: Option<&(dyn std::error::Error + 'static)>,
) -> Result<()> {
    let failures =
        if error.is_some() {
            db.query_row(
            "SELECT failures FROM transfer_jobs WHERE endpoint=? AND direction=? AND event_id=?",
            params![key,direction,event_id], |r| r.get::<_,i64>(0),
        ).optional()?.unwrap_or(0).saturating_add(1).min(6)
        } else {
            0
        };
    let retry_after = if failures > 0 {
        Utc::now().timestamp() + (2_i64 << failures)
    } else {
        0
    };
    db.execute(
        "UPDATE transfer_jobs SET transferred=?,state=?,error=?,error_category=?,failures=?,retry_after=? WHERE endpoint=? AND direction=? AND event_id=? AND state IN ('queued','failed')",
        params![i64::try_from(bytes)?,if error.is_some() {"failed"} else {"queued"},error.map(ToString::to_string),error.map(errors::category),failures,retry_after,key,direction,event_id],
    )?;
    Ok(())
}

pub(super) fn complete(
    db: &Connection,
    key: &str,
    direction: &str,
    event_id: &str,
    bytes: u64,
) -> Result<()> {
    db.execute(
        "UPDATE transfer_jobs SET transferred=?,state='completed',error=NULL,error_category=NULL,failures=0,retry_after=0,completed_at=? WHERE endpoint=? AND direction=? AND event_id=? AND state IN ('queued','failed')",
        params![i64::try_from(bytes)?,Utc::now().timestamp_millis(),key,direction,event_id],
    )?;
    // History is useful to confirm a finished transfer, but cannot grow forever.
    db.execute("DELETE FROM transfer_jobs WHERE rowid IN (SELECT rowid FROM transfer_jobs WHERE state='completed' ORDER BY completed_at DESC,rowid DESC LIMIT -1 OFFSET 500)", [])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deleted_tasks_stay_hidden_after_restart_and_explicit_reset_rebuilds_them() {
        let root = crate::tests::root();
        initialize(&root).unwrap();
        let shared = database(&root).unwrap();
        let mut item = json!({"id":"reset-task-item-aa","originId":"reset-device-aaaa","originName":"Device","createdAt":now(),"kind":"file","text":"","name":"file.bin","size":1,"sha256":digest(b"a")});
        let first = item_event(&item);
        item["id"] = json!("reset-task-item-bb");
        let second = item_event(&item);
        {
            let db = shared.lock().unwrap();
            for (sequence, event) in [(1, &first), (2, &second)] {
                enqueue(
                    &db,
                    "device:test",
                    "upload",
                    &json!({"sequence":sequence,"event":event}),
                )
                .unwrap();
            }
            action(&db,&json!({"action":"delete","endpoint":"device:test","direction":"upload","eventId":first["id"]})).unwrap();
            action(&db,&json!({"action":"pause","endpoint":"device:test","direction":"upload","eventId":second["id"]})).unwrap();
            enqueue(
                &db,
                "device:test",
                "upload",
                &json!({"sequence":1,"event":first}),
            )
            .unwrap();
            assert_eq!(list(&db).unwrap().as_array().unwrap().len(), 1);
            assert!(scheduled(&db, "device:test").unwrap().is_empty());
        }
        drop(shared);
        dispatch(json!({"op":"close","root":root})).unwrap();
        assert_eq!(
            dispatch(json!({"op":"transfers","root":root}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        dispatch(json!({"op":"reset_endpoint","root":root,"key":"device:test"})).unwrap();
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        let jobs = scheduled(&db, "device:test").unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].1, first["id"].as_str().unwrap());
        assert_eq!(list(&db).unwrap().as_array().unwrap().len(), 2);
        drop(db);
        crate::tests::cleanup(&root);
    }

    #[test]
    fn healthy_large_transfers_yield_to_later_small_and_reverse_transfers() {
        let root = crate::tests::root();
        initialize(&root).unwrap();
        let shared = database(&root).unwrap();
        let db = shared.lock().unwrap();
        for index in 0..6 {
            let item = json!({"id":format!("fair-item-{index:016}"),"originId":"fair-device-origin","originName":"Device","createdAt":now(),"kind":"file","text":"","name":"file.bin","size":if index<4 {100_000_000} else {10},"sha256":digest(format!("payload-{index}").as_bytes())});
            enqueue(
                &db,
                "peer",
                if index == 5 { "download" } else { "upload" },
                &json!({"sequence":index+1,"event":item_event(&item)}),
            )
            .unwrap();
        }
        let first = scheduled(&db, "peer").unwrap();
        assert_eq!(first.len(), 4);
        for (direction, event, _, _) in &first {
            attempted(&db, "peer", direction, event).unwrap();
            progress(&db, "peer", direction, event, 4 * 1024 * 1024, None).unwrap();
        }
        let second = scheduled(&db, "peer").unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&second[0].2).unwrap()["item"]["size"],
            10
        );
        assert_eq!(second[1].0, "download");
        assert!(
            first
                .iter()
                .all(|(direction, event, _, _)| active(&db, "peer", direction, event).unwrap())
        );
        let expected = second.iter().map(|job| job.1.clone()).collect::<Vec<_>>();
        drop(db);
        drop(shared);
        dispatch(json!({"op":"close","root":root})).unwrap();
        let shared = database(&root).unwrap();
        assert_eq!(
            scheduled(&shared.lock().unwrap(), "peer")
                .unwrap()
                .iter()
                .map(|job| job.1.clone())
                .collect::<Vec<_>>(),
            expected
        );
        drop(shared);
        crate::tests::cleanup(&root);
    }
}
