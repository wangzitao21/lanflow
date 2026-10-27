use super::*;
use crate::sync_control::{CheckedRequest, Run};
use reqwest::{Client, Response};
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use std::io::{Seek, SeekFrom};
#[path = "sync_batches.rs"]
mod batches;

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
    let parsed = serde_json::from_slice::<Value>(&bytes);
    if !status.is_success() {
        let value = parsed.unwrap_or(Value::Null);
        let message = value["error"]
            .as_str()
            .unwrap_or(if status.as_u16() == 404 {
                "请将另一端更新到支持同步删除的新版"
            } else {
                "同步暂不可用"
            });
        // Accept known service states only when their HTTP status agrees.
        // Authentication and identity failures remain determined locally.
        let category = match (status.as_u16(), value["category"].as_str()) {
            (503, Some("paused")) => Some("paused"),
            (503, Some("not_ready")) => Some("not_ready"),
            (507, _) => Some("remote_storage"),
            _ => None,
        };
        return Err(match category {
            Some(category) => errors::api_category(status.as_u16(), category, message),
            None => errors::api(status.as_u16(), message),
        });
    }
    let value =
        parsed.map_err(|_| errors::api_category(502, "protocol", "Invalid sync response"))?;
    if !value.is_object() {
        return Err(errors::api_category(
            502,
            "protocol",
            "Invalid sync response",
        ));
    }
    Ok(value)
}

fn send_change(client: &Client, url: &str, event: &Value, run: &Run) -> Result<()> {
    let ack = response_json(
        run,
        client
            .post(format!("{url}/v3/changes"))
            .timeout(Duration::from_secs(12))
            .json(event)
            .send_checked(run)?,
    )?;
    if ack["ok"] != true {
        return Err(errors::api_category(
            502,
            "protocol",
            "Missing change acknowledgement",
        ));
    }
    Ok(())
}

fn validate_page(page: &Value, after: i64) -> Result<()> {
    let invalid = || errors::api_category(502, "protocol", "Invalid changes page or cursor");
    let records = page["items"].as_array().ok_or_else(invalid)?;
    if records.len() > 50
        || !page["more"].is_boolean()
        || (records.is_empty() && page["more"] == true)
    {
        return Err(invalid());
    }
    let mut cursor = after;
    for record in records {
        let sequence = record["sequence"]
            .as_i64()
            .filter(|sequence| *sequence > cursor)
            .ok_or_else(invalid)?;
        if !record["event"].is_object() {
            return Err(invalid());
        }
        id(&record["event"], "id")?;
        cursor = sequence;
    }
    if page["cursor"].as_i64() != Some(cursor) {
        return Err(invalid());
    }
    Ok(())
}

fn save_cursor(db: &Connection, key: &str, column: &str, value: i64) -> Result<()> {
    // column is selected exclusively by the two call sites below.
    db.execute(
        &format!("UPDATE cursors SET {column}=? WHERE endpoint=? AND {column}!=?"),
        params![value, key, value],
    )?;
    Ok(())
}

fn save_pull(db: &Connection, key: &str, sequence: i64, event: &Value) -> Result<()> {
    db.execute(
        "UPDATE cursors SET pulled=?,pulled_id=? WHERE endpoint=?",
        params![sequence, string(event, "id")?, key],
    )?;
    Ok(())
}

fn push_deletions(
    client: &Client,
    base: &str,
    key: &str,
    shared: &Database,
    run: &Run,
    mut after: i64,
    batched: bool,
) -> Result<()> {
    loop {
        let pending = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            db.prepare("SELECT id,body,sequence FROM events e WHERE sequence>?2 AND json_extract(body,'$.type')='delete' AND NOT EXISTS(SELECT 1 FROM seen s WHERE s.event_id=e.id AND s.endpoint=?1) ORDER BY sequence LIMIT 50")?
            .query_map(params![key,after],|r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,i64>(2)?)))?.collect::<std::result::Result<Vec<_>,_>>()?
        };
        if pending.is_empty() {
            break;
        }
        after = pending.last().unwrap().2;
        if batched {
            let values = pending
                .iter()
                .map(|(_, body, _)| serde_json::from_str(body))
                .collect::<std::result::Result<Vec<Value>, _>>()?;
            batches::send(client, base, &values, run)?;
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            let tx = db.transaction()?;
            for (id, _, _) in pending {
                tx.execute("INSERT OR IGNORE INTO seen VALUES(?,?)", params![id, key])?;
            }
            tx.commit()?;
            continue;
        }
        for (id, body, _) in pending {
            send_change(client, base, &serde_json::from_str(&body)?, run)?;
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute("INSERT OR IGNORE INTO seen VALUES(?,?)", params![id, key])?;
        }
    }
    Ok(())
}

