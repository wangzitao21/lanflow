#![cfg(feature = "hub")]

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use reqwest::blocking::{Client, Response};
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::TcpStream,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

#[test]
fn incomplete_tls_and_trickled_headers_have_absolute_deadlines() {
    use rustls::pki_types::{CertificateDer, ServerName, pem::PemObject};
    let nas = Nas::new();
    let mut incomplete = TcpStream::connect(("127.0.0.1", nas.port)).unwrap();
    incomplete
        .set_read_timeout(Some(Duration::from_secs(8)))
        .unwrap();
    let mut byte = [0u8; 1];
    let start = Instant::now();
    let result = incomplete.read(&mut byte);
    assert!(start.elapsed() < Duration::from_secs(7));
    assert!(
        matches!(result, Ok(0))
            || result.is_err_and(|e| e.kind() != std::io::ErrorKind::TimedOut
                && e.kind() != std::io::ErrorKind::WouldBlock)
    );

    let mut roots = rustls::RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(nas.root.join("system/certificate.pem")).unwrap() {
        roots.add(cert.unwrap()).unwrap();
    }
    let config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    let socket = TcpStream::connect(("127.0.0.1", nas.port)).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    socket
        .set_write_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let connection = rustls::ClientConnection::new(
        std::sync::Arc::new(config),
        ServerName::try_from("lanflow.local").unwrap(),
    )
    .unwrap();
    let mut stream = rustls::StreamOwned::new(connection, socket);
    stream
        .write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\nX-Probe: ")
        .unwrap();
    stream.flush().unwrap();
    // Keep producing traffic, beyond the complete-header deadline.
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(11) {
        std::thread::sleep(Duration::from_millis(250));
        if stream.write_all(b".").and_then(|_| stream.flush()).is_err() {
            break;
        }
    }
    let result = stream.read(&mut byte);
    assert!(
        matches!(result, Ok(0))
            || result.is_err_and(|e| e.kind() != std::io::ErrorKind::TimedOut
                && e.kind() != std::io::ErrorKind::WouldBlock)
    );
    assert_eq!(nas.get("/v2/info")["service"], "lanflow-inbox");
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn item() -> Value {
    json!({"id":uuid::Uuid::new_v4().simple().to_string(),"originId":"a".repeat(32),
        "originName":"我的手机","createdAt":"2026-10-19T10:00:00.000Z",
        "kind":"text","text":"离线时的想法 👋","name":"","size":0,"sha256":""})
}
fn event(item: &Value) -> Value {
    json!({"id":digest(format!("item:{}",item["id"].as_str().unwrap()).as_bytes()),"type":"item","item":item})
}

fn core(request: Value) -> Value {
    let text = std::ffi::CString::new(request.to_string()).unwrap();
    let response = unsafe {
        let pointer = lanflow_core::lanflow_call(text.as_ptr());
        let value = std::ffi::CStr::from_ptr(pointer)
            .to_str()
            .unwrap()
            .to_owned();
        lanflow_core::lanflow_free(pointer);
        serde_json::from_str::<Value>(&value).unwrap()
    };
    assert_eq!(response["ok"], true, "{response}");
    response["value"].clone()
}

#[test]
fn deleted_favorite_attachments_disappear_on_reconnected_and_new_devices() {
    let mut nas = Nas::new();
    let client_root =
        std::env::temp_dir().join(format!("lanflow-favorite-sync-{}", uuid::Uuid::new_v4()));
    let a = client_root.join("a");
    let b = client_root.join("b");
    let c = client_root.join("c");
    core(json!({"op":"open","root":a}));
    let source = client_root.join("source.bin");
    let bytes: Vec<u8> = (0..262_144).map(|i| (i % 251) as u8).collect();
    fs::write(&source, &bytes).unwrap();
    let stored = core(
        json!({"op":"import_file","root":a,"path":source,"name":"favorite-only.bin","kind":"file"}),
    );
    let mut original = item();
    original["kind"] = json!("file");
    original["text"] = json!("");
    original["name"] = json!("favorite-only.bin");
    original["size"] = json!(bytes.len());
    original["sha256"] = stored["sha256"].clone();
    core(json!({"op":"add","root":a,"item":original}));
    let saved=core(json!({"op":"set_favorites","root":a,"ids":[original["id"]],"value":true}))["favorites"][original["id"].as_str().unwrap()].clone();
    let sync = |root: &PathBuf, nas: &Nas| {
        let code: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(&nas.code[9..]).unwrap()).unwrap();
        let endpoint = json!({"key":"hub:favorite-test","url":nas.url(""),"token":nas.token,"fingerprint":code["fingerprint"]});
        for _ in 0..12 {
            let state = core(json!({"op":"sync","root":root,"endpoint":endpoint}));
            assert!(state["transferError"].is_null(), "{state}");
            if state["moreTransfers"] != true && state["moreChanges"] != true {
                return state;
            }
        }
        panic!("favorite synchronization did not settle");
    };
    sync(&a, &nas);
    assert_eq!(nas.get("/v2/items")["items"].as_array().unwrap().len(),1);
    nas.restart();
    core(json!({"op":"open","root":b}));
    sync(&b, &nas);
    let received = core(json!({"op":"snapshot","root":b}));
    assert_eq!(received["entries"].as_array().unwrap().len(),1);
    let favorite = &received["favorites"][original["id"].as_str().unwrap()];
    assert_eq!(favorite["item"], saved["item"]);
    assert_eq!(
        fs::read(b.join(favorite["blobPath"].as_str().unwrap())).unwrap(),
        bytes
    );
    core(json!({"op":"close","root":b}));
    core(json!({"op":"delete","root":a,"id":original["id"]}));
    sync(&a,&nas);
    nas.restart();
    core(json!({"op":"open","root":b}));
    sync(&b,&nas);
    core(json!({"op":"open","root":c}));
    sync(&c,&nas);
    for root in [&a,&b,&c] {
        let state=core(json!({"op":"snapshot","root":root}));
        assert!(state["entries"].as_array().unwrap().is_empty());
        assert_eq!(state["favorites"][original["id"].as_str().unwrap()]["value"],false);
        assert!(core(json!({"op":"transfers","root":root})).as_array().unwrap().is_empty());
    }
    for root in [&a, &b, &c] {
        core(json!({"op":"close","root":root}));
    }
    fs::remove_dir_all(client_root).unwrap();
}

