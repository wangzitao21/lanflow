use super::*;

pub(super) fn identity(directory: &Path) -> Result<Value> {
    fs::create_dir_all(directory)?;
    let path = directory.join("identity.json");
    if path.exists() {
        return Ok(serde_json::from_slice(&fs::read(path)?)?);
    }
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["lanflow.local".to_owned()])?;
    let value = json!({"certificate":cert.pem(),"privateKey":signing_key.serialize_pem()});
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    file.write_all(serde_json::to_string(&value)?.as_bytes())?;
    file.sync_all()?;
    Ok(value)
}

pub(super) fn dispatch(request: Value) -> Result<Value> {
    let op = string(&request, "op")?;
    let root = Path::new(request["root"].as_str().unwrap_or(""));
    if op == "identity" {
        return identity(root);
    }
    if op == "hash" {
        return Ok(json!(hash_file(Path::new(string(&request, "path")?))?));
    }
    if op == "backup_database" {
        return backup::database(root, Path::new(string(&request, "path")?));
    }
    if op == "verify_database" {
        return backup::verify(root);
    }
    if op == "import_file" {
        let shared = database(root)?;
        let mut imported = import_file(root, Path::new(string(&request, "path")?))?;
        if request["name"].is_string() {
            imported["path"] = json!(attachments::register(
                root,
                &shared,
                &json!({
                    "kind":request["kind"],"name":request["name"],"sha256":imported["sha256"],"size":imported["size"]
                })
            )?);
        }
        return Ok(imported);
    }
    if op == "prepare_storage" {
        layout::prepare(root)?;
        return Ok(json!(true));
    }
    if op == "prepare_device_storage" {
        layout::prepare_device(root)?;
        return Ok(json!(true));
    }
    if op == "maintenance_cleanup" {
        return maintenance_gc::cleanup(
            root,
            request["clearTrash"]
                .as_bool()
                .ok_or("Invalid cleanup action")?,
        );
    }
    if op.starts_with("blob_") {
        return blobs::dispatch(root, &request);
    }
    if op == "open" {
        return initialize(root);
    }
    if op == "open_paged" {
        return storage::initialize_history(root, false);
    }
    if op == "sync" {
        return sync::synchronize(
            root,
            &request["endpoint"],
            request["knownRevision"].as_i64(),
            request["runId"].as_str(),
        );
    }
    if op == "begin_sync" {
        return Ok(json!(sync_control::begin(root, string(&request, "key")?)?));
    }
    if op == "cancel_sync" {
        sync_control::cancel(root, request["key"].as_str());
        sync::forget_clients(root, request["key"].as_str());
        return Ok(json!(true));
    }
    if op == "storage_stats" || op == "clear_preview_cache" {
        return maintenance::storage(root, op == "clear_preview_cache");
    }
    if op == "close" {
        sync_control::cancel(root, None);
        sync::forget_clients(root, None);
        blobs::abort_root(root);
        attachments::forget(root);
        search::forget(root);
        if let Some(all) = DATABASES.get() {
            all.lock().map_err(|_| "Database unavailable")?.remove(root);
        }
        return Ok(json!(true));
    }
    let shared = database(root)?;
    if op == "search_messages" {
        // WAL readers can scan history while drafts and incoming messages keep
        // committing through the normal connection.
        let db = Connection::open_with_flags(
            layout::database(root),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        db.busy_timeout(Duration::from_secs(15))?;
        let snapshot = db.unchecked_transaction()?;
        return search::messages(root, &snapshot, &request);
    }
    // File preparation can take minutes for very large attachments. Keep the
    // database available to message actions, drafts and transfer controls.
    let mut draft_paths = serde_json::Map::new();
    let mut attachment_changed = false;
    if op == "save_meta" {
        for images in request["value"]["imageDrafts"]
            .as_object()
            .into_iter()
            .flat_map(|v| v.values())
        {
            for item in images.as_array().into_iter().flatten() {
                if let Some(path) = attachments::register(root, &shared, item)? {
                    draft_paths.insert(string(item, "sha256")?.to_owned(), json!(path));
                }
            }
        }
    } else if let Some(item) = if op == "add" {
        Some(&request["item"])
    } else if op == "apply" {
        events::transfer_item(&request["event"])
    } else {
        None
    } {
        validate_item(item)?;
        attachment_changed = attachments::register_changed(root, &shared, item)?.1;
    }
    let mut db = shared.lock().map_err(|_| "Database unavailable")?;
    match op {
        "search_index_step" => short_search::step(&mut db, request["limit"].as_i64().unwrap_or(128)),
        "history_page" => history::page(&db, &request),
        "history_records" => history::records(&db, &request["ids"]),
        "history_position" => history::position(&db, &id(&request,"id")?),
        "history_ids" => Ok(json!(history::conversation_ids(&db, &id(&request,"conversationId")?)?)),
        "history_unread" => history::unread(&db,&request),
        "delete_conversation" => {
            let conversation = id(&request,"conversationId")?;
            let maximum: i64 = db.query_row("SELECT COALESCE(MAX(sequence),0) FROM items WHERE COALESCE(json_extract(body,'$.conversationId'),'lanflow-self-chat')=?", [&conversation], |r| r.get(0))?;
            let ids = history::conversation_ids(&db,&conversation)?;
            for chunk in ids.chunks(100_000) {
                events::delete_many(root,&mut db,&json!(chunk))?;
            }
            let mut state = snapshot_since(&db,request["knownRevision"].as_i64())?;
            state["through"] = json!(maximum);
            Ok(state)
        }
        "bootstrap_entries" => storage::bootstrap_entries(&db, &request),
        "preferences" => {
            // The first frame only needs these two fields, not the full history.
            let body: Option<String> = db
                .query_row("SELECT body FROM meta WHERE key='settings'", [], |r| r.get(0))
                .optional()?;
            let value: Value = serde_json::from_str(body.as_deref().unwrap_or("{}"))?;
            Ok(json!({"appearance":value["appearance"],"composerFraction":value["composerFraction"],"language":value["language"]}))
        }
        "snapshot" => snapshot_since(&db, request["knownRevision"].as_i64()),
        "sync_pending" => {
            let key = string(&request, "key")?;
            let pending: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM events WHERE sequence>COALESCE((SELECT pushed FROM cursors WHERE endpoint=?1),0) AND NOT EXISTS(SELECT 1 FROM seen WHERE seen.event_id=events.id AND endpoint=?1)) OR EXISTS(SELECT 1 FROM transfer_jobs WHERE endpoint=?1 AND state IN ('queued','failed'))",
                [key], |r| r.get(0),
            )?;
            Ok(json!(pending))
        }
        "items_page" => storage::items_page(&db, request["after"].as_i64().ok_or("Invalid cursor")?),
        "revision" => Ok(json!(db.query_row(
            "SELECT value FROM revision",
            [],
            |r| r.get::<_, i64>(0)
        )?)),
        "save_meta" => {
            db.execute("INSERT INTO meta VALUES('settings',?) ON CONFLICT(key) DO UPDATE SET body=excluded.body",[serde_json::to_string(&request["value"])?])?;
            Ok(Value::Object(draft_paths))
        }
        "add" => {
            apply(
                root,
                &mut db,
                &item_event(&request["item"]),
                request["source"].as_str(),
            )?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "delete" => {
            let target = id(&request, "id")?;
            events::delete_many(root,&mut db,&json!([target]))?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "trash" => maintenance::trash(root, &db),
        "trash_page" => maintenance::trash_page(root, &db, &request),
        "set_favorites" => {
            events::set_favorites(root, &mut db, &request["ids"], request["value"].as_bool().ok_or("Invalid favorite state")?)?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "delete_favorites" => {
            favorites::remove(root,&mut db,&request["ids"])?;
            snapshot_since(&db,request["knownRevision"].as_i64())
        }
        "restore_favorites" => {
            favorites::restore(root,&mut db,&request["ids"])?;
            snapshot_since(&db,request["knownRevision"].as_i64())
        }
        "delete_many" => {
            events::delete_many(root, &mut db, &request["ids"])?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "restore" => {
            if request["source"] == "favorite" {
                favorites::restore(root,&mut db,&json!([id(&request,"id")?]))?;
            } else {
                maintenance::restore(root, &mut db, &id(&request, "id")?)?;
            }
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "transfers" => transfers::list(&db),
        "transfers_page" => transfers::page(&db, &request),
        "transfer_action" => transfers::action(&db, &request),
        "transfer_blocked" => Ok(json!(db.query_row(
            "SELECT EXISTS(SELECT 1 FROM transfer_jobs WHERE endpoint=? AND state IN ('paused','cancelled') AND COALESCE(json_extract(body,'$.item.sha256'),json_extract(body,'$.favorite.item.sha256'))=?)",
            params![string(&request,"endpoint")?,string(&request,"digest")?], |r| r.get::<_,bool>(0)
        )?)),
        "conversation" => {
            let owner = id(&request, "id")?;
            let previous: Option<i64> = db
                .query_row(
                    "SELECT revision FROM conversations WHERE id=?",
                    [&owner],
                    |r| r.get(0),
                )
                .optional()?;
            let revision = Utc::now().timestamp_micros().max(previous.unwrap_or(0) + 1);
            let conversation =
                json!({"id":owner,"name":string(&request,"name")?,"revision":revision});
            let event = json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"conversation","conversation":conversation});
            apply(root, &mut db, &event, None)?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "profile" => {
            let owner = id(&request, "id")?;
            let previous: Option<String> = db
                .query_row("SELECT body FROM profiles WHERE id=?", [&owner], |r| {
                    r.get(0)
                })
                .optional()?;
            let previous: Value = serde_json::from_str(previous.as_deref().unwrap_or("{}"))?;
            let revision = Utc::now()
                .timestamp_micros()
                .max(previous["revision"].as_i64().unwrap_or(0) + 1);
            let avatar = request["avatar"]
                .as_str()
                .or_else(|| previous["avatar"].as_str())
                .unwrap_or("");
            let profile = json!({"id":owner,"name":string(&request,"name")?,"avatar":avatar,"revision":revision});
            let event = json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"profile","profile":profile});
            apply(root, &mut db, &event, None)?;
            snapshot_since(&db, request["knownRevision"].as_i64())
        }
        "page" => storage::requested_page(&db, request["after"].as_i64().unwrap_or(0), &request["capabilities"]),
        "apply" => {
            let changed = apply(root, &mut db, &request["event"], request["source"].as_str())? || attachment_changed;
            let mut state = snapshot_since(&db, request["knownRevision"].as_i64())?;
            state["ok"] = json!(true);
            state["changed"] = json!(changed);
            Ok(state)
        }
        _ => Err("Unknown native operation".into()),
    }
}
