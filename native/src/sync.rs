use super::*;
use crate::sync_control::{CheckedRequest, Run};
use reqwest::{Client, Response};
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use std::io::{Seek, SeekFrom};

type Clients = HashMap<(PathBuf, String), (Value, Client)>;
static CLIENTS: OnceLock<Mutex<Clients>> = OnceLock::new();

pub(super) fn forget_clients(root: &Path, key: Option<&str>) {
    if let Ok(mut clients) = CLIENTS.get_or_init(Default::default).lock() {
        clients
            .retain(|(path, endpoint), _| path != root || key.is_some_and(|key| endpoint != key));
    }
}

#[derive(Debug)]
struct PinnedCertificate(String);
impl ServerCertVerifier for PinnedCertificate {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        if digest(cert.as_ref()) == self.0 {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "Device certificate identity mismatch".into(),
            ))
        }
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn client(root: &Path, endpoint: &Value, run: &Run) -> Result<Client> {
    run.check()?;
    let key = (root.to_owned(), string(endpoint, "key")?.to_owned());
    if let Some((saved, client)) = CLIENTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Sync unavailable")?
        .get(&key)
        && saved == endpoint
    {
        return Ok(client.clone());
    }
    let fingerprint = string(endpoint, "fingerprint")?;
    if !valid_digest(fingerprint) {
        return Err("Invalid certificate identity".into());
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedCertificate(fingerprint.to_owned())))
        .with_no_client_auth();
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        reqwest::header::AUTHORIZATION,
        format!("Bearer {}", string(endpoint, "token")?).parse()?,
    );
    if let Some(device) = endpoint["deviceId"].as_str() {
        headers.insert("X-Lanflow-Device", device.parse()?);
    }
    let client = Client::builder()
        .use_preconfigured_tls(tls)
        .connect_timeout(Duration::from_secs(3))
        .tcp_keepalive(None)
        .pool_idle_timeout(Duration::from_secs(90))
        .pool_max_idle_per_host(2)
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .default_headers(headers)
        .build()?;
    let mut clients = CLIENTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Sync unavailable")?;
    let _mutation = run.mutation()?;
    if clients.len() >= 64 {
        clients.clear();
    }
    clients.insert(key, (endpoint.clone(), client.clone()));
    Ok(client)
}

