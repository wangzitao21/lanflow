use super::*;

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
    let mut statement = db.prepare("SELECT e.sequence,e.body FROM favorites f JOIN events e ON e.id=f.event_id WHERE json_extract(f.body,'$.item.kind')!='text' AND (json_extract(f.body,'$.value')=1 OR EXISTS(SELECT 1 FROM favorite_trash t WHERE t.original_id=f.id))")?;
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
        "state!='completed'",
        "sequence,endpoint,direction,event_id",
        -1,
        0,
    )
}

pub(super) fn page(db: &Connection, request: &Value) -> Result<Value> {
    let filter = match request["scope"].as_str().unwrap_or("completed") {
        "active" => "state!='completed'",
        "completed" => "state='completed'",
        "all" => "1",
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
        _ => return Err("Unknown transfer action".into()),
    };
    let changed = db.execute(
        "UPDATE transfer_jobs SET state=?,error=NULL,error_category=NULL,retry_after=0,failures=0 WHERE endpoint=? AND direction=? AND event_id=? AND state!='completed'",
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
