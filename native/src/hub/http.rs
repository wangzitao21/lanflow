use super::*;
use http_body_util::{BodyExt, Full, combinators::UnsyncBoxBody};
use hyper::{
    Request, Response,
    body::{Bytes, Frame, Incoming},
};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

type Error = Box<dyn std::error::Error + Send + Sync>;
type Body = UnsyncBoxBody<Bytes, Error>;
type Reply = Response<Body>;

fn bytes_body(bytes: Vec<u8>) -> Body {
    Full::new(Bytes::from(bytes))
        .map_err(|never| match never {})
        .boxed_unsync()
}

fn reply(status: u16, value: Value) -> Reply {
    let body = serde_json::to_vec(&value).unwrap_or_default();
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json; charset=utf-8")
        .header("Cache-Control", "no-store")
        .header("Content-Length", body.len())
        .body(bytes_body(body))
        .expect("static response headers")
}

fn header<'a>(request: &'a Request<Incoming>, name: &str) -> Result<Option<&'a str>> {
    let mut values = request.headers().get_all(name).iter();
    let value = values.next();
    if values.next().is_some() {
        return Err(errors::api(400, "Duplicate request header"));
    }
    value
        .map(|value| value.to_str().map_err(Into::into))
        .transpose()
}

fn length(request: &Request<Incoming>, maximum: u64) -> Result<u64> {
    let text = header(request, "content-length")?
        .ok_or_else(|| errors::api(411, "Content-Length is required"))?;
    if request.headers().contains_key("transfer-encoding")
        || text.is_empty()
        || !text.bytes().all(|c| c.is_ascii_digit())
    {
        return Err(errors::api(411, "One Content-Length is required"));
    }
    let size = text
        .parse::<u64>()
        .map_err(|_| errors::api(413, "Content too large"))?;
    if size > maximum {
        return Err(errors::api(413, "Content too large"));
    }
    Ok(size)
}

fn query(request: &Request<Incoming>, name: &str) -> Result<Option<String>> {
    let url = reqwest::Url::parse(&format!("https://localhost{}", request.uri()))?;
    Ok(url
        .query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned()))
}

async fn read_json(mut request: Request<Incoming>) -> Result<Value> {
    let expected = length(&request, 1024 * 1024)?;
    let mut bytes = Vec::with_capacity(expected as usize);
    while let Some(frame) =
        tokio::time::timeout(Duration::from_secs(30), request.body_mut().frame()).await?
    {
        let frame = frame.map_err(|_| errors::api(400, "Incomplete request"))?;
        if let Ok(data) = frame.into_data() {
            if bytes.len() + data.len() > expected as usize {
                return Err(errors::api(400, "Request exceeds declared length"));
            }
            bytes.extend_from_slice(&data);
        }
    }
    if bytes.len() != expected as usize {
        return Err(errors::api(400, "Incomplete request"));
    }
    Ok(serde_json::from_slice(&bytes)?)
}

struct FileBody {
    file: tokio::fs::File,
    remaining: u64,
}
impl hyper::body::Body for FileBody {
    type Data = Bytes;
    type Error = Error;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>>>> {
        if self.remaining == 0 {
            return Poll::Ready(None);
        }
        let mut bytes = vec![0; self.remaining.min(256 * 1024) as usize];
        let mut buf = ReadBuf::new(&mut bytes);
        match Pin::new(&mut self.file).poll_read(cx, &mut buf) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(Err(error)) => Poll::Ready(Some(Err(error.into()))),
            Poll::Ready(Ok(())) => {
                let read = buf.filled().len();
                if read == 0 {
                    return Poll::Ready(Some(Err("Stored file is incomplete".into())));
                }
                self.remaining -= read as u64;
                bytes.truncate(read);
                Poll::Ready(Some(Ok(Frame::data(Bytes::from(bytes)))))
            }
        }
    }
    fn size_hint(&self) -> hyper::body::SizeHint {
        hyper::body::SizeHint::with_exact(self.remaining)
    }
}