#[test]
fn favorite_file_publication_wakes_watch_without_adding_a_second_metadata_event() {
    let nas = Nas::new();
    let bytes = b"late shared favorite bytes";
    let original = item();
    let mut snapshot = original.clone();
    snapshot["id"] = json!(digest(
        format!("favorite:{}", original["id"].as_str().unwrap()).as_bytes()
    ));
    snapshot["kind"] = json!("file");
    snapshot["text"] = json!("");
    snapshot["name"] = json!("late.bin");
    snapshot["size"] = json!(bytes.len());
    snapshot["sha256"] = json!(digest(bytes));
    let favorite = json!({"id":"favorite-late-hub-event-001","type":"favorite","favorite":{"id":original["id"],"value":true,"revision":100,"snapshotId":snapshot["id"],"item":snapshot,"savedAt":"2026-10-22T00:00:00Z"}});
    assert_eq!(nas.post("/v3/changes", &favorite), 200);
    let cursor = nas.get("/v3/watch?after=-1")["cursor"].as_i64().unwrap();
    let before = nas.get("/v3/changes?after=0&capabilities=favorites,favoriteSnapshots")["items"]
        .as_array()
        .unwrap()
        .len();
    let client = nas.client.clone();
    let token = nas.token.clone();
    let url = nas.url(&format!("/v3/watch?after={cursor}"));
    let (sent, received) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let value: Value = client
            .get(url)
            .bearer_auth(token)
            .send()
            .unwrap()
            .json()
            .unwrap();
        sent.send(value).unwrap();
    });
    assert!(received.recv_timeout(Duration::from_millis(100)).is_err());
    assert_eq!(nas.upload(&digest(bytes), bytes, None).status(), 200);
    assert_eq!(nas.post("/v3/changes", &favorite), 200);
    let changed = received.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(changed["changed"], true);
    assert!(changed["cursor"].as_i64().unwrap() > cursor);
    waiter.join().unwrap();
    assert_eq!(
        nas.get("/v3/changes?after=0&capabilities=favorites,favoriteSnapshots")["items"]
            .as_array()
            .unwrap()
            .len(),
        before
    );
}