fn pull_deletions(
    client: &Client,
    base: &str,
    root: &Path,
    key: &str,
    shared: &Database,
    run: &Run,
    epoch: &str,
    mut cursor: i64,
) -> Result<(std::collections::HashSet<String>, i64, String)> {
    let mut targets = std::collections::HashSet::new();
    loop {
        let page = response_json(
            run,
            client
                .get(format!("{base}/v3/deletions?after={cursor}"))
                .timeout(Duration::from_secs(12))
                .send_checked(run)?,
        )?;
        let invalid = || errors::api_category(502, "protocol", "Invalid deletion inventory");
        if page["historyEpoch"] != epoch {
            return Err(invalid());
        }
        let records = page["items"]
            .as_array()
            .filter(|rows| rows.len() <= 500)
            .ok_or_else(invalid)?;
        let hash = page["state"]["hash"]
            .as_str()
            .filter(|hash| valid_digest(hash))
            .ok_or_else(invalid)?
            .to_owned();
        let mut next = cursor;
        for record in records {
            next = record["sequence"]
                .as_i64()
                .filter(|value| *value > next)
                .ok_or_else(invalid)?;
            id(record, "id")?;
        }
        if page["cursor"].as_i64() != Some(next)
            || !page["more"].is_boolean()
            || (records.is_empty() && page["more"] == true)
        {
            return Err(invalid());
        }
        let local = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            reconciliation::deletion_state(&db)?
        };
        if local["hash"] == hash {
            let head = page["state"]["cursor"]
                .as_i64()
                .filter(|head| *head >= next)
                .ok_or_else(invalid)?;
            return Ok((targets, head, hash));
        }
        for record in records {
            let target = string(record, "id")?;
            let event = json!({"id":digest(format!("delete:{target}").as_bytes()),"type":"delete","target":target});
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            apply(root, &mut db, &event, Some(key))?;
            targets.insert(target.to_owned());
        }
        cursor = next;
        if page["more"] != true {
            return Ok((targets, cursor, hash));
        }
    }
}

fn reconcile_deletions(
    client: &Client,
    base: &str,
    root: &Path,
    key: &str,
    shared: &Database,
    run: &Run,
    page: &Value,
) -> Result<()> {
    let Some(epoch) = page["historyEpoch"].as_str() else {
        return Ok(());
    };
    if !page["capabilities"]
        .as_array()
        .is_some_and(|values| values.iter().any(|value| value == "deletionInventory"))
    {
        return Ok(());
    }
    let after = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let saved: i64 = db.query_row(
            "SELECT remote_deletions FROM cursors WHERE endpoint=?",
            [key],
            |r| r.get(0),
        )?;
        if saved > page["deletionState"]["cursor"].as_i64().unwrap_or(0) {
            0
        } else {
            saved
        }
    };
    let (mut remote, mut cursor, hash) =
        pull_deletions(client, base, root, key, shared, run, epoch, after)?;
    let local = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        reconciliation::deletion_state(&db)?
    };
    if local["hash"] != hash {
        // A restored database may have lost previously acknowledged tombstones.
        // Compare the full set rather than trusting the old send cursor/receipts.
        if after != 0 {
            let all = pull_deletions(client, base, root, key, shared, run, epoch, 0)?;
            remote = all.0;
            cursor = all.1;
        }
        let local = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            db.prepare("SELECT id FROM deleted ORDER BY id")?
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        for target in local.into_iter().filter(|target| !remote.contains(target)) {
            let event = json!({"id":digest(format!("delete:{target}").as_bytes()),"type":"delete","target":target});
            {
                let mut db = shared.lock().map_err(|_| "Database unavailable")?;
                let _mutation = run.mutation()?;
                apply(root, &mut db, &event, None)?;
            }
            send_change(client, base, &event, run)?;
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![string(&event, "id")?, key],
            )?;
        }
    }
    let db = shared.lock().map_err(|_| "Database unavailable")?;
    let _mutation = run.mutation()?;
    db.execute(
        "UPDATE cursors SET remote_deletions=? WHERE endpoint=?",
        params![cursor, key],
    )?;
    Ok(())
}

const CHUNK_BYTES: u64 = 4 * 1024 * 1024;
const PAGES_PER_PASS: usize = 20;

