use super::*;

const CONVERSATION: &str = "COALESCE(json_extract(body,'$.conversationId'),'lanflow-self-chat')";

pub(super) fn schema(db: &Connection) -> Result<()> {
    let existed: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='history_totals')",
        [],
        |r| r.get(0),
    )?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS history_totals(conversation TEXT PRIMARY KEY,count INTEGER NOT NULL,maximum INTEGER NOT NULL);")?;
    if !existed {
        db.execute(&format!("INSERT INTO history_totals SELECT {CONVERSATION},COUNT(*),MAX(sequence) FROM items WHERE json_valid(body) GROUP BY {CONVERSATION}"), [])?;
    }
    let old = "COALESCE(json_extract(OLD.body,'$.conversationId'),'lanflow-self-chat')";
    let new = "COALESCE(json_extract(NEW.body,'$.conversationId'),'lanflow-self-chat')";
    let add = format!(
        "INSERT INTO history_totals VALUES({new},1,NEW.sequence) ON CONFLICT(conversation) DO UPDATE SET count=count+1,maximum=MAX(maximum,NEW.sequence);"
    );
    let remove = format!(
        "UPDATE history_totals SET count=count-1,maximum=CASE WHEN maximum=OLD.sequence THEN COALESCE((SELECT sequence FROM items INDEXED BY items_conversation_sequence WHERE json_valid(body) AND {CONVERSATION}={old} ORDER BY sequence DESC LIMIT 1),0) ELSE maximum END WHERE conversation={old};"
    );
    db.execute_batch(&format!("
        CREATE TRIGGER IF NOT EXISTS history_total_insert AFTER INSERT ON items WHEN json_valid(NEW.body) BEGIN {add} END;
        CREATE TRIGGER IF NOT EXISTS history_total_delete AFTER DELETE ON items WHEN json_valid(OLD.body) BEGIN {remove} END;
        CREATE TRIGGER IF NOT EXISTS history_total_update AFTER UPDATE ON items WHEN json_valid(OLD.body) AND json_valid(NEW.body) AND ({old}!={new} OR OLD.sequence!=NEW.sequence) BEGIN {remove} {add} END;
    "))?;
    Ok(())
}

pub(super) fn summaries(db: &Connection, after: Option<i64>) -> Result<Value> {
    let ids: Vec<String> = if let Some(after) = after {
        db.prepare("SELECT id FROM state_changes WHERE kind='history' AND revision>?")?
            .query_map([after], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?
    } else {
        db.prepare("SELECT conversation FROM history_totals WHERE count>0")?
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?
    };
    let mut result = serde_json::Map::new();
    let mut count = db.prepare("SELECT count,maximum FROM history_totals WHERE conversation=?")?;
    let mut latest = db.prepare(&format!("SELECT sequence,body FROM items INDEXED BY items_conversation_date WHERE json_valid(body) AND {CONVERSATION}=? ORDER BY julianday(json_extract(body,'$.createdAt')) DESC,id DESC LIMIT 1"))?;
    for id in ids {
        let (count, maximum): (i64, i64) = count
            .query_row([&id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?
            .unwrap_or((0, 0));
        let last: Option<(i64, String)> = latest
            .query_row([&id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        let last = last.map(|(sequence, body)| -> Result<Value> {
            Ok(json!({"sequence":sequence,"item":serde_json::from_str::<Value>(&body)?,"copies":[]}))
        }).transpose()?;
        result.insert(id, json!({"count":count,"maximum":maximum,"latest":last}));
    }
    Ok(Value::Object(result))
}

pub(super) fn records(db: &Connection, ids: &Value) -> Result<Value> {
    let ids = ids
        .as_array()
        .filter(|ids| ids.len() <= 100_000)
        .ok_or("Invalid history selection")?;
    let mut row = db.prepare("SELECT sequence,body FROM items WHERE id=?")?;
    let mut copies = db.prepare("SELECT endpoint FROM copies WHERE item_id=? ORDER BY endpoint")?;
    let mut records = Vec::new();
    for id in ids {
        let id = id
            .as_str()
            .filter(|id| valid_id(id))
            .ok_or("Invalid message ID")?;
        let Some((sequence, body)) = row
            .query_row([id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
            .optional()?
        else {
            continue;
        };
        let item: Value = serde_json::from_str(&body)?;
        let copies = copies
            .query_map([id], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        records.push(json!({"sequence":sequence,"blobPath":attachments::item_path(db,&item)?,"item":item,"copies":copies}));
    }
    Ok(json!(records))
}

pub(super) fn page(db: &Connection, request: &Value) -> Result<Value> {
    let conversation = id(request, "conversationId")?;
    let limit = request["limit"].as_i64().unwrap_or(200).clamp(1, 1000);
    let newer = request["newer"].as_bool().unwrap_or(false);
    let cursor = &request["cursor"];
    let at = cursor["at"].as_f64();
    let after_id = cursor["id"].as_str().unwrap_or("");
    let operator = if newer { ">" } else { "<" };
    let order = if newer { "ASC" } else { "DESC" };
    let boundary = if at.is_some() {
        format!(" AND (julianday(json_extract(body,'$.createdAt')),id) {operator} (?2,?3)")
    } else {
        String::new()
    };
    let sql = format!(
        "SELECT id,julianday(json_extract(body,'$.createdAt')) FROM items INDEXED BY items_conversation_date WHERE json_valid(body) AND {CONVERSATION}=?1{boundary} ORDER BY julianday(json_extract(body,'$.createdAt')) {order},id {order} LIMIT ?4"
    );
    let rows = db
        .prepare(&sql)?
        .query_map(params![conversation, at, after_id, limit + 1], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let more = rows.len() > limit as usize;
    let selected: Vec<Value> = rows
        .iter()
        .take(limit as usize)
        .map(|r| json!(r.0))
        .collect();
    let cursor = rows
        .iter()
        .take(limit as usize)
        .last()
        .map(|r| json!({"id":r.0,"at":r.1}));
    Ok(json!({"entries":records(db,&json!(selected))?,"cursor":cursor,"more":more}))
}

pub(super) fn position(db: &Connection, target: &str) -> Result<Value> {
    Ok(db
        .query_row(
            "SELECT julianday(json_extract(body,'$.createdAt')) FROM items WHERE id=?",
            [target],
            |r| r.get::<_, f64>(0),
        )
        .optional()?
        .map(|at| json!({"id":target,"at":at}))
        .unwrap_or(Value::Null))
}

pub(super) fn conversation_ids(db: &Connection, conversation: &str) -> Result<Vec<String>> {
    Ok(db
        .prepare(&format!(
            "SELECT id FROM items WHERE json_valid(body) AND {CONVERSATION}=? ORDER BY sequence,id"
        ))?
        .query_map([conversation], |r| r.get(0))?
        .collect::<std::result::Result<_, _>>()?)
}

pub(super) fn unread(db: &Connection, request: &Value) -> Result<Value> {
    let conversation = id(request, "conversationId")?;
    let through = request["through"].as_i64().unwrap_or(0);
    let origin = request["originId"].as_str().unwrap_or("");
    let count: i64 = db.query_row(&format!("SELECT count(*) FROM items INDEXED BY items_conversation_sequence WHERE json_valid(body) AND {CONVERSATION}=? AND sequence>? AND json_extract(body,'$.originId')!=?"),params![conversation,through,origin],|r|r.get(0))?;
    Ok(json!(count))
}