#[test]
fn change_watch_requires_auth_and_waits_for_a_commit() {
    let nas = Nas::new();
    assert_eq!(
        nas.client
            .get(nas.url("/v3/watch"))
            .send()
            .unwrap()
            .status(),
        401
    );
    let baseline = nas.get("/v3/watch?after=-1");
    let cursor = baseline["cursor"].as_i64().unwrap();
    let client = nas.client.clone();
    let url = nas.url(&format!("/v3/watch?after={cursor}"));
    let token = nas.token.clone();
    let (tx, rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let response: Value = client
            .get(url)
            .bearer_auth(token)
            .send()
            .unwrap()
            .json()
            .unwrap();
        tx.send(response).unwrap();
    });
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
    assert_eq!(nas.post("/v3/changes", &event(&item())), 200);
    let changed = rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(changed["cursor"].as_i64().unwrap() > cursor);
    assert_eq!(changed["changed"], true);
    waiter.join().unwrap();
}

#[test]
fn idle_change_watch_stays_silent_until_content_and_releases_closed_connections() {
    let nas = Nas::new();
    let baseline = nas.get("/v3/watch?after=-1");
    assert_eq!(baseline["waitForChange"], true);
    let cursor = baseline["cursor"].as_i64().unwrap();
    let url = nas.url(&format!("/v3/watch?after={cursor}&wait=change"));
    // More disconnects than the entire watch admission pool must not leak
    // slots when the indefinite wait is cancelled before any new content.
    for _ in 0..70 {
        let result = nas.client.get(&url).bearer_auth(&nas.token)
            .timeout(Duration::from_millis(60)).send();
        assert!(result.is_err_and(|error| error.is_timeout()));
    }
    let client = nas.client.clone();
    let token = nas.token.clone();
    let (tx, rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let response: Value = client.get(url).bearer_auth(token)
            .timeout(Duration::from_secs(40)).send().unwrap().json().unwrap();
        tx.send(response).unwrap();
    });
    // Cross the old 25-second idle reply deadline.
    assert!(rx.recv_timeout(Duration::from_secs(27)).is_err());
    assert_eq!(nas.post("/v3/changes", &event(&item())), 200);
    let changed = rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(changed["cursor"].as_i64().unwrap() > cursor);
    assert_eq!(changed["changed"], true);
    waiter.join().unwrap();
}