// Each pass moves a bounded chunk, allowing newly queued text/deletions and
// user controls to run between chunks without losing durable file progress.
#[cfg(test)]
pub(super) fn upload(
    client: &Client,
    url: &str,
    root: &Path,
    item: &Value,
    run: &Run,
) -> Result<(u64, bool)> {
    upload_part(client, url, root, item, run, &mut HashMap::new())
}

fn upload_part(
    client: &Client,
    url: &str,
    root: &Path,
    item: &Value,
    run: &Run,
    offsets: &mut HashMap<String, (bool, u64)>,
) -> Result<(u64, bool)> {
    let digest = string(item, "sha256")?;
    let size = item["size"].as_u64().ok_or("Invalid file size")?;
    let location = format!("{url}/v2/blobs/{digest}");
    let cache_key = format!("{digest}:{size}");
    if offsets.get(&cache_key).is_some_and(|saved| saved.1 == size) {
        return Ok((size, true));
    }
    let (resumable, offset) = if let Some(saved) = offsets.get(&cache_key) {
        *saved
    } else {
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
            offsets.insert(cache_key, (true, size));
            return Ok((size, true));
        }
        if !matches!(head.status().as_u16(), 200 | 404) {
            if head.status().as_u16() == 507 {
                return Err(errors::api_category(
                    507,
                    "remote_storage",
                    "Remote file is unavailable",
                ));
            }
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
        (resumable, offset)
    };
    let mut file = File::open(attachments::path(root, digest)).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            errors::api(425, "等待附件来源设备上线")
        } else {
            Box::new(error) as Box<dyn std::error::Error + Send + Sync>
        }
    })?;
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
        offsets.insert(cache_key, (true, offset + count));
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
    offsets.insert(cache_key, (true, size));
    Ok((size, true))
}

#[cfg(test)]
pub(super) fn download(
    client: &Client,
    url: &str,
    root: &Path,
    key: &str,
    item: &Value,
    run: &Run,
) -> Result<(u64, bool)> {
    download_part(client, url, root, key, item, run, &mut HashMap::new())
}

fn download_part(
    client: &Client,
    url: &str,
    root: &Path,
    key: &str,
    item: &Value,
    run: &Run,
    range_support: &mut HashMap<String, bool>,
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
        let cache_key = format!("{digest}:{size}");
        let ranges = if let Some(ranges) = range_support.get(&cache_key) {
            *ranges
        } else {
            let head = client
                .head(format!("{url}/v2/blobs/{digest}"))
                .timeout(Duration::from_secs(12))
                .send_checked(run)?;
            if head.status().as_u16() == 404 {
                return Err(errors::api(425, "等待附件来源设备上线"));
            }
            let head = head.error_for_status()?;
            let ranges = head
                .headers()
                .get(reqwest::header::ACCEPT_RANGES)
                .is_some_and(|v| v == "bytes");
            range_support.insert(cache_key, ranges);
            ranges
        };
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
    continuous: bool,
) -> Result<Option<(String, &'static str)>> {
    let _phase = run.file_phase()?;
    let started = std::time::Instant::now();
    let mut attempts = 0;
    let mut offsets = HashMap::new();
    let mut ranges = HashMap::new();
    let mut failure = None;
    loop {
        let jobs = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            transfers::scheduled(&db, key)?
        };
        if jobs.is_empty() {
            break;
        }
        for (direction, event_id, body, previous) in jobs {
            if continuous
                && attempts > 0
                && (attempts >= 16 || started.elapsed() >= Duration::from_millis(750))
            {
                return Ok(failure);
            }
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
            attempts += 1;
            let result = (|| -> Result<(u64, bool)> {
                let result = if direction == "upload" {
                    upload_part(client, url, root, item, run, &mut offsets)?
                } else {
                    download_part(client, url, root, key, item, run, &mut ranges)?
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
                        send_change(client, url, &event, run)?;
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
                                message_edits::mark_copy(&db, item_id, key)?;
                            }
                        }
                        transfers::complete(&db, key, &direction, &event_id, bytes)?;
                    }
                }
                Err(error) => {
                    offsets.clear();
                    ranges.clear();
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
        if !continuous {
            break;
        }
    }
    Ok(failure)
}

#[cfg(test)]
pub(super) fn synchronize(
    root: &Path,
    endpoint: &Value,
    known_revision: Option<i64>,
    run_id: Option<&str>,
) -> Result<Value> {
    synchronize_with_budget(root, endpoint, known_revision, run_id, false)
}

