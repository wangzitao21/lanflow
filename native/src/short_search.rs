use super::*;

// Hex-encoded one/two-character terms preserve literal substring semantics,
// including punctuation. Only non-ASCII terms need this supplementary index.
fn grams(body: &str) -> String {
    format!(
        "(WITH RECURSIVE source(text) AS (
        SELECT CAST(lower(COALESCE(json_extract({body},'$.text'),'')) AS BLOB) UNION ALL
        SELECT CAST(lower(COALESCE(json_extract({body},'$.name'),'')) AS BLOB)),
        segments(text,rest) AS (
          SELECT CAST(CASE WHEN instr(text,x'00')=0 THEN text ELSE substr(text,1,instr(text,x'00')-1) END AS TEXT),
            CASE WHEN instr(text,x'00')=0 THEN x'' ELSE substr(text,instr(text,x'00')+1) END FROM source
          UNION ALL
          SELECT CAST(CASE WHEN instr(rest,x'00')=0 THEN rest ELSE substr(rest,1,instr(rest,x'00')-1) END AS TEXT),
            CASE WHEN instr(rest,x'00')=0 THEN x'' ELSE substr(rest,instr(rest,x'00')+1) END FROM segments WHERE length(rest)>0),
        chars(text,n) AS (
          SELECT text,1 FROM segments WHERE length(CAST(text AS BLOB))!=length(text)
          UNION ALL SELECT text,n+1 FROM chars WHERE n<length(text)),
        grams(term) AS (
          SELECT 's'||hex(substr(text,n,1)) FROM chars WHERE unicode(substr(text,n,1))>127
          UNION SELECT 's'||hex(substr(text,n,2)) FROM chars WHERE n<length(text)
          AND (unicode(substr(text,n,1))>127 OR unicode(substr(text,n+1,1))>127))
        SELECT COALESCE(group_concat(term,' '),'') FROM grams)"
    )
}

pub(super) fn query(query: &str) -> Option<String> {
    let count = query.chars().count();
    (count > 0 && count < 3 && !query.is_ascii() && !query.chars().any(char::is_control))
        .then(|| format!("\"s{}\"", hex::encode(query.to_ascii_lowercase())))
}

pub(super) fn schema(db: &Connection) -> Result<()> {
    let dated: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('message_search_documents') WHERE name='created')",[],|r| r.get(0))?;
    if !dated {
        db.execute_batch("ALTER TABLE message_search_documents ADD COLUMN created REAL;
            UPDATE message_search_documents SET created=(SELECT julianday(json_extract(body,'$.createdAt')) FROM items WHERE id=item_id);")?;
    }
    let existing: Option<String> = db
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name='message_short_search'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let existed = existing
        .as_ref()
        .is_some_and(|sql| sql.contains("contentless_delete=1"));
    if existing.is_some() && !existed {
        db.execute_batch(
            "DROP TABLE message_short_search; DROP VIEW IF EXISTS message_short_content;",
        )?;
    }
    // Direct row deletion avoids regenerating every substring during bulk
    // deletion and needs no second stored copy of the text/term strings.
    db.execute_batch("CREATE VIRTUAL TABLE IF NOT EXISTS message_short_search USING fts5(grams,content='',contentless_delete=1,detail=none);")?;
    let new = grams("NEW.body");
    for (name, action, row) in [
        ("INSERT", "AFTER INSERT", "NEW"),
        ("DELETE", "AFTER DELETE", "OLD"),
        ("UPDATE_DELETE", "BEFORE UPDATE", "OLD"),
        ("UPDATE_INSERT", "AFTER UPDATE", "NEW"),
    ] {
        let commands = if row == "NEW" {
            format!("INSERT OR IGNORE INTO message_search_documents(item_id,created) VALUES(NEW.id,julianday(json_extract(NEW.body,'$.createdAt')));
                INSERT INTO message_search(rowid,text,name) SELECT document_id,COALESCE(json_extract(NEW.body,'$.text'),''),COALESCE(json_extract(NEW.body,'$.name'),'') FROM message_search_documents WHERE item_id=NEW.id;
                INSERT INTO message_short_search(rowid,grams) SELECT document_id,{new} FROM message_search_documents WHERE item_id=NEW.id;")
        } else {
            "INSERT INTO message_search(message_search,rowid,text,name) SELECT 'delete',document_id,COALESCE(json_extract(OLD.body,'$.text'),''),COALESCE(json_extract(OLD.body,'$.name'),'') FROM message_search_documents WHERE item_id=OLD.id;
                DELETE FROM message_short_search WHERE rowid IN (SELECT document_id FROM message_search_documents WHERE item_id=OLD.id);
                DELETE FROM message_search_documents WHERE item_id=OLD.id;".to_owned()
        };
        db.execute_batch(&format!("DROP TRIGGER IF EXISTS search_items_{name};
            CREATE TRIGGER search_items_{name} {action} ON items WHEN json_valid({row}.body) BEGIN {commands} END;"))?;
    }
    if !existed {
        let upper: i64 = db.query_row(
            "SELECT COALESCE(MAX(document_id),0) FROM message_search_documents",
            [],
            |r| r.get(0),
        )?;
        if upper > 0 {
            db.execute(
                "INSERT OR REPLACE INTO meta(key,body) VALUES('short_search_build',?)",
                [json!({"after":0,"upper":upper}).to_string()],
            )?;
        }
    }
    Ok(())
}

pub(super) fn pending(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key='short_search_build')",
        [],
        |r| r.get(0),
    )?)
}

// Upgrade existing histories after the chat is usable. Each committed slice
// is small, survives interruption and leaves regular reads/writes a turn.
pub(super) fn step(db: &mut Connection, limit: i64) -> Result<Value> {
    let tx = db.transaction()?;
    let state: Option<String> = tx
        .query_row(
            "SELECT body FROM meta WHERE key='short_search_build'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let Some(state) = state else {
        return Ok(json!({"done":true}));
    };
    let state: Value = serde_json::from_str(&state)?;
    let after = state["after"]
        .as_i64()
        .ok_or("Invalid search index position")?;
    let upper = state["upper"]
        .as_i64()
        .ok_or("Invalid search index boundary")?;
    let rows = tx.prepare("SELECT document_id FROM message_search_documents WHERE document_id>? AND document_id<=? ORDER BY document_id LIMIT ?")?
        .query_map(params![after,upper,limit.clamp(1,256)], |r|r.get::<_,i64>(0))?.collect::<std::result::Result<Vec<_>,_>>()?;
    let next = rows.last().copied().unwrap_or(upper);
    let terms = grams("i.body");
    tx.execute(&format!("INSERT OR REPLACE INTO message_short_search(rowid,grams) SELECT d.document_id,{terms} FROM message_search_documents d JOIN items i ON i.id=d.item_id WHERE d.document_id>? AND d.document_id<=? AND json_valid(i.body)"),params![after,next])?;
    let done = next >= upper || rows.len() < limit.clamp(1, 256) as usize;
    if done {
        tx.execute("DELETE FROM meta WHERE key='short_search_build'", [])?;
    } else {
        tx.execute(
            "UPDATE meta SET body=? WHERE key='short_search_build'",
            [json!({"after":next,"upper":upper}).to_string()],
        )?;
    }
    tx.commit()?;
    Ok(json!({"done":done,"after":next,"upper":upper}))
}