fn response_json(run: &Run, mut response: Response) -> Result<Value> {
    let status = response.status();
    let mut bytes = Vec::new();
    while let Some(chunk) = sync_control::response_chunk(&mut response, run)? {
        if bytes.len() + chunk.len() > 32 * 1024 * 1024 {
            return Err("Response too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).unwrap_or(json!({}));
    if !status.is_success() {
        return Err(errors::api(
            status.as_u16(),
            value["error"]
                .as_str()
                .unwrap_or(if status.as_u16() == 404 {
                    "请将另一端更新到支持同步删除的新版"
                } else {
                    "同步暂不可用"
                }),
        ));
    }
    Ok(value)
}

fn save_cursor(db: &Connection, key: &str, column: &str, value: i64) -> Result<()> {
    // column is selected exclusively by the two call sites below.
    db.execute(
        &format!("UPDATE cursors SET {column}=? WHERE endpoint=?"),
        params![value, key],
    )?;
    Ok(())
}

const CHUNK_BYTES: u64 = 4 * 1024 * 1024;
const PAGES_PER_PASS: usize = 20;

// Each pass moves a bounded chunk, allowing newly queued text/deletions and
// user controls to run between chunks without losing durable file progress.
pub(super) fn upload(
    client: &Client,
    url: &str,
    root: &Path,
    item: &Value,
    run: &Run,
) -> Result<(u64, bool)> {
    let digest = string(item, "sha256")?;
    let size = item["size"].as_u64().ok_or("Invalid file size")?;
    let location = format!("{url}/v2/blobs/{digest}");
    let head = client
        .head(&location)
        .query(&[("size", size)])
        .timeout(Duration::from_secs(12))
        .send_checked(run)?;
    if head.status().as_u16() == 200
        && head
            .headers()
            .get(reqwest::header::CONTENT_LENGTH)
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok())
            == Some(size)
    {
        return Ok((size, true));
    }
    if !matches!(head.status().as_u16(), 200 | 404) {
        return Err(errors::api(
            head.status().as_u16(),
            "Remote file is unavailable",
        ));
    }
    let resumable = head
        .headers()
        .get("X-Lanflow-Resumable")
        .is_some_and(|v| v == "1");
    let offset = head
        .headers()
        .get("X-Lanflow-Offset")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);
    let mut file = File::open(attachments::path(root, digest))?;
    if file.metadata()?.len() != size {
        return Err("Local file is incomplete".into());
    }
    if resumable && size > 0 {
        if offset >= size {
            return Err("Invalid remote upload offset".into());
        }
        let count = CHUNK_BYTES.min(size - offset);
        file.seek(SeekFrom::Start(offset))?;
        let ack = response_json(
            run,
            client
                .put(location)
                .header(
                    reqwest::header::CONTENT_RANGE,
                    format!("bytes {}-{}/{}", offset, offset + count - 1, size),
                )
                .send_file_checked(
                    file,
                    count,
                    if offset + count == size { size } else { 0 },
                    run,
                )?,
        )?;
        if ack["offset"].as_u64() != Some(offset + count) {
            return Err("Remote upload offset mismatch".into());
        }
        let complete = offset + count == size;
        if complete && ack["sha256"] != digest {
            return Err("Remote file checksum mismatch".into());
        }
        return Ok((offset + count, complete));
    }
    // Old peers keep their whole-file endpoint. Never send them a chunk as if
    // it were a complete file.
    let ack = response_json(
        run,
        client
            .put(location)
            .send_file_checked(file, size, size, run)?,
    )?;
    if ack["sha256"] != digest {
        return Err("Remote file checksum mismatch".into());
    }
    Ok((size, true))
}

pub(super) fn download(
    client: &Client,
    url: &str,
    root: &Path,
    key: &str,
    item: &Value,
    run: &Run,
) -> Result<(u64, bool)> {
    let digest = string(item, "sha256")?;
    let size = item["size"].as_u64().ok_or("Invalid size")?;
    let target = attachments::path(root, digest);
    if verified_files::check(&target, digest, size)? {
        return Ok((size, true));
    }
    let temp = layout::incoming(root).join(format!(
        "download-{}.part",
        super::digest(format!("{key}:{digest}").as_bytes())
    ));
    let mut offset = fs::metadata(&temp).map(|m| m.len()).unwrap_or(0);
    if offset > size {
        File::create(&temp)?;
        offset = 0;
    }
    if offset < size || size == 0 {
        let head = client
            .head(format!("{url}/v2/blobs/{digest}"))
            .timeout(Duration::from_secs(12))
            .send_checked(run)?
            .error_for_status()?;
        let ranges = head
            .headers()
            .get(reqwest::header::ACCEPT_RANGES)
            .is_some_and(|v| v == "bytes");
        if !ranges {
            offset = 0;
        }
        let end = (offset + CHUNK_BYTES).min(size).saturating_sub(1);
        let mut request = client.get(format!("{url}/v2/blobs/{digest}"));
        if size > 0 && ranges {
            request = request.header(reqwest::header::RANGE, format!("bytes={offset}-{end}"));
        }
        let mut response = request.send_checked(run)?.error_for_status()?;
        let expected;
        if response.status().as_u16() == 206 {
            let range = format!("bytes {offset}-{end}/{size}");
            if response
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                != Some(range.as_str())
            {
                return Err("Remote file range mismatch".into());
            }
            expected = end + 1 - offset;
        } else if response.status().as_u16() == 200 {
            // A legacy peer ignored Range; restart safely from its full body.
            offset = 0;
            expected = size;
        } else {
            return Err("Invalid file response".into());
        }
        if response.content_length() != Some(expected) {
            return Err("Remote file size mismatch".into());
        }
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(offset == 0)
            .open(&temp)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut received = 0;
        let result = (|| -> Result<()> {
            while let Some(buffer) = sync_control::response_chunk(&mut response, run)? {
                received += buffer.len() as u64;
                if received > expected {
                    return Err("File exceeded advertised range".into());
                }
                file.write_all(&buffer)?;
            }
            if received != expected {
                return Err("Incomplete file chunk".into());
            }
            Ok(())
        })();
        file.sync_all()?;
        result?;
        offset += received;
    }
    if offset < size {
        return Ok((offset, false));
    }
    run.check()?;
    // Hash the complete file before making it visible, including any prefix
    // saved by a previous process or downloaded from a different connection.
    if !verified_files::check(&temp, digest, size)? {
        fs::remove_file(&temp)?;
        return Err("File checksum mismatch".into());
    }
    run.check()?;
    blobs::publish(root, &temp, digest)?;
    Ok((size, true))
}

fn run_jobs(
    client: &Client,
    url: &str,
    root: &Path,
    key: &str,
    shared: &Database,
    run: &Run,
) -> Result<Option<(String, &'static str)>> {
    let jobs = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        transfers::scheduled(&db, key)?
    };
    let mut failure = None;
    for (direction, event_id, body, previous) in jobs {
        run.check()?;
        let event: Value = serde_json::from_str(&body)?;
        let item = events::transfer_item(&event).ok_or("Invalid transfer event")?;
        let item_id = string(item, "id")?;
        let favorite = events::is_favorite(&event);
        {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            if !transfers::active(&db, key, &direction, &event_id)? {
                continue;
            }
            if (!favorite && deleted(&db, item_id)?)
                || (favorite && !favorites::retained(&db, &event)?)
            {
                db.execute(
                    "DELETE FROM transfer_jobs WHERE endpoint=? AND direction=? AND event_id=?",
                    params![key, direction, event_id],
                )?;
                continue;
            }
            transfers::attempted(&db, key, &direction, &event_id)?;
        }
        let result = (|| -> Result<(u64, bool)> {
            let result = if direction == "upload" {
                upload(client, url, root, item, run)?
            } else {
                download(client, url, root, key, item, run)?
            };
            if result.1 && direction == "upload" {
                let active = {
                    let db = shared.lock().map_err(|_| "Database unavailable")?;
                    transfers::active(&db, key, &direction, &event_id)?
                        && if favorite {
                            favorites::retained(&db, &event)?
                        } else {
                            !deleted(&db, item_id)?
                        }
                };
                if active {
                    response_json(
                        run,
                        client
                            .post(format!("{url}/v3/changes"))
                            .timeout(Duration::from_secs(12))
                            .json(&event)
                            .send_checked(run)?,
                    )?;
                }
            }
            if result.1 && direction == "download" {
                run.check()?;
                attachments::register(root, shared, item)?;
            }
            Ok(result)
        })();
        run.check()?;
        let mut db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        if !transfers::active(&db, key, &direction, &event_id)? {
            continue;
        }
        match result {
            Ok((bytes, complete)) => {
                transfers::progress(&db, key, &direction, &event_id, bytes, None)?;
                if complete {
                    if direction == "download" {
                        apply(
                            root,
                            &mut db,
                            &event,
                            if favorite { None } else { Some(key) },
                        )?;
                        if favorite {
                            favorites::touch(&db, &event)?;
                        }
                    } else if favorite || !deleted(&db, item_id)? {
                        db.execute(
                            "INSERT OR IGNORE INTO seen VALUES(?,?)",
                            params![event_id, key],
                        )?;
                        if !favorite {
                            db.execute(
                                "INSERT OR IGNORE INTO copies VALUES(?,?)",
                                params![item_id, key],
                            )?;
                        }
                    }
                    transfers::complete(&db, key, &direction, &event_id, bytes)?;
                }
            }
            Err(error) => {
                let message = error.to_string();
                let previous = if direction == "download" {
                    let partial = layout::incoming(root).join(format!(
                        "download-{}.part",
                        digest(format!("{key}:{}", string(item, "sha256")?).as_bytes())
                    ));
                    fs::metadata(partial).map(|m| m.len()).unwrap_or(previous)
                } else {
                    previous
                };
                transfers::progress(
                    &db,
                    key,
                    &direction,
                    &event_id,
                    previous,
                    Some(error.as_ref()),
                )?;
                failure.get_or_insert((message, errors::category(error.as_ref())));
            }
        }
    }
    Ok(failure)
}

