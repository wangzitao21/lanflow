use super::*;
use std::future::{Future, poll_fn};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll, Waker};
use tokio::io::AsyncRead;

pub(super) const NETWORK_IDLE_TIMEOUT: Duration = Duration::from_secs(45);

// One runtime serves every endpoint. Its timers only wake for an actual timeout;
// no periodic worker is needed while transfers make progress or the app is idle.
pub(super) fn runtime() -> Result<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<std::result::Result<tokio::runtime::Runtime, std::io::Error>> =
        OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
        })
        .as_ref()
        .map_err(|error| error.to_string().into())
}

struct Control {
    cancelled: AtomicBool,
    claimed: AtomicBool,
    in_files: AtomicBool,
    yield_files: AtomicBool,
    mutations: Mutex<()>,
    waiting: Mutex<Option<Waker>>,
}
impl Control {
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        if let Ok(mut waiting) = self.waiting.lock()
            && let Some(waker) = waiting.take()
        {
            waker.wake();
        }
    }
}
type Runs = HashMap<(PathBuf, String), (String, Arc<Control>)>;
static RUNS: OnceLock<Mutex<Runs>> = OnceLock::new();

pub(super) fn begin(root: &Path, key: &str) -> Result<String> {
    let mut runs = RUNS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Sync unavailable")?;
    let id = uuid::Uuid::new_v4().simple().to_string();
    if let Some((_, previous)) = runs.insert(
        (root.to_owned(), key.to_owned()),
        (
            id.clone(),
            Arc::new(Control {
                cancelled: AtomicBool::new(false),
                claimed: AtomicBool::new(false),
                in_files: AtomicBool::new(false),
                yield_files: AtomicBool::new(false),
                mutations: Mutex::new(()),
                waiting: Mutex::new(None),
            }),
        ),
    ) {
        let _guard = previous.mutations.lock().map_err(|_| "Sync unavailable")?;
        previous.cancel();
    }
    Ok(id)
}

pub(super) fn cancel(root: &Path, key: Option<&str>) {
    if let Ok(mut runs) = RUNS.get_or_init(Default::default).lock() {
        runs.retain(|(path, endpoint), (_, control)| {
            let matches = path == root && key.is_none_or(|key| endpoint == key);
            if matches {
                let _guard = control
                    .mutations
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                control.cancel();
            }
            !matches
        });
    }
}

pub(super) fn interrupt_files(root: &Path, key: &str, run_id: &str) -> bool {
    let Ok(runs) = RUNS.get_or_init(Default::default).lock() else {
        return false;
    };
    let Some((current, control)) = runs.get(&(root.to_owned(), key.to_owned())) else {
        return false;
    };
    if current != run_id {
        return false;
    }
    control.yield_files.store(true, Ordering::Release);
    if control.in_files.load(Ordering::Acquire) {
        let _guard = control
            .mutations
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        control.cancel();
        return true;
    }
    false
}

pub(super) fn file_activity(root: &Path) -> usize {
    RUNS.get_or_init(Default::default)
        .lock()
        .map(|runs| {
            runs.iter()
                .filter(|((path, _), (_, control))| {
                    path == root
                        && control.in_files.load(Ordering::Acquire)
                        && !control.cancelled.load(Ordering::Acquire)
                })
                .count()
        })
        .unwrap_or(0)
}

pub(super) struct FilePhase<'a>(&'a Control);
impl Drop for FilePhase<'_> {
    fn drop(&mut self) {
        self.0.in_files.store(false, Ordering::Release);
    }
}

pub(super) struct Run {
    control: Arc<Control>,
    key: (PathBuf, String),
    id: String,
    idle_timeout: Duration,
}
impl Run {
    pub fn file_phase(&self) -> Result<FilePhase<'_>> {
        self.control.in_files.store(true, Ordering::Release);
        if self.control.yield_files.load(Ordering::Acquire) {
            self.control.cancel();
        }
        self.check()?;
        Ok(FilePhase(&self.control))
    }
    pub fn acquire(root: &Path, key: &str, id: &str) -> Result<Self> {
        let runs = RUNS
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "Sync unavailable")?;
        let key = (root.to_owned(), key.to_owned());
        let (_, control) = runs
            .get(&key)
            .filter(|(current, control)| {
                current == id && !control.cancelled.load(Ordering::Acquire)
            })
            .ok_or_else(|| errors::api(499, "Sync cancelled"))?;
        if control.claimed.swap(true, Ordering::AcqRel) {
            return Err(errors::api(409, "Sync already running"));
        }
        Ok(Self {
            control: control.clone(),
            key,
            id: id.to_owned(),
            idle_timeout: NETWORK_IDLE_TIMEOUT,
        })
    }

    pub fn check(&self) -> Result<()> {
        if self.control.cancelled.load(Ordering::Acquire) {
            Err(errors::api(499, "Sync cancelled"))
        } else {
            Ok(())
        }
    }

    #[cfg(test)]
    pub fn set_idle_timeout(&mut self, idle: Duration) {
        self.idle_timeout = idle;
    }

    // Cancellation waits only for short state commits, never network or file IO.
    // Once cancel returns, a removed endpoint cannot commit later incoming state.
    pub fn mutation(&self) -> Result<std::sync::MutexGuard<'_, ()>> {
        let guard = self
            .control
            .mutations
            .lock()
            .map_err(|_| "Sync unavailable")?;
        self.check()?;
        Ok(guard)
    }

    // Bound only time spent waiting for network progress. Local file reads pause
    // the upload clock; hashing and download writes happen outside this future.
    // Dropping a stalled/cancelled future closes its unfinished HTTP stream.
    pub fn wait_network<T, F: Future<Output = reqwest::Result<T>>>(
        &self,
        future: impl FnOnce() -> F,
        progress: Option<&NetworkProgress>,
        idle: Duration,
    ) -> Result<T> {
        self.check()?;
        runtime()?.block_on(async {
            let mut future = Box::pin(future());
            let mut timer = Box::pin(tokio::time::sleep(idle));
            poll_fn(|cx| {
                *self.control.waiting.lock().unwrap() = Some(cx.waker().clone());
                self.check()?;
                if let Some(progress) = progress {
                    progress.state.lock().unwrap().waiting = Some(cx.waker().clone());
                }
                if let Poll::Ready(result) = future.as_mut().poll(cx) {
                    self.check()?;
                    return Poll::Ready(result.map_err(Into::into));
                }
                if let Some(progress) = progress {
                    let state = progress.state.lock().unwrap();
                    if state.reading_file {
                        return Poll::Pending;
                    }
                    let allowance = if state.upload_finished {
                        progress.response_timeout
                    } else {
                        idle
                    };
                    timer.as_mut().reset(state.last_activity + allowance);
                }
                if timer.as_mut().poll(cx).is_ready() {
                    return Poll::Ready(Err(errors::api(
                        408,
                        "File transfer made no network progress",
                    )));
                }
                Poll::Pending
            })
            .await
        })
    }
}
impl Drop for Run {
    fn drop(&mut self) {
        if let Some(runs) = RUNS.get()
            && let Ok(mut runs) = runs.lock()
        {
            if runs.get(&self.key).is_some_and(|(id, _)| id == &self.id) {
                runs.remove(&self.key);
            }
        }
    }
}

