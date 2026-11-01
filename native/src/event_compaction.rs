use super::*;

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS compacted_events(id TEXT PRIMARY KEY,body_hash TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS compact_favorite_event ON favorites(event_id);
        CREATE INDEX IF NOT EXISTS compact_event_profile ON events(json_extract(body,'$.profile.id')) WHERE json_extract(body,'$.type')='profile';
        CREATE INDEX IF NOT EXISTS compact_event_conversation ON events(json_extract(body,'$.conversation.id')) WHERE json_extract(body,'$.type')='conversation';
        CREATE INDEX IF NOT EXISTS compact_event_target ON events(json_extract(body,'$.target')) WHERE json_extract(body,'$.type')='edit';
        CREATE INDEX IF NOT EXISTS compact_event_favorite ON events(json_extract(body,'$.favorite.id')) WHERE json_extract(body,'$.type') IN ('favorite','favorite_snapshot');")?;
    Ok(())
}

pub(super) fn metadata(db: &Connection, kind: &str, owner: &str) -> Result<usize> {
    let table = if kind == "profile" {
        "profiles"
    } else {
        "conversations"
    };
    let rows=db.prepare(&format!("SELECT e.id,e.body FROM events e WHERE json_extract(e.body,'$.type')='{kind}' AND json_extract(e.body,'$.{kind}.id')=? AND COALESCE(json_extract(e.body,'$.conversation.deleted'),0)!=1 AND e.id!=(SELECT event_id FROM {table} WHERE id=?)"))?
        .query_map(params![owner,owner],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
    compact_rows(db, rows)
}

pub(super) fn replay(db: &Connection, event_id: &str, body: &str) -> Result<bool> {
    let hash: Option<String> = db
        .query_row(
            "SELECT body_hash FROM compacted_events WHERE id=?",
            [event_id],
            |r| r.get(0),
        )
        .optional()?;
    if hash
        .as_ref()
        .is_some_and(|hash| *hash != digest(body.as_bytes()))
    {
        return Err(errors::api(
            409,
            "Change ID conflicts with compacted content",
        ));
    }
    Ok(hash.is_some())
}

fn compact_rows(db: &Connection, rows: Vec<(String, String)>) -> Result<usize> {
    let count = rows.len();
    for (id, body) in rows {
        db.execute(
            "INSERT OR IGNORE INTO compacted_events VALUES(?,?)",
            params![id, digest(body.as_bytes())],
        )?;
        db.execute("DELETE FROM seen WHERE event_id=?", [&id])?;
        db.execute("DELETE FROM transfer_jobs WHERE event_id=?", [&id])?;
        db.execute("DELETE FROM events WHERE id=?", [&id])?;
    }
    Ok(count)
}

pub(super) fn deleted_message(db: &Connection, target: &str) -> Result<usize> {
    // Keep the immutable deletion event. Peers can rebuild from the surviving
    // event stream; compact receipts still reject ID/content collisions.
    let rows=db.prepare("SELECT id,body FROM events WHERE (json_extract(body,'$.type')='item' AND json_extract(body,'$.item.id')=?1) OR (json_extract(body,'$.type')='edit' AND json_extract(body,'$.target')=?1)")?
        .query_map([target],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
    let mut count = compact_rows(db, rows)?;
    db.execute("DELETE FROM message_edit_parents WHERE event_id IN (SELECT event_id FROM message_edit_versions WHERE item_id=?)",[target])?;
    db.execute("DELETE FROM message_edit_heads WHERE item_id=?", [target])?;
    db.execute(
        "DELETE FROM message_edit_versions WHERE item_id=?",
        [target],
    )?;
    db.execute("DELETE FROM message_edits WHERE id=?", [target])?;
    if !db.query_row("SELECT EXISTS(SELECT 1 FROM trash WHERE id=?1) OR EXISTS(SELECT 1 FROM favorite_trash WHERE original_id=?1)",[target],|r|r.get::<_,bool>(0))? {
        let rows=db.prepare("SELECT e.id,e.body FROM events e WHERE json_extract(e.body,'$.type') IN ('favorite','favorite_snapshot') AND json_extract(e.body,'$.favorite.id')=? AND (json_type(e.body,'$.favorite.item') IS NOT NULL OR json_extract(e.body,'$.favorite.value')=1 OR NOT EXISTS(SELECT 1 FROM favorites f WHERE f.event_id=e.id))")?
            .query_map([target],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
        count+=compact_rows(db,rows)?;
        favorites::compact_deleted(db,target)?;
    }
    Ok(count)
}

pub(super) fn all(db: &Connection) -> Result<usize> {
    let targets = db
        .prepare("SELECT id FROM deleted")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut count = 0;
    for target in targets {
        count += deleted_message(db, &target)?;
    }
    let rows=db.prepare("SELECT e.id,e.body FROM events e WHERE (json_extract(e.body,'$.type')='profile' AND EXISTS(SELECT 1 FROM profiles p WHERE p.id=json_extract(e.body,'$.profile.id') AND p.event_id!=e.id)) OR (json_extract(e.body,'$.type')='conversation' AND COALESCE(json_extract(e.body,'$.conversation.deleted'),0)!=1 AND EXISTS(SELECT 1 FROM conversations c WHERE c.id=json_extract(e.body,'$.conversation.id') AND c.event_id!=e.id))")?
        .query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<std::result::Result<Vec<_>,_>>()?;
    count += compact_rows(db, rows)?;
    Ok(count)
}
