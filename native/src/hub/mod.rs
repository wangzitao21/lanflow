use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
use std::{
    future::Future,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

mod http;
mod identity;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

// Authentication has its own small admission pool. A client that has not sent
// a complete request must never consume the transfer or notification capacity.
struct Admission {
    pending: Mutex<HashMap<IpAddr, usize>>,
    requests: Arc<tokio::sync::Semaphore>,
    watches: Arc<tokio::sync::Semaphore>,
}

impl Admission {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(HashMap::new()),
            requests: Arc::new(tokio::sync::Semaphore::new(64)),
            watches: Arc::new(tokio::sync::Semaphore::new(64)),
        })
    }

    fn accept(self: &Arc<Self>, source: IpAddr) -> Option<ConnectionAdmission> {
        let mut pending = self.pending.lock().ok()?;
        if pending.values().sum::<usize>() >= 64 || pending.get(&source).copied().unwrap_or(0) >= 8
        {
            return None;
        }
        *pending.entry(source).or_default() += 1;
        Some(ConnectionAdmission {
            admission: self.clone(),
            pending_source: Some(source),
            established: None,
        })
    }

    fn release_pending(&self, source: IpAddr) {
        if let Ok(mut pending) = self.pending.lock() {
            if let Some(count) = pending.get_mut(&source) {
                *count -= 1;
                if *count == 0 {
                    pending.remove(&source);
                }
            }
        }
    }
}

struct ConnectionAdmission {
    admission: Arc<Admission>,
    pending_source: Option<IpAddr>,
    established: Option<(bool, tokio::sync::OwnedSemaphorePermit)>,
}

impl ConnectionAdmission {
    fn authenticate(&mut self, watching: bool) -> bool {
        if self
            .established
            .as_ref()
            .is_some_and(|(old, _)| *old == watching)
        {
            return true;
        }
        let pool = if watching {
            &self.admission.watches
        } else {
            &self.admission.requests
        };
        let Ok(permit) = pool.clone().try_acquire_owned() else {
            return false;
        };
        self.established = Some((watching, permit));
        if let Some(source) = self.pending_source.take() {
            self.admission.release_pending(source);
        }
        true
    }
}

impl Drop for ConnectionAdmission {
    fn drop(&mut self) {
        if let Some(source) = self.pending_source.take() {
            self.admission.release_pending(source);
        }
    }
}

pub struct Config {
    pub data: PathBuf,
    pub host: String,
    pub port: u16,
    pub name: String,
    pub certificate: Option<PathBuf>,
    pub private_key: Option<PathBuf>,
}

struct Hub {
    root: PathBuf,
    db: Mutex<Connection>,
    identity: identity::Identity,
    name: String,
    changes: tokio::sync::watch::Sender<i64>,
    _lock: File,
}

impl Hub {
    fn open(config: &Config) -> Result<Self> {
        fs::create_dir_all(&config.data)?;
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(config.data.join(".hub.lock"))?;
        lock.try_lock()
            .map_err(|_| "This NAS data directory is already in use")?;
        layout::prepare(&config.data)?;
        let identity = identity::Identity::load(config)?;
        let db = storage::open_hub(&config.data)?;
        let (changes, _) = tokio::sync::watch::channel(storage::change_cursor(&db)?);
        Ok(Self {
            root: config.data.clone(),
            db: Mutex::new(db),
            identity,
            name: config.name.chars().take(60).collect(),
            changes,
            _lock: lock,
        })
    }
}

// Socket inactivity, rather than total transfer time, limits stalled clients.
// Large whole-file transfers remain compatible while active.
struct IdleIo<T> {
    inner: T,
    timer: Pin<Box<tokio::time::Sleep>>,
    progress: Arc<AtomicU64>,
    observed: u64,
    idle: Duration,
}
impl<T> IdleIo<T> {
    fn new(inner: T, progress: Arc<AtomicU64>) -> Self {
        Self {
            inner,
            timer: Box::pin(tokio::time::sleep(Duration::from_secs(30))),
            progress,
            observed: 0,
            idle: Duration::from_secs(30),
        }
    }
    fn expired(&mut self, cx: &mut Context<'_>) -> bool {
        let epoch = self.progress.load(Ordering::Acquire);
        if epoch != self.observed || epoch % 2 == 1 {
            self.observed = epoch;
            self.active();
            return false;
        }
        self.timer.as_mut().poll(cx).is_ready()
    }
    fn active(&mut self) {
        self.timer
            .as_mut()
            .reset(tokio::time::Instant::now() + self.idle);
    }
}

