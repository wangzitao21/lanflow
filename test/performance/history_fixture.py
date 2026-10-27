import datetime
import hashlib
import json
import os
import pathlib
import sqlite3
import sys


root = pathlib.Path(sys.argv[1]).resolve()
count = int(sys.argv[2])
if not root.name.startswith("lanflow-history-") or count not in (10_000, 100_000):
    raise ValueError("Only isolated history benchmark fixtures are supported")
database = root / "system" / "messages.sqlite3"
if not database.is_file():
    raise FileNotFoundError("Initialize the real application schema first")
connection = sqlite3.connect(database)
def short_grams(body):
    value = json.loads(body)
    terms = set()
    for field in ("text", "name"):
        text = value.get(field, "").translate(str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"))
        for segment in text.split("\0"):
            for i, char in enumerate(segment):
                if ord(char) > 127:
                    terms.add("s" + char.encode().hex())
                if i and (ord(segment[i - 1]) > 127 or ord(char) > 127):
                    terms.add("s" + segment[i - 1:i + 1].encode().hex())
    return " ".join(sorted(terms))

connection.create_function("lanflow_short_grams", 1, short_grams, deterministic=True)
if connection.execute("SELECT count(*) FROM items").fetchone()[0]:
    raise ValueError("The benchmark fixture must start with an empty database")


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


base = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
sequence = 0
seed_copies = os.environ.get("LANFLOW_BENCH_COPIES") == "1"
with connection:
    for group in range(1, 16):
        conversation = {
            "id": f"conversation-bench-{group:04}",
            "name": f"Bench conversation {group}",
            "revision": 1,
        }
        event_id = f"conversation-event-{group:08}"
        event = {"id": event_id, "type": "conversation", "conversation": conversation}
        sequence += 1
        connection.execute("INSERT INTO events(sequence,id,body) VALUES(?,?,?)", (sequence, event_id, encode(event)))
        connection.execute("INSERT INTO conversations(id,revision,event_id,body) VALUES(?,?,?,?)", (conversation["id"], 1, event_id, encode(conversation)))
    for index in range(count):
        # Deliberately mix chronological order and include equal timestamps;
        # ascending SQL insertion order must not make sorting trivially cheap.
        created = base + datetime.timedelta(seconds=((index * 7919) % count) // 3)
        item = {
            "id": f"message-bench-{index:016}",
            "originId": f"device-bench-{index % 2:08}",
            "originName": "Bench desktop" if index % 2 == 0 else "Bench mobile",
            "createdAt": created.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "kind": "text",
            "text": f"Message {index} {'needle' if index % 97 == 0 else 'regular'} — 说明记录 " + "payload segment " * 8,
            "name": "",
            "size": 0,
            "sha256": "",
        }
        if index % 16:
            item["conversationId"] = f"conversation-bench-{index % 16:04}"
        event_id = hashlib.sha256(f"item:{item['id']}".encode()).hexdigest()
        event = {"id": event_id, "type": "item", "item": item}
        sequence += 1
        connection.execute("INSERT INTO events(sequence,id,body) VALUES(?,?,?)", (sequence, event_id, encode(event)))
        connection.execute("INSERT INTO items(id,sequence,body) VALUES(?,?,?)", (item["id"], sequence, encode(item)))
        if seed_copies:
            connection.execute("INSERT INTO copies(item_id,endpoint) VALUES(?,?)", (item["id"], "device:seeded-history-peer"))
connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
actual = connection.execute("SELECT count(*) FROM items").fetchone()[0]
matches = connection.execute("SELECT count(*) FROM items WHERE instr(lower(json_extract(body,'$.text')),'needle')>0").fetchone()[0]
filter_sql = "json_valid(i.body) AND (instr(lower(json_extract(i.body,'$.text')),lower(?))>0 OR instr(lower(json_extract(i.body,'$.name')),lower(?))>0)"
plans = {}
for name, extra, arguments in [
    ("global", "", ("needle", "needle")),
    ("conversation", " AND COALESCE(json_extract(i.body,'$.conversationId'),'lanflow-self-chat')=?", ("needle", "needle", "lanflow-self-chat")),
    ("conversationAndKind", " AND COALESCE(json_extract(i.body,'$.conversationId'),'lanflow-self-chat')=? AND json_extract(i.body,'$.kind')=?", ("needle", "needle", "lanflow-self-chat", "text")),
]:
    where = filter_sql + extra
    plans[name] = {
        "count": [row[3] for row in connection.execute("EXPLAIN QUERY PLAN SELECT count(*) FROM items i WHERE " + where, arguments)],
        "page": [row[3] for row in connection.execute("EXPLAIN QUERY PLAN SELECT i.id FROM items i WHERE " + where + " ORDER BY julianday(json_extract(i.body,'$.createdAt')) DESC,i.id DESC LIMIT 50 OFFSET 0", arguments)],
    }
has_candidates = connection.execute("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='message_search')").fetchone()[0]
if has_candidates:
    candidate_filter = "message_search MATCH ? AND " + filter_sql
    candidate_source = "message_search CROSS JOIN message_search_documents d ON d.document_id=message_search.rowid CROSS JOIN items i ON i.id=d.item_id"
    literal = '"nee" AND "eed" AND "edl" AND "dle"'
    plans["candidateIndexedGlobal"] = [row[3] for row in connection.execute(
        "EXPLAIN QUERY PLAN WITH matches AS MATERIALIZED (SELECT i.id,julianday(json_extract(i.body,'$.createdAt')) AS created FROM " + candidate_source + " WHERE " + candidate_filter + ") SELECT id,COUNT(*) OVER() FROM matches ORDER BY created DESC,id DESC LIMIT 50 OFFSET 0", (literal, "needle", "needle"))]
connection.close()
if integrity != "ok" or actual != count:
    raise RuntimeError("The fixture did not pass SQLite validation")
print(json.dumps({"messages": actual, "searchMatches": matches, "seededCopies": count if seed_copies else 0, "integrity": integrity, "databaseBytes": database.stat().st_size, "sqliteQueryPlans": plans}))
