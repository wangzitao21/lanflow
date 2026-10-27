use super::*;
use std::io::{BufRead, BufReader};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

#[derive(Clone)]
struct Request {
    method: String,
    path: String,
    body: Value,
    authorization: String,
}
struct Reply {
    status: u16,
    body: Value,
}
impl Reply {
    fn ok(body: Value) -> Self {
        Self { status: 200, body }
    }
}
struct Peer {
    address: std::net::SocketAddr,
    endpoint: Value,
    stop: Arc<AtomicBool>,
    connections: Arc<AtomicUsize>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Peer {
    fn start(handler: impl Fn(Request) -> Reply + Send + Sync + 'static) -> Self {
        let certified =
            rcgen::generate_simple_self_signed(vec!["lanflow.local".to_owned()]).unwrap();
        let certificate = certified.cert.der().clone();
        let fingerprint = digest(certificate.as_ref());
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
            rustls::pki_types::PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der()),
        );
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![certificate], key)
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let connections = Arc::new(AtomicUsize::new(0));
        let accepted = connections.clone();
        let worker = std::thread::spawn(move || {
            let config = Arc::new(config);
            while !stopping.load(Ordering::Acquire) {
                let Ok((socket, _)) = listener.accept() else {
                    break;
                };
                if stopping.load(Ordering::Acquire) {
                    break;
                }
                accepted.fetch_add(1, Ordering::SeqCst);
                socket
                    .set_read_timeout(Some(Duration::from_millis(700)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let stream = rustls::StreamOwned::new(
                    rustls::ServerConnection::new(config.clone()).unwrap(),
                    socket,
                );
                let mut stream = BufReader::new(stream);
                loop {
                    let mut first = String::new();
                    if stream.read_line(&mut first).unwrap_or(0) == 0 {
                        break;
                    }
                    let mut parts = first.split_whitespace();
                    let method = parts.next().unwrap_or("").to_owned();
                    let path = parts.next().unwrap_or("").to_owned();
                    let mut length = 0;
                    let mut authorization = String::new();
                    loop {
                        let mut header = String::new();
                        if stream.read_line(&mut header).unwrap_or(0) == 0 {
                            break;
                        }
                        if header == "\r\n" {
                            break;
                        }
                        if let Some((name, value)) = header.trim().split_once(':') {
                            if name.eq_ignore_ascii_case("content-length") {
                                length = value.trim().parse().unwrap();
                            }
                            if name.eq_ignore_ascii_case("authorization") {
                                authorization = value.trim().to_owned();
                            }
                        }
                    }
                    let mut body = vec![0; length];
                    if stream.read_exact(&mut body).is_err() {
                        break;
                    }
                    let response = handler(Request {
                        method: method.clone(),
                        path,
                        body: serde_json::from_slice(&body).unwrap_or(Value::Null),
                        authorization,
                    });
                    let bytes = serde_json::to_vec(&response.body).unwrap();
                    let headers = format!(
                        "HTTP/1.1 {} OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n\r\n",
                        response.status,
                        bytes.len()
                    );
                    if stream.get_mut().write_all(headers.as_bytes()).is_err() {
                        break;
                    }
                    if method != "HEAD" && stream.get_mut().write_all(&bytes).is_err() {
                        break;
                    }
                    if stream.get_mut().flush().is_err() {
                        break;
                    }
                    if stopping.load(Ordering::Acquire) {
                        break;
                    }
                }
            }
        });
        Self {
            address,
            endpoint: json!({"key":"device:test-peer","url":format!("https://{address}"),"fingerprint":fingerprint,"token":"first-token"}),
            stop,
            connections,
            worker: Some(worker),
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.address);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}
fn note(index: usize) -> Value {
    json!({"id":format!("message-{index:016}"),"originId":"device-test-origin","originName":"Desktop","createdAt":"2026-10-22T00:00:00Z","kind":"text","text":format!("Message {index}"),"name":"","size":0,"sha256":""})
}
fn empty_page(capable: bool) -> Value {
    json!({"items":[],"cursor":0,"more":false,"protocol":3,"capabilities":if capable { vec!["favorites"] } else { Vec::<&str>::new() }})
}

fn database_peer(root: &Path) -> Peer {
    let root = root.to_owned();
    Peer::start(move |request| {
        let result = (|| -> Result<Value> {
            let shared=database(&root)?;
            let mut db=shared.lock().unwrap();
            let uri=reqwest::Url::parse(&format!("https://localhost{}",request.path))?;
            let after=uri.query_pairs().find(|(key,_)| key=="after").map(|(_,value)| value.parse::<i64>()).transpose()?.unwrap_or(0);
            if request.method=="POST" {
                if uri.path()=="/v3/changes/batch" {
                    events::apply_batch(&root,&mut db,&request.body["events"],Some("device:client"))?;
                    return Ok(json!({"ok":true,"ids":request.body["events"].as_array().unwrap().iter().map(|e|e["id"].clone()).collect::<Vec<_>>()}));
                }
                apply(&root,&mut db,&request.body,Some("device:client"))?;
                Ok(json!({"ok":true}))
            } else if uri.path()=="/v3/deletions" {
                reconciliation::deletion_page(&db,after)
            } else {
                storage::page(&db,after)
            }
        })();
        match result { Ok(value)=>Reply::ok(value), Err(error)=>Reply{status:errors::status(error.as_ref()),body:json!({"error":error.to_string()})} }
    })
}

#[test]
fn a_batch_without_matching_acknowledgements_never_advances_the_sender() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":note(9191)})).unwrap();
    let peer = Peer::start(|request| {
        if request.method == "POST" { Reply::ok(json!({"ok":true,"ids":[]})) }
        else { Reply::ok(json!({"items":[],"cursor":0,"more":false,"protocol":3,"capabilities":["changeBatches"]})) }
    });
    let error = sync::synchronize(&root,&peer.endpoint,None,None).unwrap_err();
    assert_eq!(errors::category(error.as_ref()),"protocol");
    let shared = database(&root).unwrap();
    let db = shared.lock().unwrap();
    assert_eq!(db.query_row("SELECT pushed FROM cursors",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    assert_eq!(db.query_row("SELECT COUNT(*) FROM copies",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    drop(db); drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn deletion_inventory_repairs_invalid_cursors_and_removes_favorites() {
    let source=crate::tests::root(); let receiver=crate::tests::root();
    let item=note(2200);
    dispatch(json!({"op":"add","root":source,"item":item})).unwrap();
    dispatch(json!({"op":"set_favorites","root":source,"ids":[item["id"]],"value":true})).unwrap();
    let peer=database_peer(&source);
    sync::synchronize(&receiver,&peer.endpoint,None,None).unwrap();
    { let shared=database(&receiver).unwrap(); let db=shared.lock().unwrap();
      db.execute("UPDATE cursors SET pulled=99999,pushed=99999,pulled_id='stale-checkpoint'",[]).unwrap(); }
    dispatch(json!({"op":"delete","root":source,"id":item["id"]})).unwrap();
    let result=sync::synchronize(&receiver,&peer.endpoint,None,None).unwrap();
    assert!(result["entries"].as_array().unwrap().is_empty());
    assert_eq!(result["favorites"][item["id"].as_str().unwrap()]["value"],false);
    assert!(initialize(&source).unwrap()["entries"].as_array().unwrap().is_empty());
    crate::tests::cleanup(&receiver); crate::tests::cleanup(&source);
}

#[test]
fn deleted_messages_cannot_return_when_a_peer_restores_a_pre_deletion_backup() {
    let source=crate::tests::root(); let receiver=crate::tests::root();
    let item=note(2201);
    dispatch(json!({"op":"add","root":source,"item":item})).unwrap();
    let backup=source.join("before-delete.sqlite3");
    dispatch(json!({"op":"backup_database","root":source,"path":backup})).unwrap();
    let peer=database_peer(&source);
    sync::synchronize(&receiver,&peer.endpoint,None,None).unwrap();
    dispatch(json!({"op":"delete","root":receiver,"id":item["id"]})).unwrap();
    sync::synchronize(&receiver,&peer.endpoint,None,None).unwrap();
    let epoch={let db=database(&source).unwrap(); reconciliation::epoch(&db.lock().unwrap()).unwrap()};
    dispatch(json!({"op":"close","root":source})).unwrap();
    fs::copy(&backup,layout::database(&source)).unwrap();
    assert_eq!(initialize(&source).unwrap()["entries"].as_array().unwrap().len(),1);
    { let db=database(&source).unwrap(); assert_eq!(reconciliation::epoch(&db.lock().unwrap()).unwrap(),epoch); }
    // Keep the send receipts and remove the normal receive checkpoint: deletion
    // reconciliation itself must repair the restored copy, independently.
    { let db=database(&receiver).unwrap(); db.lock().unwrap().execute("UPDATE cursors SET pulled=0,pulled_id=''",[]).unwrap(); }
    sync::synchronize(&receiver,&peer.endpoint,None,None).unwrap();
    assert!(initialize(&source).unwrap()["entries"].as_array().unwrap().is_empty());
    assert!(initialize(&receiver).unwrap()["entries"].as_array().unwrap().is_empty());
    crate::tests::cleanup(&receiver); crate::tests::cleanup(&source);
}

#[test]
fn metadata_notifications_preempt_only_the_requested_file_run() {
    let root=crate::tests::root();
    initialize(&root).unwrap();
    let first=sync_control::begin(&root,"device:peer").unwrap();
    let run=sync_control::Run::acquire(&root,"device:peer",&first).unwrap();
    assert!(!sync_control::interrupt_files(&root,"device:peer",&first));
    assert!(run.check().is_ok());
    assert!(run.file_phase().is_err());
    drop(run);
    let second=sync_control::begin(&root,"device:peer").unwrap();
    let run=sync_control::Run::acquire(&root,"device:peer",&second).unwrap();
    let phase=run.file_phase().unwrap();
    assert!(!sync_control::interrupt_files(&root,"device:peer",&first));
    assert!(run.check().is_ok());
    assert!(sync_control::interrupt_files(&root,"device:peer",&second));
    assert!(run.check().is_err());
    drop(phase); drop(run);
    crate::tests::cleanup(&root);
}

#[test]
fn successful_http_without_a_change_acknowledgement_never_marks_a_copy() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":note(901)})).unwrap();
    let peer = Peer::start(|request| {
        Reply::ok(if request.method == "GET" {
            empty_page(true)
        } else {
            json!({"error":"not committed"})
        })
    });
    assert!(sync::synchronize(&root, &peer.endpoint, None, None).is_err());
    let shared = database(&root).unwrap();
    let db = shared.lock().unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM copies", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.query_row("SELECT pushed FROM cursors", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(db);
    crate::tests::cleanup(&root);
}

#[test]
fn remote_attachment_storage_failure_never_blames_local_storage() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let mut item = note(903);
    item["kind"] = json!("file");
    item["name"] = json!("pending.bin");
    item["sha256"] = json!("a".repeat(64));
    item["size"] = json!(12);
    let peer = Peer::start(|request| {
        if request.method == "HEAD" {
            Reply {
                status: 507,
                body: json!({"error":"disk full"}),
            }
        } else {
            Reply::ok(empty_page(true))
        }
    });
    let shared = database(&root).unwrap();
    transfers::enqueue(
        &shared.lock().unwrap(),
        "device:test-peer",
        "upload",
        &json!({"sequence":1,"event":item_event(&item)}),
    )
    .unwrap();
    let state = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(state["transferErrorCategory"], "remote_storage");
    crate::tests::cleanup(&root);
}

#[test]
fn malformed_page_does_not_commit_deletions_or_advance_the_cursor() {
    let root = crate::tests::root();
    let original = note(902);
    dispatch(json!({"op":"add","root":root,"item":original})).unwrap();
    let target = original["id"].clone();
    let peer = Peer::start(move |request| {
        if request.method == "POST" {
            return Reply::ok(json!({"ok":true}));
        }
        let event = json!({"id":"malformed-delete-event","type":"delete","target":target});
        Reply::ok(
            json!({"protocol":3,"capabilities":[],"items":[{"sequence":4,"event":event}],"cursor":3,"more":false}),
        )
    });
    assert!(sync::synchronize(&root, &peer.endpoint, None, None).is_err());
    let state = dispatch(json!({"op":"snapshot","root":root})).unwrap();
    assert_eq!(state["entries"].as_array().unwrap().len(), 1);
    let shared = database(&root).unwrap();
    let db = shared.lock().unwrap();
    assert_eq!(
        db.query_row("SELECT pulled FROM cursors", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(db);
    crate::tests::cleanup(&root);
}

#[test]
fn favorite_removal_metadata_is_sent_even_when_its_shared_attachment_is_missing() {
    let root = crate::tests::root();
    let original = note(84);
    let source = original["id"].as_str().unwrap();
    let mut item = original.clone();
    item["id"] = json!(favorites::snapshot_id(source));
    item["kind"] = json!("file");
    item["text"] = json!("");
    item["name"] = json!("not-downloaded.bin");
    item["size"] = json!(20);
    item["sha256"] = json!("a".repeat(64));
    let event = json!({"id":"favorite-missing-event-01","type":"favorite","favorite":{"id":source,"value":true,"revision":1,"snapshotId":item["id"],"item":item,"savedAt":"2026-10-22T00:00:00Z"}});
    dispatch(json!({"op":"apply","root":root,"event":event})).unwrap();
    dispatch(json!({"op":"delete_favorites","root":root,"ids":[item["id"]]})).unwrap();
    let posted = Arc::new(Mutex::new(Vec::<Value>::new()));
    let received = posted.clone();
    let peer = Peer::start(move |request| {
        if request.method == "POST" {
            received.lock().unwrap().push(request.body);
            Reply::ok(json!({"ok":true}))
        } else if request.path.starts_with("/v3/changes") {
            Reply::ok(empty_page(true))
        } else {
            Reply {
                status: 404,
                body: json!({}),
            }
        }
    });
    let state = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert!(
        posted
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["type"] == "favorite" && e["favorite"]["value"] == false)
    );
    assert_eq!(state["moreChanges"], false);
    // Deleted attachments no longer leave a permanent missing-source job.
    assert!(state["transferError"].is_null());
    crate::tests::cleanup(&root);
}

#[test]
fn cancelled_sync_does_not_send_followups_or_commit_receipts() {
    let root = crate::tests::root();
    for index in 0..3 {
        dispatch(json!({"op":"add","root":root,"item":note(index)})).unwrap();
    }
    let posts = Arc::new(AtomicUsize::new(0));
    let received = posts.clone();
    let (sent, first) = std::sync::mpsc::channel();
    let (release, blocked) = std::sync::mpsc::channel();
    let blocked = Mutex::new(blocked);
    let peer = Peer::start(move |request| {
        if request.method == "GET" {
            return Reply::ok(empty_page(true));
        }
        if received.fetch_add(1, Ordering::SeqCst) == 0 {
            sent.send(()).unwrap();
            blocked
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .unwrap();
        }
        Reply::ok(json!({"ok":true}))
    });
    let run_id = sync_control::begin(&root, "device:test-peer").unwrap();
    let thread_root = root.clone();
    let endpoint = peer.endpoint.clone();
    let running =
        std::thread::spawn(move || sync::synchronize(&thread_root, &endpoint, None, Some(&run_id)));
    first.recv_timeout(Duration::from_secs(5)).unwrap();
    dispatch(json!({"op":"cancel_sync","root":root,"key":"device:test-peer"})).unwrap();
    release.send(()).unwrap();
    let error = running.join().unwrap().unwrap_err();
    assert_eq!(errors::category(error.as_ref()), "cancelled");
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    let shared = database(&root).unwrap();
    assert_eq!(
        shared
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM seen", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn old_peer_skips_favorites_without_blocking_text_and_upgrade_backfills_them() {
    let root = crate::tests::root();
    dispatch(json!({"op":"add","root":root,"item":note(1)})).unwrap();
    dispatch(json!({"op":"set_favorites","root":root,"ids":[note(1)["id"]],"value":true})).unwrap();
    dispatch(json!({"op":"add","root":root,"item":note(2)})).unwrap();
    let upgraded = Arc::new(AtomicBool::new(false));
    let capability = upgraded.clone();
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    let delivered = events.clone();
    let peer = Peer::start(move |request| {
        if request.method == "GET" {
            return Reply::ok(empty_page(capability.load(Ordering::Acquire)));
        }
        if request.body["type"] == "favorite" && !capability.load(Ordering::Acquire) {
            return Reply {
                status: 400,
                body: json!({"error":"Unknown change type"}),
            };
        }
        delivered.lock().unwrap().push(request.body);
        Reply::ok(json!({"ok":true}))
    });
    let result = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(result["moreChanges"], false);
    assert_eq!(events.lock().unwrap().len(), 2);
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .all(|event| event["type"] == "item")
    );
    upgraded.store(true, Ordering::Release);
    sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    let events = events.lock().unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[2]["favorite"]["id"], note(1)["id"]);
    assert_eq!(events[2]["favorite"]["value"], true);
    assert_eq!(
        peer.connections.load(Ordering::SeqCst),
        1,
        "successive sync passes reuse the pinned connection"
    );
    crate::tests::cleanup(&root);
}

#[test]
fn cached_connection_never_reuses_old_credentials_or_certificate_identity() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let received = seen.clone();
    let peer = Peer::start(move |request| {
        received.lock().unwrap().push(request.authorization);
        Reply::ok(empty_page(true))
    });
    sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    let mut changed = peer.endpoint.clone();
    changed["token"] = json!("replacement-token");
    sync::synchronize(&root, &changed, None, None).unwrap();
    assert_eq!(
        *seen.lock().unwrap(),
        vec!["Bearer first-token", "Bearer replacement-token"]
    );
    changed["fingerprint"] = json!("a".repeat(64));
    let error = sync::synchronize(&root, &changed, None, None).unwrap_err();
    assert_eq!(errors::category(error.as_ref()), "identity");
    assert_eq!(seen.lock().unwrap().len(), 2);
    crate::tests::cleanup(&root);
}

#[test]
fn pull_page_limit_keeps_the_final_pending_page_for_the_next_pass() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let pages = Arc::new(AtomicUsize::new(0));
    let count = pages.clone();
    let peer = Peer::start(move |request| {
        if request.method != "GET" {
            return Reply::ok(json!({"ok":true}));
        }
        let after: usize = request
            .path
            .split("after=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        count.fetch_add(1, Ordering::SeqCst);
        if after >= 21 {
            return Reply::ok(json!({"items":[],"cursor":21,"more":false,"protocol":3}));
        }
        let sequence = after + 1;
        Reply::ok(
            json!({"items":[{"sequence":sequence,"event":item_event(&note(sequence))}],"cursor":sequence,"more":sequence<21,"protocol":3}),
        )
    });
    let first = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(first["moreChanges"], true);
    assert_eq!(first["entries"].as_array().unwrap().len(), 20);
    assert_eq!(
        pages.load(Ordering::SeqCst),
        20,
        "must not prefetch a final page and lose its more flag"
    );
    let second = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(second["entries"].as_array().unwrap().len(), 21);
    assert_eq!(second["moreChanges"], false);
    crate::tests::cleanup(&root);
}

#[test]
fn push_page_limit_requests_a_followup_when_remote_has_no_more_changes() {
    let root = crate::tests::root();
    let shared = database(&root).unwrap();
    {
        let mut db = shared.lock().unwrap();
        let tx = db.transaction().unwrap();
        for index in 0..1000 {
            let event = json!({"id":format!("favorite-event-{index:016}"),"type":"favorite","favorite":{"id":"future-item-000001","value":true,"revision":index+1}});
            tx.execute(
                "INSERT INTO events(id,body) VALUES(?,?)",
                params![event["id"].as_str().unwrap(), event.to_string()],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    dispatch(json!({"op":"add","root":root,"item":note(1001)})).unwrap();
    let posts = Arc::new(AtomicUsize::new(0));
    let posted = posts.clone();
    let peer = Peer::start(move |request| {
        if request.method == "GET" {
            return Reply::ok(empty_page(false));
        }
        assert_eq!(request.body["type"], "item");
        posted.fetch_add(1, Ordering::SeqCst);
        Reply::ok(json!({"ok":true}))
    });
    let first = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(first["moreChanges"], true);
    assert_eq!(posts.load(Ordering::SeqCst), 0);
    let second = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(second["moreChanges"], false);
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    drop(shared);
    crate::tests::cleanup(&root);
}

#[test]
fn per_file_backoff_exposes_deadline_and_leaves_text_sync_available() {
    let root = crate::tests::root();
    initialize(&root).unwrap();
    let source = root.join("source.bin");
    fs::write(&source, b"file bytes").unwrap();
    let blob = dispatch(
        json!({"op":"import_file","root":root,"path":source,"name":"report.bin","kind":"file"}),
    )
    .unwrap();
    let mut item = note(1);
    item["kind"] = json!("file");
    item["name"] = json!("report.bin");
    item["text"] = json!("");
    item["sha256"] = blob["sha256"].clone();
    item["size"] = blob["size"].clone();
    dispatch(json!({"op":"add","root":root,"item":item})).unwrap();
    let heads = Arc::new(AtomicUsize::new(0));
    let failures = heads.clone();
    let texts = Arc::new(AtomicUsize::new(0));
    let delivered = texts.clone();
    let peer = Peer::start(move |request| match request.method.as_str() {
        "GET" => Reply::ok(empty_page(true)),
        "HEAD" => {
            failures.fetch_add(1, Ordering::SeqCst);
            Reply {
                status: 503,
                body: json!({"error":"Busy"}),
            }
        }
        _ => {
            assert_eq!(request.body["item"]["kind"], "text");
            delivered.fetch_add(1, Ordering::SeqCst);
            Reply::ok(json!({"ok":true}))
        }
    });
    let before = Utc::now().timestamp();
    let first = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(first["moreTransfers"], false);
    assert_eq!(first["transferErrorCategory"], "busy");
    assert!(first["nextRetry"].as_i64().unwrap() >= before + 4);
    dispatch(json!({"op":"add","root":root,"item":note(2)})).unwrap();
    let second = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(texts.load(Ordering::SeqCst), 1);
    assert_eq!(
        heads.load(Ordering::SeqCst),
        1,
        "file must respect its own deadline"
    );
    assert_eq!(second["nextRetry"], first["nextRetry"]);
    {
        let shared = database(&root).unwrap();
        shared
            .lock()
            .unwrap()
            .execute(
                "UPDATE transfer_jobs SET retry_after=?",
                [Utc::now().timestamp()],
            )
            .unwrap();
    }
    sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(
        heads.load(Ordering::SeqCst),
        2,
        "a due transfer is retried without resetting its progress"
    );
    crate::tests::cleanup(&root);
}

#[test]
fn newly_capable_client_replays_filtered_favorites_once_without_duplicate_messages() {
    let root = crate::tests::root();
    for index in 1..=2 {
        dispatch(json!({"op":"add","root":root,"item":note(index)})).unwrap();
    }
    {
        let shared = database(&root).unwrap();
        shared
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO cursors(endpoint,pushed,pulled) VALUES('device:test-peer',2,3)",
                [],
            )
            .unwrap();
    }
    let requests = Arc::new(Mutex::new(Vec::new()));
    let requested = requests.clone();
    let peer = Peer::start(move |request| {
        assert_eq!(request.method, "GET");
        assert!(request.path.contains("capabilities=favorites"));
        let after: i64 = request
            .path
            .split("after=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        requested.lock().unwrap().push(after);
        let favorite = json!({"id":"remote-favorite-event-01","type":"favorite","favorite":{"id":note(1)["id"],"value":true,"revision":1}});
        Reply::ok(
            json!({"items":if after == 0 { vec![json!({"sequence":1,"event":item_event(&note(1))}),json!({"sequence":2,"event":favorite}),json!({"sequence":3,"event":item_event(&note(2))})] } else { vec![] },"cursor":3,"more":false,"protocol":3,"capabilities":["favorites"]}),
        )
    });
    let first = sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(first["entries"].as_array().unwrap().len(), 2);
    assert_eq!(
        first["favorites"][note(1)["id"].as_str().unwrap()]["value"],
        true
    );
    sync::synchronize(&root, &peer.endpoint, None, None).unwrap();
    assert_eq!(*requests.lock().unwrap(), vec![3, 0, 3]);
    crate::tests::cleanup(&root);
}

#[test]
fn interrupted_and_timed_out_response_bodies_keep_network_error_categories() {
    for stalled in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            stream.read(&mut request).unwrap();
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial",
                )
                .unwrap();
            stream.flush().unwrap();
            if stalled {
                std::thread::sleep(Duration::from_millis(350));
            }
        });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut response = sync_control::runtime()
            .unwrap()
            .block_on(async {
                client
                    .get(format!("http://{address}"))
                    .timeout(Duration::from_millis(100))
                    .send()
                    .await
            })
            .unwrap();
        let error = sync_control::runtime().unwrap().block_on(async {
            loop {
                match response.chunk().await {
                    Ok(Some(_)) => (),
                    Ok(None) => panic!("incomplete response unexpectedly succeeded"),
                    Err(error) => break error,
                }
            }
        });
        assert_eq!(
            errors::category(&error),
            if stalled { "timeout" } else { "offline" }
        );
        server.join().unwrap();
    }
}

// A real TCP peer lets the transfer tests exercise HTTP backpressure and stalled
// reads without making each regression wait for the production idle deadline.
struct FilePeer {
    address: std::net::SocketAddr,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl FilePeer {
    fn start(
        handler: impl Fn(
            &str,
            &HashMap<String, String>,
            &mut BufReader<TcpStream>,
        ) -> std::io::Result<()>
        + Send
        + 'static,
    ) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let worker = std::thread::spawn(move || {
            while let Ok((socket, _)) = listener.accept() {
                if stopping.load(Ordering::Acquire) {
                    break;
                }
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut stream = BufReader::new(socket);
                let mut first = String::new();
                if stream.read_line(&mut first).unwrap_or(0) == 0 {
                    continue;
                }
                let method = first.split_whitespace().next().unwrap().to_owned();
                let mut headers = HashMap::new();
                loop {
                    let mut header = String::new();
                    if stream.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                        break;
                    }
                    if let Some((name, value)) = header.trim().split_once(':') {
                        headers.insert(name.to_ascii_lowercase(), value.trim().to_owned());
                    }
                }
                let _ = handler(&method, &headers, &mut stream);
            }
        });
        Self {
            address,
            stop,
            worker: Some(worker),
        }
    }
    fn url(&self) -> String {
        format!("http://{}", self.address)
    }
}
impl Drop for FilePeer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.address);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}
fn file_reply(
    stream: &mut BufReader<TcpStream>,
    status: u16,
    length: usize,
    headers: &str,
) -> std::io::Result<()> {
    write!(
        stream.get_mut(),
        "HTTP/1.1 {status} OK\r\nContent-Length: {length}\r\nConnection: close\r\n{headers}\r\n"
    )?;
    stream.get_mut().flush()
}
fn transfer_run(root: &Path, idle: Duration) -> sync_control::Run {
    initialize(root).unwrap();
    let id = sync_control::begin(root, "test-transfer").unwrap();
    let mut run = sync_control::Run::acquire(root, "test-transfer", &id).unwrap();
    run.set_idle_timeout(idle);
    run
}

