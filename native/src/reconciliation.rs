use super::*;

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS deletion_clock(revision INTEGER NOT NULL,count INTEGER NOT NULL);
        INSERT INTO deletion_clock SELECT 0,(SELECT COUNT(*) FROM deleted) WHERE NOT EXISTS(SELECT 1 FROM deletion_clock);
        CREATE TRIGGER IF NOT EXISTS deletion_clock_insert AFTER INSERT ON deleted BEGIN UPDATE deletion_clock SET revision=revision+1,count=count+1; END;
        CREATE TRIGGER IF NOT EXISTS deletion_clock_delete AFTER DELETE ON deleted BEGIN UPDATE deletion_clock SET revision=revision+1,count=count-1; END;
        CREATE TRIGGER IF NOT EXISTS deletion_clock_update AFTER UPDATE ON deleted BEGIN UPDATE deletion_clock SET revision=revision+1; END;")?;
    db.execute(
        "INSERT OR IGNORE INTO meta(key,body) VALUES('sync_epoch',?)",
        [uuid::Uuid::new_v4().simple().to_string()],
    )?;
    for (column, definition) in [
        ("remote_epoch", "TEXT NOT NULL DEFAULT ''"),
        ("pulled_id", "TEXT NOT NULL DEFAULT ''"),
        ("remote_deletions", "INTEGER NOT NULL DEFAULT 0"),
    ] {
        let exists: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('cursors') WHERE name=?)",
            [column],
            |r| r.get(0),
        )?;
        if !exists {
            db.execute(
                &format!("ALTER TABLE cursors ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    db.execute_batch("CREATE INDEX IF NOT EXISTS deletion_events ON events(json_extract(body,'$.target'),sequence) WHERE json_extract(body,'$.type')='delete';
        CREATE INDEX IF NOT EXISTS deletion_event_sequence ON events(sequence) WHERE json_extract(body,'$.type')='delete';")?;
    Ok(())
}

pub(super) fn epoch(db: &Connection) -> Result<String> {
    Ok(
        db.query_row("SELECT body FROM meta WHERE key='sync_epoch'", [], |r| {
            r.get(0)
        })?,
    )
}

pub(super) fn deletion_state(db: &Connection) -> Result<Value> {
    let (revision, count): (i64, i64) =
        db.query_row("SELECT revision,count FROM deletion_clock", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?;
    let cursor: i64 = db.query_row("SELECT COALESCE(MAX(rowid),0) FROM deleted", [], |r| {
        r.get(0)
    })?;
    let cached: Option<String> = db
        .query_row(
            "SELECT body FROM meta WHERE key='deletion_state'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(cached) = cached {
        if let Ok(value) = serde_json::from_str::<Value>(&cached) {
            if value["revision"] == revision
                && value["count"] == count
                && value["cursor"] == cursor
                && value["hash"].as_str().is_some_and(valid_digest)
            {
                return Ok(value);
            }
        }
    }
    let mut hash = Sha256::new();
    for id in db
        .prepare("SELECT id FROM deleted ORDER BY id")?
        .query_map([], |r| r.get::<_, String>(0))?
    {
        hash.update(id?.as_bytes());
        hash.update(b"\0");
    }
    let value = json!({"revision":revision,"count":count,"cursor":cursor,"hash":hex::encode(hash.finalize())});
    db.execute("INSERT INTO meta VALUES('deletion_state',?) ON CONFLICT(key) DO UPDATE SET body=excluded.body",[value.to_string()])?;
    Ok(value)
}

pub(super) fn deletion_page(db: &Connection, after: i64) -> Result<Value> {
    if after < 0 {
        return Err("Invalid deletion cursor".into());
    }
    let rows = db
        .prepare("SELECT rowid,id FROM deleted WHERE rowid>? ORDER BY rowid LIMIT 501")?
        .query_map([after], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let items = rows
        .iter()
        .take(500)
        .map(|(sequence, id)| json!({"sequence":sequence,"id":id}))
        .collect::<Vec<_>>();
    let cursor = rows.iter().take(500).last().map_or(after, |row| row.0);
    Ok(
        json!({"items":items,"cursor":cursor,"more":rows.len()>500,"historyEpoch":epoch(db)?,"state":deletion_state(db)?}),
    )
}

pub(super) fn annotate_page(db: &Connection, after: i64, page: &mut Value) -> Result<()> {
    page["historyEpoch"] = json!(epoch(db)?);
    page["head"] = json!(db.query_row(
        "SELECT COALESCE(MAX(sequence),0) FROM events",
        [],
        |r| r.get::<_, i64>(0)
    )?);
    page["afterId"] = json!(
        db.query_row("SELECT id FROM events WHERE sequence=?", [after], |r| {
            r.get::<_, String>(0)
        })
        .optional()?
    );
    page["deletionState"] = deletion_state(db)?;
    Ok(())
}