pub(super) fn synchronize_with_budget(
    root: &Path,
    endpoint: &Value,
    known_revision: Option<i64>,
    run_id: Option<&str>,
    continuous_files: bool,
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
    let deleted_before = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        reconciliation::deletion_state(&db)?["count"]
            .as_i64()
            .unwrap_or(0)
    };
    let (mut pushed, mut pulled, favorites_before, snapshots_before, edits_before) = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        let _mutation = run.mutation()?;
        db.execute("INSERT OR IGNORE INTO cursors(endpoint) VALUES(?)", [key])?;
        db.query_row(
            "SELECT pushed,pulled,favorites_supported,favorite_snapshots_supported,edits_supported FROM cursors WHERE endpoint=?",
            [key],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, bool>(3)?,
                    r.get::<_, bool>(4)?,
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
    let response = client
        .get(format!(
            "{base}/v3/changes?after={pulled}&capabilities=favorites,favoriteSnapshots,messageEdits"
        ))
        .timeout(Duration::from_secs(12))
        .send_checked(run)
        .and_then(|response| response_json(run, response));
    let mut page = match response {
        Ok(page) => page,
        Err(error) => {
            if run.check().is_ok() {
                let _ = transfers::complete_local_downloads(root, &shared);
            }
            return Err(error);
        }
    };
    if let Some(epoch) = page["historyEpoch"].as_str() {
        if !valid_id(epoch) {
            return Err(errors::api_category(
                502,
                "protocol",
                "Invalid history identity",
            ));
        }
        let (saved, checkpoint): (String, String) = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            db.query_row(
                "SELECT remote_epoch,pulled_id FROM cursors WHERE endpoint=?",
                [key],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?
        };
        if saved != epoch
            || page["head"].as_i64().is_some_and(|head| head < pulled)
            || (pulled > 0
                && !checkpoint.is_empty()
                && page["afterId"].as_str() != Some(checkpoint.as_str()))
        {
            {
                let mut db = shared.lock().map_err(|_| "Database unavailable")?;
                let _mutation = run.mutation()?;
                let tx = db.transaction()?;
                tx.execute("UPDATE cursors SET pushed=0,pulled=0,pulled_id='',remote_deletions=0,remote_epoch=? WHERE endpoint=?",params![epoch,key])?;
                tx.execute("DELETE FROM seen WHERE endpoint=?", [key])?;
                tx.execute("DELETE FROM copies WHERE endpoint=?", [key])?;
                tx.execute("UPDATE transfer_jobs SET state='queued',error=NULL,error_category=NULL,retry_after=0,failures=0,completed_at=0 WHERE endpoint=? AND direction='upload' AND state IN ('completed','failed')",[key])?;
                tx.commit()?;
            }
            pushed = 0;
            pulled = 0;
            page=response_json(run,client.get(format!("{base}/v3/changes?after=0&capabilities=favorites,favoriteSnapshots,messageEdits,deletionInventory"))
                .timeout(Duration::from_secs(12)).send_checked(run)?)?;
        }
    }
    validate_page(&page, pulled)?;
    let batches_supported = page["capabilities"]
        .as_array()
        .is_some_and(|values| values.iter().any(|v| v == "changeBatches"));
    push_deletions(&client, base, key, &shared, run, pushed, batches_supported)?;
    reconcile_deletions(&client, base, root, key, &shared, run, &page)?;
    let have_new_deletions = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        reconciliation::deletion_state(&db)?["count"].as_i64() != Some(deleted_before)
    };
    if !have_new_deletions {
        transfers::complete_local_downloads(root, &shared)?;
    }
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
    let edits_supported = page["capabilities"]
        .as_array()
        .is_some_and(|values| values.iter().any(|v| v == "messageEdits"));
    if favorites_supported != favorites_before
        || snapshots_supported != snapshots_before
        || edits_supported != edits_before
    {
        let replay = (favorites_supported && !favorites_before)
            || (snapshots_supported && !snapshots_before)
            || (edits_supported && !edits_before);
        {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute("UPDATE cursors SET favorites_supported=?,favorite_snapshots_supported=?,pulled=CASE WHEN ? THEN 0 ELSE pulled END WHERE endpoint=?",
                params![favorites_supported,snapshots_supported,replay,key])?;
            db.execute("UPDATE cursors SET edits_supported=?,pushed=CASE WHEN ? THEN 0 ELSE pushed END WHERE endpoint=?", params![edits_supported,edits_supported && !edits_before,key])?;
            if edits_supported && !edits_before {
                pushed = 0;
            }
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
                        "{base}/v3/changes?after=0&capabilities=favorites,favoriteSnapshots,messageEdits"
                    ))
                    .timeout(Duration::from_secs(12))
                    .send_checked(run)?,
            )?;
            validate_page(&page, pulled)?;
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
        let mut favorite_events = Vec::new();
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
            if batches_supported {
                favorite_events.push(event);
                continue;
            }
            send_change(&client, base, &event, run)?;
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![event_id, key],
            )?;
        }
        if !favorite_events.is_empty() {
            batches::send(&client, base, &favorite_events, run)?;
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            let tx = db.transaction()?;
            for event in favorite_events {
                tx.execute(
                    "INSERT OR IGNORE INTO seen VALUES(?,?)",
                    params![string(&event, "id")?, key],
                )?;
            }
            tx.commit()?;
        }
    }
    for _ in 0..PAGES_PER_PASS {
        let batch = {
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            if batches_supported {
                batches::page(&db, pushed, key)?
            } else {
                super::page(&db, pushed)?
            }
        };
        let records = batch["items"].as_array().ok_or("Invalid changes")?;
        if batches_supported {
            pushed = batches::push_page(
                &client,
                base,
                key,
                &shared,
                run,
                records,
                batch["cursor"].as_i64().ok_or("Invalid outgoing cursor")?,
                favorites_supported,
                snapshots_supported,
                edits_supported,
            )?;
            if batch["more"] != true {
                break;
            }
            continue;
        }
        for record in records {
            run.check()?;
            let sequence = record["sequence"].as_i64().ok_or("Invalid sequence")?;
            let event = &record["event"];
            let event_id = string(event, "id")?;
            if (event["type"] == "favorite" && !favorites_supported)
                || (event["type"] == "favorite_snapshot" && !snapshots_supported)
                || (event["type"] == "edit" && !edits_supported)
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
                        send_change(&client, base, event, run)?;
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
                        send_change(&client, base, &tombstone, run)?;
                    } else {
                        if event["item"]["kind"] != "text" {
                            let db = shared.lock().map_err(|_| "Database unavailable")?;
                            let _mutation = run.mutation()?;
                            transfers::enqueue(&db, key, "upload", record)?;
                            pushed = sequence;
                            save_cursor(&db, key, "pushed", pushed)?;
                            continue;
                        }
                        send_change(&client, base, event, run)?;
                    }
                } else {
                    send_change(&client, base, event, run)?;
                }
            }
            let db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            db.execute(
                "INSERT OR IGNORE INTO seen VALUES(?,?)",
                params![event_id, key],
            )?;
            if event["type"] == "item" || event["type"] == "edit" {
                message_edits::mark_copy(
                    &db,
                    if event["type"] == "item" {
                        string(&event["item"], "id")?
                    } else {
                        string(event, "target")?
                    },
                    key,
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
        // Validate the whole page before applying any tombstone or cursor.
        validate_page(&page, pulled)?;
        let records = page["items"].as_array().ok_or("Invalid changes")?;
        if records.len() > 50 {
            return Err("Changes page too large".into());
        }
        // Apply deletions before additions in the same page to avoid a transient resurrection.
        {
            let mut db = shared.lock().map_err(|_| "Database unavailable")?;
            let _mutation = run.mutation()?;
            let tx = db.transaction()?;
            for record in records.iter().filter(|r| {
                r["event"]["type"] == "delete"
                    || (events::is_favorite(&r["event"])
                        && r["event"]["favorite"]["value"] == false)
            }) {
                run.check()?;
                events::apply_transaction(root, &tx, &record["event"], Some(key))?;
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
                    let removed = deleted(&tx, string(&event["item"], "id")?)?;
                    if !removed && event["item"]["kind"] != "text" {
                        transfers::enqueue(&tx, key, "download", record)?;
                        pulled = sequence;
                        continue;
                    }
                }
                events::apply_transaction(root, &tx, event, Some(key))?;
                if events::is_favorite(event)
                    && events::transfer_item(event).is_some_and(|item| item["kind"] != "text")
                    && favorites::retained(&tx, event)?
                {
                    transfers::enqueue(&tx, key, "download", record)?;
                }
                pulled = sequence;
            }
            if let Some(record) = records.last() {
                save_pull(&tx, key, pulled, &record["event"])?;
            }
            tx.commit()?;
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
                    "{base}/v3/changes?after={pulled}&capabilities=favorites,favoriteSnapshots,messageEdits"
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
    let deleted_after = {
        let db = shared.lock().map_err(|_| "Database unavailable")?;
        reconciliation::deletion_state(&db)?["count"]
            .as_i64()
            .unwrap_or(0)
    };
    // Publish removals to the UI before starting potentially slow file chunks.
    let failure = if deleted_after != deleted_before {
        None
    } else {
        run_jobs(&client, base, root, key, &shared, run, continuous_files)?
    };
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