#[test]
fn stalled_download_preserves_partial_bytes_and_resumes_with_full_checksum() {
    let root = crate::tests::root();
    let run = transfer_run(&root, Duration::from_millis(100));
    let data = vec![37_u8; 4096];
    let sha = digest(&data);
    let item = json!({"sha256":sha,"size":data.len()});
    let gets = Arc::new(AtomicUsize::new(0));
    let requested = gets.clone();
    let (release, stalled) = std::sync::mpsc::channel();
    let peer = FilePeer::start(move |method, headers, stream| {
        if method == "HEAD" {
            return file_reply(stream, 200, data.len(), "Accept-Ranges: bytes\r\n");
        }
        let first = requested.fetch_add(1, Ordering::SeqCst) == 0;
        let offset = if first { 0 } else { 1024 };
        assert_eq!(headers["range"], format!("bytes={offset}-4095"));
        file_reply(
            stream,
            206,
            data.len() - offset,
            &format!("Content-Range: bytes {offset}-4095/4096\r\n"),
        )?;
        if first {
            stream.get_mut().write_all(&data[..1024])?;
            stream.get_mut().flush()?;
            stalled.recv_timeout(Duration::from_secs(5)).unwrap();
        } else {
            stream.get_mut().write_all(&data[offset..])?;
        }
        Ok(())
    });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let error =
        sync::download(&client, &peer.url(), &root, "test-transfer", &item, &run).unwrap_err();
    assert_eq!(errors::category(error.as_ref()), "timeout");
    assert!(!attachments::path(&root, &sha).exists());
    release.send(()).unwrap();
    assert_eq!(
        sync::download(&client, &peer.url(), &root, "test-transfer", &item, &run).unwrap(),
        (4096, true)
    );
    assert_eq!(
        blobs::hash_file(&attachments::path(&root, &sha)).unwrap(),
        sha
    );
    assert_eq!(gets.load(Ordering::SeqCst), 2);
    drop(peer);
    crate::tests::cleanup(&root);
}