pub(super) fn synchronize(
    root: &Path,
    endpoint: &Value,
    known_revision: Option<i64>,
    run_id: Option<&str>,
) -> Result<Value> {
    let key = string(endpoint, "key")?;
    let run_id = match run_id {
        Some(value) => value.to_owned(),
        None => sync_control::begin(root, key)?,
    };
    let run = Run::acquire(root, key, &run_id)?;
    let run = &run;
    let client = client(root, endpoint, run)?;
    let base = string(endpoint, "url")?.trim_end_matches('/');
    let uri = reqwest::Url::parse(base)?;
    if uri.scheme() != "https" || !uri.username().is_empty() || uri.password().is_some() {
        return Err("Invalid sync address".into());
    }
    let key = string(endpoint, "key")?;
    let shared = database(root)?;
    let (mut pushed, mut pulled, favorites_before, snapshots_before) = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        db.execute("INSERT OR IGNORE INTO cursors(endpoint) VALUES(?)", [key])?;
        db.query_row(
            "SELECT pushed,pulled,favorites_supported,favorite_snapshots_supported FROM cursors WHERE endpoint=?",
            [key],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, bool>(3)?,
                ))
            },
        )?
    };
    {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        transfers::queue_outgoing(&db, key, pushed)?;
    }
    // Probe before publishing to an old server, so no deletion/profile is silently lost.
    let mut page = response_json(
        run,
        client
            .get(format!(
                "{base}/v3/changes?after={pulled}&capabilities=favorites,favoriteSnapshots"
            ))
            .timeout(Duration::from_secs(12))
            .send_checked(run)?,
    )?;
    if page["protocol"].as_i64().unwrap_or(0) < 3 {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let categories: bool =
            db.query_row("SELECT EXISTS(SELECT 1 FROM conversations)", [], |r| {
                r.get(0)
            })?;
        if categories {
            return Err("请更新另一端的 LanFlow 或 NAS，以同步分类会话".into());
        }
    }
    let favorites_supported = page["capabilities"]
        .as_array()
        .is_some_and(|values| values.iter().any(|value| value == "favorites"));
    let snapshots_supported = page["capabilities"]
        .as_array()
        .is_some_and(|values| values.iter().any(|value| value == "favoriteSnapshots"));
    if favorites_supported != favorites_before || snapshots_supported != snapshots_before {
        let replay = (favorites_supported && !favorites_before)
            || (snapshots_supported && !snapshots_before);
        {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute("UPDATE cursors SET favorites_supported=?,favorite_snapshots_supported=?,pulled=CASE WHEN ? THEN 0 ELSE pulled END WHERE endpoint=?",
                params![favorites_supported,snapshots_supported,replay,key])?;
        }
        if replay && pulled != 0 {
            pulled = 0;
            // A previously older client may have advanced past filtered favorite
            // events. Replaying existing metadata is idempotent and repairs that
            // gap once when optional support is negotiated.
            page = response_json(
                run,
                client
                    .get(format!(
                        "{base}/v3/changes?after=0&capabilities=favorites,favoriteSnapshots"
                    ))
                    .timeout(Duration::from_secs(12))
                    .send_checked(run)?,
            )?;
        }
    }
    let mut more_favorites = false;
    {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        if favorites_supported {
            transfers::queue_favorites(&db, key, pushed, snapshots_supported)?;
        }
        db.execute("DELETE FROM transfer_jobs WHERE endpoint=?1 AND direction='upload' AND ((?2=0 AND json_extract(body,'$.type')='favorite') OR (?3=0 AND json_extract(body,'$.type')='favorite_snapshot'))",params![key,favorites_supported,snapshots_supported])?;
    }
    if favorites_supported {
        // Peers upgraded after this cursor advanced still need the latest local
        // favorite state. Unrecognized optional events were deliberately skipped.
        let pending = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let mut statement = db.prepare("SELECT e.id,e.body,e.sequence FROM favorites f JOIN events e ON e.id=CASE WHEN ?2=0 THEN COALESCE(json_extract(f.body,'$.stateEventId'),f.event_id) ELSE f.event_id END WHERE NOT EXISTS(SELECT 1 FROM seen s WHERE s.event_id=e.id AND s.endpoint=?1) AND (json_extract(e.body,'$.favorite.value')=0 OR NOT EXISTS(SELECT 1 FROM transfer_jobs j WHERE j.endpoint=?1 AND j.direction='upload' AND j.event_id=e.id)) ORDER BY e.sequence LIMIT 51")?;
            statement
                .query_map(params![key, snapshots_supported], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        more_favorites = pending.len() > 50;
        for (event_id, body, sequence) in pending.into_iter().take(50) {
            let event: Value = serde_json::from_str(&body)?;
            if event["favorite"]["value"] == true
                && events::transfer_item(&event).is_some_and(|item| item["kind"] != "text")
            {
                let db = shared.lock().map_err(|_| "Database unavailable")?;
                let _mutation = run.mutation()?;
                if favorites::retained(&db, &event)? {
                    transfers::enqueue(
                        &db,
                        key,
                        "upload",
                        &json!({"sequence":sequence,"event":event}),
                    )?;
                    continue;
                }
            }
            response_json(
                run,
                client
                    .post(format!("{base}/v3/changes"))
                    .timeout(Duration::from_secs(12))
                    .json(&event)
                    .send_checked(run)?,
            )?;
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![event_id, key],
            )?;
        }
    }
    for _ in 0..PAGES_PER_PASS {
        let batch = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            super::page(&db, pushed)?
        };
        let records = batch["items"].as_array().ok_or("Invalid changes")?;
        for record in records {
            run.check()?;
            let sequence = record["sequence"].as_i64().ok_or("Invalid sequence")?;
            let event = &record["event"];
            let event_id = string(event, "id")?;
            if (event["type"] == "favorite" && !favorites_supported)
                || (event["type"] == "favorite_snapshot" && !snapshots_supported)
            {
                let db = shared.lock().map_err(|_| "Database unavailable")?;
                let _mutation = run.mutation()?;
                pushed = sequence;
                save_cursor(&db, key, "pushed", pushed)?;
                continue;
            }
            let skip = {
                let db = shared.lock().map_err(|_| "Database unavailable")?;
                db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM seen WHERE event_id=? AND endpoint=?)",
                    params![event_id, key],
                    |r| r.get::<_, bool>(0),
                )?
            };
            if !skip {
                if events::is_favorite(event) {
                    let retained = {
                        let db = shared.lock().map_err(|_| "Database unavailable")?;
                        let _mutation = run.mutation()?;
                        let retained = favorites::retained(&db, event)?;
                        if retained
                            && event["favorite"]["value"] == true
                            && events::transfer_item(event)
                                .is_some_and(|item| item["kind"] != "text")
                        {
                            transfers::enqueue(&db, key, "upload", record)?;
                            pushed = sequence;
                            save_cursor(&db, key, "pushed", pushed)?;
                            continue;
                        }
                        retained
                    };
                    // A cleared favorite must not be recreated by historical
                    // additions. The latest false state still propagates.
                    if retained
                        || event["favorite"]["value"] != true
                        || !event["favorite"]["item"].is_object()
                    {
                        response_json(
                            run,
                            client
                                .post(format!("{base}/v3/changes"))
                                .timeout(Duration::from_secs(12))
                                .json(event)
                                .send_checked(run)?,
                        )?;
                    }
                } else if event["type"] == "item" {
                    let removed = {
                        let db = shared.lock().map_err(|_| "Database unavailable")?;
                        deleted(&db, string(&event["item"], "id")?)?
                    };
                    // Send tombstones before any stale payload. Deleted content is never uploaded.
                    if removed {
                        let target = string(&event["item"], "id")?;
                        let tombstone = json!({"id":digest(format!("delete:{target}").as_bytes()),"type":"delete","target":target});
                        response_json(
                            run,
                            client
                                .post(format!("{base}/v3/changes"))
                                .timeout(Duration::from_secs(12))
                                .json(&tombstone)
                                .send_checked(run)?,
                        )?;
                    } else {
                        if event["item"]["kind"] != "text" {
                            let db = shared.lock().map_err(|_| "Database unavailable")?;
                            let _mutation = run.mutation()?;
                            transfers::enqueue(&db, key, "upload", record)?;
                            pushed = sequence;
                            save_cursor(&db, key, "pushed", pushed)?;
                            continue;
                        }
                        response_json(
                            run,
                            client
                                .post(format!("{base}/v3/changes"))
                                .timeout(Duration::from_secs(12))
                                .json(event)
                                .send_checked(run)?,
                        )?;
                    }
                } else {
                    response_json(
                        run,
                        client
                            .post(format!("{base}/v3/changes"))
                            .timeout(Duration::from_secs(12))
                            .json(event)
                            .send_checked(run)?,
                    )?;
                }
            }
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![event_id, key],
            )?;
            if event["type"] == "item" && !deleted(&db, string(&event["item"], "id")?)? {
                db.execute(
                    "INSERT OR IGNORE INTO copies VALUES(?,?)",
                    params![string(&event["item"], "id")?, key],
                )?;
            }
            pushed = sequence;
            save_cursor(&db, key, "pushed", pushed)?;
        }
        if batch["more"] != true {
            break;
        }
    }
    let mut more_pulled = false;
    for page_index in 0..PAGES_PER_PASS {
        let records = page["items"].as_array().ok_or("Invalid changes")?;
        if records.len() > 50 {
            return Err("Changes page too large".into());
        }
        // Apply deletions before additions in the same page to avoid a transient resurrection.
        for record in records.iter().filter(|r| {
            r["event"]["type"] == "delete"
                || (events::is_favorite(&r["event"]) && r["event"]["favorite"]["value"] == false)
        }) {
            run.check()?;
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            apply(root, &mut db, &record["event"], Some(key))?;
        }
        for record in records {
            run.check()?;
            let sequence = record["sequence"].as_i64().ok_or("Invalid sequence")?;
            if sequence <= pulled {
                return Err("Invalid change order".into());
            }
            let event = &record["event"];
            if event["type"] == "item" {
                validate_item(&event["item"])?;
                let removed = {
                    let db = shared.lock().map_err(|_| "Database unavailable")?;
                    deleted(&db, string(&event["item"], "id")?)?
                };
                if !removed && event["item"]["kind"] != "text" {
                    let db = shared.lock().map_err(|_| "Database unavailable")?;
                    let _mutation = run.mutation()?;
                    transfers::enqueue(&db, key, "download", record)?;
                    pulled = sequence;
                    save_cursor(&db, key, "pulled", pulled)?;
                    continue;
                }
            }
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            apply(root, &mut db, event, Some(key))?;
            if events::is_favorite(event)
                && events::transfer_item(event).is_some_and(|item| item["kind"] != "text")
                && favorites::retained(&db, event)?
            {
                transfers::enqueue(&db, key, "download", record)?;
            }
            pulled = sequence;
            save_cursor(&db, key, "pulled", pulled)?;
        }
        if page["cursor"].as_i64() != Some(pulled) || (records.is_empty() && page["more"] == true) {
            return Err("Invalid change cursor".into());
        }
        more_pulled = page["more"] == true;
        if !more_pulled || page_index + 1 == PAGES_PER_PASS {
            break;
        }
        page = response_json(
            run,
            client
                .get(format!(
                    "{base}/v3/changes?after={pulled}&capabilities=favorites,favoriteSnapshots"
                ))
                .timeout(Duration::from_secs(12))
                .send_checked(run)?,
        )?;
    }
    {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        transfers::queue_missing_favorites(root, &db, key)?;
    }
    let failure = run_jobs(&client, base, root, key, &shared, run)?;
    run.check()?;
    let db = shared.lock().map_err(|_| "Database unavailable")?;
    let mut result = snapshot_since(&db, known_revision)?;
    result["moreTransfers"] = json!(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM transfer_jobs WHERE endpoint=? AND state='queued')",
        [key],
        |r| r.get::<_, bool>(0)
    )?);
    result["transferError"] = json!(failure.as_ref().map(|(message, _)| message));
    result["transferErrorCategory"] = json!(failure.as_ref().map(|(_, category)| category));
    result["nextRetry"] = json!(db.query_row(
        "SELECT MIN(retry_after) FROM transfer_jobs WHERE endpoint=? AND state='failed'",
        [key],
        |r| r.get::<_, Option<i64>>(0)
    )?);
    let more_pushed: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM events WHERE sequence>? AND NOT EXISTS(SELECT 1 FROM seen WHERE seen.event_id=events.id AND endpoint=?))", params![pushed,key], |r| r.get(0))?;
    result["moreChanges"] = json!(more_pushed || more_pulled || more_favorites);
    Ok(result)
}