async fn blob_read(hub: Arc<Hub>, request: Request<Incoming>, digest: String) -> Result<Reply> {
    let head = request.method() == "HEAD";
    let size = query(&request, "size")?
        .map(|v| v.parse::<u64>())
        .transpose()?;
    let range = header(&request, "range")?.map(str::to_owned);
    let spec = tokio::task::spawn_blocking(move || {
        blobs::read_spec(&hub.root, &digest, size, range.as_deref(), head)
    })
    .await??;
    let status = spec["status"].as_u64().ok_or("Invalid blob status")? as u16;
    let mut builder = Response::builder()
        .status(status)
        .header("X-Lanflow-Resumable", "1")
        .header("Accept-Ranges", "bytes")
        .header("Cache-Control", "no-store")
        .header("Content-Type", "application/octet-stream")
        .header("Content-Length", spec["length"].as_u64().unwrap_or(0));
    if let Some(offset) = spec["offset"].as_u64() {
        builder = builder.header("X-Lanflow-Offset", offset);
    }
    if let Some(range) = spec["contentRange"].as_str() {
        builder = builder.header("Content-Range", range);
    }
    let body = if !head && matches!(status, 200 | 206) {
        let mut file = tokio::fs::File::open(string(&spec, "path")?).await?;
        file.seek(std::io::SeekFrom::Start(
            spec["start"].as_u64().unwrap_or(0),
        ))
        .await?;
        FileBody {
            file,
            remaining: spec["length"].as_u64().unwrap_or(0),
        }
        .boxed_unsync()
    } else {
        bytes_body(Vec::new())
    };
    Ok(builder.body(body)?)
}

async fn blob_upload(
    hub: Arc<Hub>,
    mut request: Request<Incoming>,
    digest: String,
) -> Result<Reply> {
    let size = length(&request, MAX_FILE)?;
    let range = header(&request, "content-range")?.map(str::to_owned);
    let upload = tokio::task::spawn_blocking(move || {
        blobs::Upload::begin(&hub.root, &digest, size, range.as_deref())
    })
    .await?;
    let upload = match upload {
        Ok(upload) => upload,
        Err(error) => {
            // Closing while a chunk is still being sent can turn the HTTP error
            // into a TCP reset. Discard a bounded body before sending the reply.
            // An Expect client has not sent its body yet; reject it immediately.
            if size <= blobs::CHUNK_BYTES && !request.headers().contains_key("expect") {
                let _ = tokio::time::timeout(Duration::from_secs(5), async {
                    while let Some(frame) = request.body_mut().frame().await {
                        if frame.is_err() {
                            break;
                        }
                    }
                })
                .await;
            }
            return Err(error);
        }
    };
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(&upload.path)
        .await?;
    let mut count = 0u64;
    while let Some(frame) =
        tokio::time::timeout(Duration::from_secs(30), request.body_mut().frame()).await?
    {
        let frame = frame.map_err(|_| errors::api(400, "Incomplete upload"))?;
        if let Ok(data) = frame.into_data() {
            count += data.len() as u64;
            if count > size {
                return Err(errors::api(400, "Upload exceeds declared length"));
            }
            file.write_all(&data).await?;
        }
    }
    if count != size {
        return Err(errors::api(400, "Incomplete upload"));
    }
    file.sync_all().await?;
    drop(file);
    let result = tokio::task::spawn_blocking(move || upload.finish()).await??;
    Ok(reply(200, result))
}