#[test]
fn slow_continuous_legacy_download_has_no_total_transfer_deadline() {
    let root = crate::tests::root();
    let idle = Duration::from_millis(150);
    let run = transfer_run(&root, idle);
    let data = vec![63_u8; 128 * 1024];
    let sha = digest(&data);
    let item = json!({"sha256":sha,"size":data.len()});
    let peer = FilePeer::start(move |method, _, stream| {
        file_reply(stream, 200, data.len(), "")?;
        if method != "HEAD" {
            for chunk in data.chunks(4096) {
                stream.get_mut().write_all(chunk)?;
                stream.get_mut().flush()?;
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        Ok(())
    });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let started = std::time::Instant::now();
    assert_eq!(
        sync::download(&client, &peer.url(), &root, "test-transfer", &item, &run).unwrap(),
        (128 * 1024, true)
    );
    assert!(started.elapsed() > idle * 3);
    assert_eq!(
        blobs::hash_file(&attachments::path(&root, &sha)).unwrap(),
        sha
    );
    drop(peer);
    crate::tests::cleanup(&root);
}

#[test]
fn stalled_upload_times_out_and_slow_upload_keeps_its_bytes() {
    for stalled in [true, false] {
        let root = crate::tests::root();
        let idle = Duration::from_millis(250);
        let run = transfer_run(&root, idle);
        let data = vec![71_u8; 16 * 1024 * 1024];
        let sha = digest(&data);
        let path = root.join("upload.bin");
        fs::write(&path, &data).unwrap();
        let expected = sha.clone();
        let (release, blocked) = std::sync::mpsc::channel();
        let peer = FilePeer::start(move |_, headers, stream| {
            let length: usize = headers["content-length"].parse().unwrap();
            if stalled {
                blocked.recv_timeout(Duration::from_secs(5)).unwrap();
                return Ok(());
            }
            let mut actual = Vec::with_capacity(length);
            let mut chunk = [0_u8; 64 * 1024];
            while actual.len() < length {
                let count = (length - actual.len()).min(chunk.len());
                stream.read_exact(&mut chunk[..count])?;
                actual.extend_from_slice(&chunk[..count]);
                std::thread::sleep(Duration::from_millis(4));
            }
            assert_eq!(digest(&actual), expected);
            // Flushing/hashing on the receiver after upload is not a stalled
            // active upload and must get the separate acknowledgement budget.
            std::thread::sleep(Duration::from_millis(400));
            file_reply(stream, 200, 2, "")?;
            stream.get_mut().write_all(b"{}")
        });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let (body, progress) = sync_control::file_body(
            File::open(&path).unwrap(),
            data.len() as u64,
            Duration::from_secs(3),
        );
        let started = std::time::Instant::now();
        let result = run.wait_network(
            || {
                client
                    .put(peer.url())
                    .header(reqwest::header::CONTENT_LENGTH, data.len())
                    .body(body)
                    .send()
            },
            Some(&progress),
            idle,
        );
        if stalled {
            assert_eq!(errors::category(result.unwrap_err().as_ref()), "timeout");
            assert!(started.elapsed() < Duration::from_secs(2));
            release.send(()).unwrap();
        } else {
            assert!(result.unwrap().status().is_success());
            assert!(started.elapsed() > idle * 4);
        }
        assert_eq!(blobs::hash_file(&path).unwrap(), sha);
        drop(peer);
        crate::tests::cleanup(&root);
    }
}

#[test]
fn cancelled_waiting_network_request_exits_without_waiting_for_its_deadline() {
    use crate::sync_control::CheckedRequest;
    let root = crate::tests::root();
    let run = transfer_run(&root, Duration::from_secs(45));
    let (entered, requested) = std::sync::mpsc::channel();
    let (release, blocked) = std::sync::mpsc::channel();
    let peer = FilePeer::start(move |_, _, _| {
        entered.send(()).unwrap();
        blocked.recv_timeout(Duration::from_secs(5)).unwrap();
        Ok(())
    });
    let url = peer.url();
    let worker = std::thread::spawn(move || {
        reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(url)
            .send_checked(&run)
    });
    requested.recv_timeout(Duration::from_secs(5)).unwrap();
    let started = std::time::Instant::now();
    sync_control::cancel(&root, Some("test-transfer"));
    let error = worker.join().unwrap().unwrap_err();
    assert_eq!(errors::category(error.as_ref()), "cancelled");
    assert!(started.elapsed() < Duration::from_secs(1));
    release.send(()).unwrap();
    drop(peer);
    crate::tests::cleanup(&root);
}

#[test]
fn resumed_and_legacy_uploads_preserve_ranges_and_checksum_acknowledgements() {
    for resumable in [true, false] {
        let root = crate::tests::root();
        let run = transfer_run(&root, Duration::from_secs(5));
        let data = vec![91_u8; 8 * 1024 * 1024 + 333];
        let sha = digest(&data);
        let item = json!({"sha256":sha,"size":data.len()});
        fs::write(attachments::path(&root, &sha), &data).unwrap();
        let received = Arc::new(Mutex::new(if resumable {
            data[..1234].to_vec()
        } else {
            Vec::new()
        }));
        let saved = received.clone();
        let peer = FilePeer::start(move |method, headers, stream| {
            let mut bytes = saved.lock().unwrap();
            if method == "HEAD" {
                let extra = if resumable {
                    format!(
                        "X-Lanflow-Resumable: 1\r\nX-Lanflow-Offset: {}\r\n",
                        bytes.len()
                    )
                } else {
                    String::new()
                };
                return file_reply(stream, 404, 0, &extra);
            }
            let length: usize = headers["content-length"].parse().unwrap();
            if resumable {
                assert_eq!(
                    headers["content-range"],
                    format!(
                        "bytes {}-{}/{}",
                        bytes.len(),
                        bytes.len() + length - 1,
                        data.len()
                    )
                );
                assert!(length <= 4 * 1024 * 1024);
            } else {
                assert!(!headers.contains_key("content-range"));
                assert_eq!(length, data.len());
            }
            let before = bytes.len();
            bytes.resize(before + length, 0);
            stream.read_exact(&mut bytes[before..])?;
            assert_eq!(*bytes, data[..bytes.len()]);
            let checksum = if bytes.len() == data.len() {
                json!(digest(&bytes))
            } else {
                Value::Null
            };
            let ack = serde_json::to_vec(&json!({"offset":bytes.len(),"sha256":checksum})).unwrap();
            file_reply(stream, 200, ack.len(), "")?;
            stream.get_mut().write_all(&ack)
        });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        for pass in 0..3 {
            let (offset, done) = sync::upload(&client, &peer.url(), &root, &item, &run).unwrap();
            if done {
                assert_eq!(offset, item["size"].as_u64().unwrap());
                break;
            }
            assert_eq!(pass, 0, "resumed file should need just two chunks");
            assert_eq!(offset, 1234 + 4 * 1024 * 1024);
        }
        assert_eq!(digest(&received.lock().unwrap()), sha);
        drop(peer);
        crate::tests::cleanup(&root);
    }
}