pub(super) trait CheckedRequest {
    fn send_checked(self, run: &Run) -> Result<reqwest::Response>;
    fn send_file_checked(
        self,
        file: File,
        size: u64,
        verification_size: u64,
        run: &Run,
    ) -> Result<reqwest::Response>;
}
impl CheckedRequest for reqwest::RequestBuilder {
    fn send_checked(self, run: &Run) -> Result<reqwest::Response> {
        run.wait_network(|| self.send(), None, run.idle_timeout)
    }

    fn send_file_checked(
        self,
        file: File,
        size: u64,
        verification_size: u64,
        run: &Run,
    ) -> Result<reqwest::Response> {
        // Once the body has been handed to the transport, the peer may still be
        // draining socket buffers, flushing storage, or hashing the entire file.
        // This is a deadline, never an added delay before processing its reply.
        let response_timeout = Duration::from_secs(120 + verification_size / (8 * 1024 * 1024));
        let (body, progress) = file_body(file, size, response_timeout);
        run.wait_network(
            || {
                self.header(reqwest::header::CONTENT_LENGTH, size)
                    .body(body)
                    .send()
            },
            Some(&progress),
            run.idle_timeout,
        )
    }
}

pub(super) fn response_chunk(
    response: &mut reqwest::Response,
    run: &Run,
) -> Result<Option<bytes::Bytes>> {
    run.wait_network(|| response.chunk(), None, run.idle_timeout)
}

struct ProgressState {
    last_activity: tokio::time::Instant,
    reading_file: bool,
    upload_finished: bool,
    waiting: Option<Waker>,
}
pub(super) struct NetworkProgress {
    state: Mutex<ProgressState>,
    response_timeout: Duration,
}
impl NetworkProgress {
    fn update(&self, reading_file: bool, upload_finished: bool) {
        let mut state = self.state.lock().unwrap();
        state.reading_file = reading_file;
        state.upload_finished = upload_finished;
        state.last_activity = tokio::time::Instant::now();
        if let Some(waker) = state.waiting.take() {
            waker.wake();
        }
    }
}

pub(super) fn file_body(
    file: File,
    size: u64,
    response_timeout: Duration,
) -> (reqwest::Body, Arc<NetworkProgress>) {
    let progress = Arc::new(NetworkProgress {
        state: Mutex::new(ProgressState {
            last_activity: tokio::time::Instant::now(),
            reading_file: false,
            upload_finished: size == 0,
            waiting: None,
        }),
        response_timeout,
    });
    let body = FileBody {
        file: tokio::fs::File::from_std(file),
        remaining: size,
        buffer: vec![0; 64 * 1024],
        progress: progress.clone(),
    };
    (reqwest::Body::wrap(body), progress)
}

struct FileBody {
    file: tokio::fs::File,
    remaining: u64,
    buffer: Vec<u8>,
    progress: Arc<NetworkProgress>,
}
impl http_body::Body for FileBody {
    type Data = bytes::Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<std::io::Result<http_body::Frame<Self::Data>>>> {
        let this = self.get_mut();
        if this.remaining == 0 {
            return Poll::Ready(None);
        }
        let count = this.remaining.min(this.buffer.len() as u64) as usize;
        let mut buffer = tokio::io::ReadBuf::new(&mut this.buffer[..count]);
        match Pin::new(&mut this.file).poll_read(cx, &mut buffer) {
            Poll::Pending => {
                this.progress.update(true, false);
                Poll::Pending
            }
            Poll::Ready(result) => {
                this.progress
                    .update(false, buffer.filled().len() as u64 == this.remaining);
                Poll::Ready(Some(result.and_then(|()| {
                    let bytes = buffer.filled();
                    if bytes.is_empty() {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::UnexpectedEof,
                            "Local file is incomplete",
                        ));
                    }
                    this.remaining -= bytes.len() as u64;
                    Ok(http_body::Frame::data(bytes::Bytes::copy_from_slice(bytes)))
                })))
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        self.remaining == 0
    }

    fn size_hint(&self) -> http_body::SizeHint {
        http_body::SizeHint::with_exact(self.remaining)
    }
}