struct Nas {
    root: PathBuf,
    process: Option<Child>,
    client: Client,
    port: u16,
    code: String,
    token: String,
}
impl Nas {
    fn empty() -> Self {
        let root = std::env::temp_dir().join(format!("lanflow-hub-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        Self {
            root,
            process: None,
            client: Client::builder()
                .danger_accept_invalid_certs(true)
                .no_proxy()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap(),
            port: 0,
            code: String::new(),
            token: String::new(),
        }
    }
    fn new() -> Self {
        let mut nas = Self::empty();
        nas.start();
        nas
    }
    fn start(&mut self) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_lanflow-hub"))
            .arg("--data")
            .arg(&self.root)
            .args(["--host", "127.0.0.1", "--port", "0"])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let output = child.stdout.take().unwrap();
        self.process = Some(child);
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut port = 0;
            for line in BufReader::new(output)
                .lines()
                .map_while(std::result::Result::ok)
            {
                if line.starts_with("LanFlow NAS ready") {
                    port = line.split_whitespace().last().unwrap().parse().unwrap();
                }
                if line.starts_with("lanflow1:") {
                    let _ = tx.send((port, line));
                    break;
                }
            }
        });
        let (port, code) = rx
            .recv_timeout(Duration::from_secs(20))
            .expect("Rust NAS startup");
        self.port = port;
        self.code = code;
        let config: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(&self.code[9..]).unwrap()).unwrap();
        self.token = config["token"].as_str().unwrap().to_owned();
    }
    fn stop(&mut self) {
        if let Some(mut process) = self.process.take() {
            let _ = process.kill();
            process.wait().unwrap();
        }
    }
    fn restart(&mut self) {
        self.stop();
        self.start();
    }
    fn url(&self, path: &str) -> String {
        format!("https://127.0.0.1:{}{path}", self.port)
    }
    fn request(&self, method: &str, path: &str) -> reqwest::blocking::RequestBuilder {
        self.client
            .request(method.parse().unwrap(), self.url(path))
            .bearer_auth(&self.token)
    }
    fn get(&self, path: &str) -> Value {
        self.request("GET", path)
            .send()
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .unwrap()
    }
    fn post(&self, path: &str, value: &Value) -> u16 {
        self.request("POST", path)
            .json(value)
            .send()
            .unwrap()
            .status()
            .as_u16()
    }
    fn upload(&self, hash: &str, bytes: &[u8], range: Option<&str>) -> Response {
        let mut request = self
            .request("PUT", &format!("/v2/blobs/{hash}"))
            .body(bytes.to_vec());
        if let Some(range) = range {
            request = request.header("Content-Range", range);
        }
        request.send().unwrap()
    }
}
impl Drop for Nas {
    fn drop(&mut self) {
        self.stop();
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn authentication_durable_idempotency_and_identity_survive_restart() {
    let mut nas = Nas::new();
    let item = item();
    assert_eq!(
        nas.client
            .post(nas.url("/v2/items"))
            .json(&item)
            .send()
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        nas.client.get(nas.url("/health")).send().unwrap().status(),
        200
    );
    for _ in 0..3 {
        assert_eq!(nas.post("/v2/items", &item), 200);
    }
    let mut changed = item.clone();
    changed["text"] = json!("conflict");
    assert_eq!(nas.post("/v2/items", &changed), 409);
    let code = nas.code.clone();
    let cert = fs::read(nas.root.join("system/certificate.pem")).unwrap();
    let key = fs::read(nas.root.join("system/private-key.pem")).unwrap();
    nas.restart();
    assert_eq!(nas.code, code);
    assert_eq!(
        fs::read(nas.root.join("system/certificate.pem")).unwrap(),
        cert
    );
    assert_eq!(
        fs::read(nas.root.join("system/private-key.pem")).unwrap(),
        key
    );
    assert_eq!(nas.get("/v2/items")["items"].as_array().unwrap().len(), 1);
    assert_eq!(nas.get("/v2/items")["items"][0]["text"], item["text"]);
}

#[test]
fn conversations_profiles_and_deletion_use_the_shared_rules() {
    let mut nas = Nas::new();
    let old = item();
    assert_eq!(nas.post("/v2/items", &old), 200);
    let category = "conversation-work-001";
    for (revision, name) in [(2, "工作"), (1, "旧分类")] {
        assert_eq!(
            nas.post(
                "/v3/changes",
                &json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"conversation",
            "conversation":{"id":category,"name":name,"revision":revision}})
            ),
            200
        );
        assert_eq!(
            nas.post(
                "/v3/changes",
                &json!({"id":uuid::Uuid::new_v4().simple().to_string(),"type":"profile",
            "profile":{"id":old["originId"],"name":name,"avatar":"","revision":revision}})
            ),
            200
        );
    }
    let mut categorized = item();
    categorized["conversationId"] = json!(category);
    assert_eq!(nas.post("/v2/items", &categorized), 200);
    assert!(
        nas.get("/v2/items")["items"][0]
            .get("conversationId")
            .is_none()
    );
    let deletion = json!({"id":digest(format!("delete:{}",old["id"].as_str().unwrap()).as_bytes()),"type":"delete","target":old["id"]});
    assert_eq!(nas.post("/v3/changes", &deletion), 200);
    assert_eq!(nas.post("/v2/items", &old), 200);
    nas.restart();
    assert_eq!(nas.get("/v2/items")["items"].as_array().unwrap().len(), 1);
    assert_eq!(nas.get("/v2/items")["items"][0]["conversationId"], category);
    let db = Connection::open(nas.root.join("system/messages.sqlite3")).unwrap();
    for table in ["profiles", "conversations"] {
        let value: String = db
            .query_row(&format!("SELECT body FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&value).unwrap()["name"],
            "工作"
        );
    }
}

#[test]
fn blob_integrity_empty_files_and_metadata_ordering() {
    let nas = Nas::new();
    for bytes in [Vec::new(), (0..524544).map(|i| (i % 256) as u8).collect()] {
        let hash = digest(&bytes);
        let mut item = item();
        item["kind"] = json!("video");
        item["name"] = json!("../../movie.mp4");
        item["size"] = json!(bytes.len());
        item["sha256"] = json!(hash);
        item["text"] = json!("");
        assert_eq!(nas.post("/v2/items", &item), 409);
        assert_eq!(nas.upload(&hash, b"corrupt", None).status(), 400);
        assert!(!nas.root.join("system/pending").join(&hash).exists());
        assert_eq!(
            fs::read_dir(nas.root.join("system/cache/incoming"))
                .unwrap()
                .count(),
            0
        );
        assert_eq!(nas.upload(&hash, &bytes, None).status(), 200);
        assert_eq!(nas.post("/v2/items", &item), 200);
        assert_eq!(
            nas.request("GET", &format!("/v2/blobs/{hash}"))
                .send()
                .unwrap()
                .bytes()
                .unwrap()
                .as_ref(),
            bytes
        );
    }
}

#[test]
fn item_and_event_pagination_never_skip_or_duplicate() {
    let nas = Nas::new();
    for _ in 0..113 {
        assert_eq!(nas.post("/v2/items", &item()), 200);
    }
    for route in ["/v2/items", "/v3/changes"] {
        let mut cursor = 0;
        let mut ids = std::collections::HashSet::new();
        loop {
            let page = nas.get(&format!("{route}?after={cursor}"));
            for record in page["items"].as_array().unwrap() {
                assert!(
                    ids.insert(
                        if route == "/v2/items" {
                            record["id"].clone()
                        } else {
                            record["event"]["id"].clone()
                        }
                        .to_string()
                    )
                );
            }
            cursor = page["cursor"].as_i64().unwrap();
            if page["more"] == false {
                break;
            }
        }
        assert_eq!(ids.len(), 113);
    }
}

#[test]
fn validation_blocks_bad_metadata_credentials_and_file_paths() {
    let nas = Nas::new();
    for (field, value) in [
        ("id", json!("../escape")),
        ("size", json!(true)),
        ("text", json!("x".repeat(20001))),
        ("originName", json!("😀".repeat(31))),
    ] {
        let mut item = item();
        item[field] = value;
        assert_eq!(nas.post("/v2/items", &item), 400);
    }
    assert_eq!(
        nas.request("GET", "/hub.json").send().unwrap().status(),
        404
    );
    assert_eq!(
        nas.request("GET", "/v2/blobs/%2e%2e%2fhub.json")
            .send()
            .unwrap()
            .status(),
        400
    );
    for route in [
        "/v2/items?after=-1",
        "/v3/changes?after=9223372036854775808",
    ] {
        assert_eq!(nas.request("GET", route).send().unwrap().status(), 400);
    }
    assert!(
        !nas.request("GET", "/v2/info")
            .header("Authorization", "Bearer bad")
            .send()
            .unwrap()
            .status()
            .is_success()
    );
}

#[test]
fn chunk_upload_resumes_after_restart_and_supports_ranges() {
    let mut nas = Nas::new();
    let bytes: Vec<_> = (0..2560256).map(|i| (i % 256) as u8).collect();
    let hash = digest(&bytes);
    let route = format!("/v2/blobs/{hash}");
    let head = format!("{route}?size={}", bytes.len());
    let response = nas.request("HEAD", &head).send().unwrap();
    assert_eq!(response.status(), 404);
    assert_eq!(response.headers()["X-Lanflow-Offset"], "0");
    let first = format!("bytes 0-1048575/{}", bytes.len());
    assert_eq!(
        nas.upload(&hash, &bytes[..1048576], Some(&first)).status(),
        200
    );
    for _ in 0..3 {
        assert_eq!(
            nas.upload(&hash, &bytes[..1048576], Some(&first)).status(),
            409
        );
        assert_eq!(
            nas.request("HEAD", &head).send().unwrap().headers()["X-Lanflow-Offset"],
            "1048576"
        );
    }
    nas.restart();
    assert_eq!(
        nas.request("HEAD", &head).send().unwrap().headers()["X-Lanflow-Offset"],
        "1048576"
    );
    let last = format!("bytes 1048576-{}/{}", bytes.len() - 1, bytes.len());
    assert_eq!(
        nas.upload(&hash, &bytes[1048576..], Some(&last)).status(),
        200
    );
    let response = nas
        .request("GET", &route)
        .header("Range", "bytes=10-500")
        .send()
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(
        response.headers()["Content-Range"],
        format!("bytes 10-500/{}", bytes.len())
    );
    assert_eq!(response.bytes().unwrap().as_ref(), &bytes[10..501]);
    assert_eq!(
        nas.request("GET", &route)
            .header("Range", format!("bytes={}-", bytes.len()))
            .send()
            .unwrap()
            .status(),
        416
    );
}

#[test]
fn bad_checksum_is_removed_and_flushed_final_chunk_is_recovered() {
    let nas = Nas::new();
    let bytes = b"correct-content";
    let hash = digest(bytes);
    assert_eq!(
        nas.upload(&hash, b"bad", Some("bytes 0-2/15")).status(),
        200
    );
    assert_eq!(
        nas.upload(&hash, &bytes[3..], Some("bytes 3-14/15"))
            .status(),
        400
    );
    assert_eq!(
        fs::read_dir(nas.root.join("system/cache/incoming"))
            .unwrap()
            .count(),
        0
    );
    fs::write(
        nas.root
            .join("system/cache/incoming")
            .join(format!("{hash}.15.upload.part")),
        bytes,
    )
    .unwrap();
    let response = nas
        .request("HEAD", &format!("/v2/blobs/{hash}?size=15"))
        .send()
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["Content-Length"], "15");
    assert_eq!(
        nas.request("GET", &format!("/v2/blobs/{hash}"))
            .send()
            .unwrap()
            .bytes()
            .unwrap()
            .as_ref(),
        bytes
    );
}

