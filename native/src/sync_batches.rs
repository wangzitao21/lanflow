use super::*;

pub(super) fn page(db: &Connection, after: i64, key: &str) -> Result<Value> {
    let rows = db.prepare("SELECT sequence,body FROM events e WHERE sequence>?1 AND NOT EXISTS(SELECT 1 FROM seen s WHERE s.event_id=e.id AND s.endpoint=?2) ORDER BY sequence LIMIT 51")?
        .query_map(params![after,key], |r| Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?)))?
        .collect::<std::result::Result<Vec<_>,_>>()?;
    let more = rows.len() > 50;
    let items = rows
        .iter()
        .take(50)
        .map(|(sequence, body)| -> Result<Value> {
            Ok(json!({"sequence":sequence,"event":serde_json::from_str::<Value>(body)?}))
        })
        .collect::<Result<Vec<_>>>()?;
    let cursor = if more {
        rows[49].0
    } else {
        db.query_row("SELECT COALESCE(MAX(sequence),0) FROM events", [], |r| {
            r.get(0)
        })?
    };
    Ok(json!({"items":items,"cursor":cursor,"more":more}))
}

pub(super) fn send(client: &Client, base: &str, events: &[Value], run: &Run) -> Result<()> {
    let mut offset = 0;
    while offset < events.len() {
        let mut end = offset;
        let mut bytes = 0;
        while end < events.len() && end - offset < 50 {
            let size = serde_json::to_vec(&events[end])?.len() + 1;
            if end > offset && bytes + size > 512 * 1024 {
                break;
            }
            bytes += size;
            end += 1;
        }
        let expected: Vec<_> = events[offset..end]
            .iter()
            .map(|event| event["id"].clone())
            .collect();
        let ack = response_json(
            run,
            client
                .post(format!("{base}/v3/changes/batch"))
                .timeout(Duration::from_secs(12))
                .json(&json!({"events": &events[offset..end]}))
                .send_checked(run)?,
        )?;
        if ack["ok"] != true || ack["ids"] != json!(expected) {
            return Err(errors::api_category(
                502,
                "protocol",
                "Missing batch acknowledgement",
            ));
        }
        offset = end;
    }
    Ok(())
}

pub(super) fn push_page(
    client: &Client,
    base: &str,
    key: &str,
    shared: &Database,
    run: &Run,
    records: &[Value],
    cursor: i64,
    favorites_supported: bool,
    snapshots_supported: bool,
    edits_supported: bool,
) -> Result<i64> {
    let mut outgoing = Vec::new();
    let mut received = Vec::new();
    {
        let mut db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        let tx = db.transaction()?;
        for record in records {
            let event = &record["event"];
            let event_id = string(event, "id")?;
            if (event["type"] == "favorite" && !favorites_supported)
                || (event["type"] == "favorite_snapshot" && !snapshots_supported)
                || (event["type"] == "edit" && !edits_supported)
            {
                continue;
            }
            let seen: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM seen WHERE event_id=? AND endpoint=?)",
                params![event_id, key],
                |r| r.get(0),
            )?;
            if !seen {
                if events::is_favorite(event) {
                    let retained = favorites::retained(&tx, event)?;
                    if retained
                        && event["favorite"]["value"] == true
                        && events::transfer_item(event).is_some_and(|item| item["kind"] != "text")
                    {
                        transfers::enqueue(&tx, key, "upload", record)?;
                        continue;
                    }
                    if retained
                        || event["favorite"]["value"] != true
                        || !event["favorite"]["item"].is_object()
                    {
                        outgoing.push(event.clone());
                    }
                } else if event["type"] == "item" {
                    let target = string(&event["item"], "id")?;
                    if deleted(&tx, target)? {
                        outgoing.push(json!({"id":digest(format!("delete:{target}").as_bytes()),"type":"delete","target":target}));
                    } else if event["item"]["kind"] != "text" {
                        transfers::enqueue(&tx, key, "upload", record)?;
                        continue;
                    } else {
                        outgoing.push(event.clone());
                    }
                } else {
                    outgoing.push(event.clone());
                }
            }
            received.push(event);
        }
        tx.commit()?;
    }
    send(client, base, &outgoing, run)?;
    let mut db = shared.lock().map_err(|_| "Database unavailable")?;
    let _mutation = run.mutation()?;
    let tx = db.transaction()?;
    for event in received {
        tx.execute(
            "INSERT OR IGNORE INTO seen VALUES(?,?)",
            params![string(event, "id")?, key],
        )?;
        if event["type"] == "item" || event["type"] == "edit" {
            message_edits::mark_copy(
                &tx,
                if event["type"] == "item" {
                    string(&event["item"], "id")?
                } else {
                    string(event, "target")?
                },
                key,
            )?;
        }
    }
    save_cursor(&tx, key, "pushed", cursor)?;
    tx.commit()?;
    Ok(cursor)
}