async fn dispatch(
    hub: Arc<Hub>,
    request: Request<Incoming>,
    connection: Arc<Mutex<ConnectionAdmission>>,
) -> Result<Reply> {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    if method == "GET" && path == "/health" {
        let mut response = reply(200, json!({"ok":true}));
        // Public liveness probes do not need persistent unauthenticated slots.
        response.headers_mut().insert(
            "Connection",
            hyper::header::HeaderValue::from_static("close"),
        );
        return Ok(response);
    }
    let authorization = header(&request, "authorization")?.unwrap_or("");
    let expected = format!("Bearer {}", string(&hub.identity.config, "token")?);
    if !bool::from(authorization.as_bytes().ct_eq(expected.as_bytes())) {
        return Err(errors::api(401, "NAS 连接码已失效，请重新绑定"));
    }
    if !connection
        .lock()
        .map_err(|_| "Connection unavailable")?
        .authenticate(method == "GET" && path == "/v3/watch")
    {
        return Err(errors::api(503, "NAS 正忙，请稍后重试"));
    }
    if method == "GET" && path == "/v2/info" {
        return Ok(reply(
            200,
            json!({"service":"lanflow-inbox","version":1,"protocol":3,"id":hub.identity.config["id"],"name":hub.name}),
        ));
    }
    if method == "GET" && path == "/v3/watch" {
        let after = query(&request, "after")?
            .unwrap_or_else(|| "-1".into())
            .parse::<i64>()?;
        if after < -1 {
            return Err(errors::api(400, "Invalid cursor"));
        }
        // Subscribe before inspecting the cursor, so an intervening commit
        // cannot be missed. No database polling or locks while waiting.
        let mut changes = hub.changes.subscribe();
        let wait = query(&request, "wait")?;
        if *changes.borrow_and_update() == after {
            if wait.as_deref() == Some("change") {
                // The authenticated connection waits without periodic empty
                // replies. Hyper drops this future when its socket closes.
                let _ = changes.changed().await;
            } else {
                let hold = wait.and_then(|v| v.parse::<u64>().ok()).unwrap_or(25).clamp(5, 120);
                let _ = tokio::time::timeout(Duration::from_secs(hold), changes.changed()).await;
            }
        }
        let cursor = *changes.borrow_and_update();
        return Ok(reply(200, json!({"cursor":cursor,"changed":cursor!=after,"waitForChange":true})));
    }
    if method == "GET" && matches!(path.as_str(), "/v3/changes" | "/v2/items") {
        let after = query(&request, "after")?
            .unwrap_or_else(|| "0".into())
            .parse::<i64>()?;
        let capabilities = json!(query(&request, "capabilities")?);
        let value = tokio::task::spawn_blocking(move || -> Result<Value> {
            let db = hub.db.lock().map_err(|_| "Database unavailable")?;
            if path == "/v3/changes" {
                storage::requested_page(&db, after, &capabilities)
            } else {
                storage::items_page(&db, after)
            }
        })
        .await??;
        return Ok(reply(200, value));
    }
    if method == "POST" && matches!(path.as_str(), "/v3/changes" | "/v2/items") {
        let value = read_json(request).await?;
        tokio::task::spawn_blocking(move || -> Result<()> {
            let event = if path == "/v2/items" {
                item_event(&events::normalize_item(&value)?)
            } else {
                value
            };
            let mut attachment_changed = false;
            if let Some(item) = events::transfer_item(&event) {
                validate_item(item)?;
                attachment_changed = attachments::register_changed(&hub.root, &hub.db, item)?.1;
            }
            let mut db = hub.db.lock().map_err(|_| "Database unavailable")?;
            if apply(&hub.root, &mut db, &event, None)? || attachment_changed {
                hub.changes.send_replace(storage::change_cursor(&db)?);
            }
            Ok(())
        })
        .await??;
        return Ok(reply(200, json!({"ok":true})));
    }
    if let Some(digest) = path.strip_prefix("/v2/blobs/") {
        return match method.as_str() {
            "GET" | "HEAD" => blob_read(hub, request, digest.to_owned()).await,
            "PUT" => blob_upload(hub, request, digest.to_owned()).await,
            _ => Err(errors::api(405, "Method not allowed")),
        };
    }
    Err(errors::api(404, "Unknown request"))
}

pub(super) async fn handle(
    hub: Arc<Hub>,
    request: Request<Incoming>,
    connection: Arc<Mutex<ConnectionAdmission>>,
) -> std::result::Result<Reply, std::convert::Infallible> {
    let head = request.method() == "HEAD";
    let mut response = match dispatch(hub, request, connection).await {
        Ok(response) => response,
        Err(error) => {
            let status = errors::status(error.as_ref());
            let message = if status == 507 {
                "NAS 存储暂不可用，请检查磁盘空间".to_owned()
            } else {
                error.to_string()
            };
            let mut response = reply(status, json!({"error":message}));
            // Rejected requests may have unread bodies.
            response.headers_mut().insert(
                "Connection",
                hyper::header::HeaderValue::from_static("close"),
            );
            response
        }
    };
    if head {
        *response.body_mut() = bytes_body(Vec::new());
    }
    Ok(response)
}