#[test]
fn python_database_upgrade_preserves_sequences_identity_blobs_and_makes_a_backup() {
    let mut nas = Nas::empty();
    let config = json!({"id":"b".repeat(32),"token":"A".repeat(43)});
    fs::write(
        nas.root.join("hub.json"),
        serde_json::to_vec(&config).unwrap(),
    )
    .unwrap();
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["old-nas.local".into()]).unwrap();
    let certificate = cert.pem();
    let private_key = signing_key.serialize_pem();
    fs::write(nas.root.join("certificate.pem"), &certificate).unwrap();
    fs::write(nas.root.join("private-key.pem"), &private_key).unwrap();
    // Match the compact JSON and field order used by the Python service.
    let expected_code = format!(
        "lanflow1:{}",
        URL_SAFE_NO_PAD.encode(format!(
            "{{\"id\":\"{}\",\"token\":\"{}\",\"fingerprint\":\"{}\"}}",
            config["id"].as_str().unwrap(),
            config["token"].as_str().unwrap(),
            digest(cert.der().as_ref()),
        ))
    );
    let db = Connection::open(nas.root.join("inbox.sqlite3")).unwrap();
    db.execute_batch("PRAGMA journal_mode=WAL;
        CREATE TABLE items(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,body TEXT NOT NULL);
        CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,body TEXT NOT NULL);
        CREATE TABLE deleted(id TEXT PRIMARY KEY);
        CREATE TABLE profiles(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,event_id TEXT NOT NULL,body TEXT NOT NULL);
        CREATE TABLE conversations(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,event_id TEXT NOT NULL,body TEXT NOT NULL);").unwrap();
    let text = item();
    let mut file = item();
    let bytes = b"existing NAS file";
    let hash = digest(bytes);
    file["kind"] = json!("file");
    file["text"] = json!("");
    file["name"] = json!("existing.bin");
    file["size"] = json!(bytes.len());
    file["sha256"] = json!(hash);
    fs::create_dir(nas.root.join("blobs")).unwrap();
    fs::write(nas.root.join("blobs").join(&hash), bytes).unwrap();
    for (item_sequence, event_sequence, value) in [(7, 11, &text), (40, 48, &file)] {
        db.execute(
            "INSERT INTO items VALUES(?,?,?)",
            params![
                item_sequence,
                value["id"].as_str().unwrap(),
                value.to_string()
            ],
        )
        .unwrap();
        let event = event(value);
        db.execute(
            "INSERT INTO events VALUES(?,?,?)",
            params![
                event_sequence,
                event["id"].as_str().unwrap(),
                event.to_string()
            ],
        )
        .unwrap();
    }
    let removed = "removed-item-00001";
    let deletion = json!({"id":"delete-event-000001","type":"delete","target":removed});
    db.execute(
        "INSERT INTO events VALUES(200,?,?)",
        params![deletion["id"].as_str().unwrap(), deletion.to_string()],
    )
    .unwrap();
    db.execute("INSERT INTO deleted VALUES(?)", [removed])
        .unwrap();
    db.execute("UPDATE sqlite_sequence SET seq=700 WHERE name='items'", [])
        .unwrap();
    // Keep the old connection open: the backup must include committed WAL data.
    nas.start();
    assert_eq!(nas.code, expected_code);
    let page = nas.get("/v2/items");
    assert_eq!(page["items"][0]["sequence"], 7);
    assert_eq!(page["items"][1]["sequence"], 40);
    assert_eq!(nas.get("/v3/changes?after=48")["items"][0]["sequence"], 200);
    assert_eq!(nas.post("/v2/items", &text), 200);
    assert_eq!(nas.post("/v3/changes", &deletion), 200);
    let mut stale = item();
    stale["id"] = json!(removed);
    assert_eq!(nas.post("/v2/items", &stale), 200);
    assert_eq!(nas.get("/v2/items")["items"].as_array().unwrap().len(), 2);
    let next = item();
    assert_eq!(nas.post("/v2/items", &next), 200);
    assert!(
        nas.get("/v2/items?after=40")["items"][0]["sequence"]
            .as_i64()
            .unwrap()
            > 700
    );
    assert_eq!(
        fs::read(nas.root.join("files/existing.bin")).unwrap(),
        bytes
    );
    assert_eq!(
        fs::read_to_string(nas.root.join("system/certificate.pem")).unwrap(),
        certificate
    );
    assert_eq!(
        fs::read_to_string(nas.root.join("system/private-key.pem")).unwrap(),
        private_key
    );
    let backup = Connection::open(nas.root.join("system/inbox.pre-rust.sqlite3")).unwrap();
    assert_eq!(
        backup
            .query_row("SELECT count(*) FROM events", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        3
    );
    assert_eq!(
        backup
            .query_row("SELECT body FROM items WHERE sequence=7", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        text.to_string()
    );
    let backup_bytes = fs::read(nas.root.join("system/inbox.pre-rust.sqlite3")).unwrap();
    nas.restart();
    assert_eq!(nas.code, expected_code);
    assert_eq!(
        fs::read(nas.root.join("system/inbox.pre-rust.sqlite3")).unwrap(),
        backup_bytes
    );
    drop(backup);
    drop(db);
}