// HTTP/1 dispatches requests serially. An odd epoch means the service is
// processing a request (possibly hashing a large file). Socket idle deadlines
// restart when it finishes; body reads still have their own inactivity timeout.
struct Processing(Arc<AtomicU64>);
impl Processing {
    fn begin(progress: Arc<AtomicU64>) -> Self {
        progress.fetch_add(1, Ordering::Release);
        Self(progress)
    }
}
impl Drop for Processing {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::Release);
    }
}
impl<T: AsyncRead + Unpin> AsyncRead for IdleIo<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if self.expired(cx) {
            return Poll::Ready(Err(std::io::ErrorKind::TimedOut.into()));
        }
        let before = buf.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buf);
        if matches!(result, Poll::Ready(Ok(()))) && buf.filled().len() > before {
            self.active();
        }
        result
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for IdleIo<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        if self.expired(cx) {
            return Poll::Ready(Err(std::io::ErrorKind::TimedOut.into()));
        }
        let result = Pin::new(&mut self.inner).poll_write(cx, buf);
        if matches!(result, Poll::Ready(Ok(n)) if n > 0) {
            self.active();
        }
        result
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        if self.expired(cx) {
            return Poll::Ready(Err(std::io::ErrorKind::TimedOut.into()));
        }
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

pub fn run(config: Config) -> Result<()> {
    let hub = Arc::new(Hub::open(&config)?);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let listener = tokio::net::TcpListener::bind((config.host.as_str(), config.port)).await?;
        let address: SocketAddr = listener.local_addr()?;
        println!("LanFlow NAS ready on HTTPS port {}", address.port());
        println!("Connection code (paste into LanFlow > My devices > Add NAS):");
        println!("{}", hub.identity.code);
        std::io::stdout().flush()?;
        let admission = Admission::new();
        loop {
            let (socket, source) = listener.accept().await?;
            let Some(connection) = admission.accept(source.ip()) else {
                continue;
            };
            let hub = hub.clone();
            tokio::spawn(async move {
                let connection = Arc::new(Mutex::new(connection));
                let progress = Arc::new(AtomicU64::new(0));
                let acceptor = tokio_rustls::TlsAcceptor::from(hub.identity.tls.clone());
                let Ok(Ok(socket)) = tokio::time::timeout(
                    HANDSHAKE_TIMEOUT,
                    acceptor.accept(IdleIo::new(socket, progress.clone())),
                )
                .await
                else {
                    return;
                };
                let service = hyper::service::service_fn(move |request| {
                    let hub = hub.clone();
                    let progress = progress.clone();
                    let connection = connection.clone();
                    async move {
                        let _processing = Processing::begin(progress);
                        http::handle(hub, request, connection).await
                    }
                });
                // Never log requests, credentials or message contents on disconnect.
                let _ = hyper::server::conn::http1::Builder::new()
                    .max_buf_size(64 * 1024)
                    .timer(hyper_util::rt::TokioTimer::new())
                    .header_read_timeout(HEADER_TIMEOUT)
                    .serve_connection(hyper_util::rt::TokioIo::new(socket), service)
                    .await;
            });
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn unauthenticated_sources_and_watchers_have_separate_capacity() {
        let admission = Admission::new();
        let source = IpAddr::from([127, 0, 0, 1]);
        let other = IpAddr::from([127, 0, 0, 2]);
        let mut pending = (0..8)
            .map(|_| admission.accept(source).unwrap())
            .collect::<Vec<_>>();
        assert!(admission.accept(source).is_none());
        assert!(admission.accept(other).is_some());
        assert!(pending[0].authenticate(false));
        assert!(admission.accept(source).is_some());
        drop(pending);

        let mut watches = Vec::new();
        for _ in 0..64 {
            let mut connection = admission.accept(source).unwrap();
            assert!(connection.authenticate(true));
            watches.push(connection);
        }
        let mut overflow = admission.accept(source).unwrap();
        assert!(!overflow.authenticate(true));
        // A full notification pool still leaves transfer connections available.
        assert!(overflow.authenticate(false));
        drop(watches);
        assert!(overflow.authenticate(true));
        drop(overflow);
        assert!(admission.pending.lock().unwrap().is_empty());
        assert_eq!(admission.requests.available_permits(), 64);
        assert_eq!(admission.watches.available_permits(), 64);
    }

    #[test]
    fn long_server_processing_is_not_a_stalled_client() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let (socket, _reader) = tokio::io::duplex(64);
                let progress = Arc::new(AtomicU64::new(0));
                let mut socket = IdleIo::new(socket, progress.clone());
                socket.idle = Duration::from_millis(5);
                socket.active();
                let processing = Processing::begin(progress);
                tokio::time::sleep(Duration::from_millis(20)).await;
                socket.write_all(b"working").await.unwrap();
                tokio::time::sleep(Duration::from_millis(20)).await;
                drop(processing);
                socket.write_all(b"response").await.unwrap();
                tokio::time::sleep(Duration::from_millis(20)).await;
                assert_eq!(
                    socket.write_all(b"idle").await.unwrap_err().kind(),
                    std::io::ErrorKind::TimedOut
                );
            });
    }
}
