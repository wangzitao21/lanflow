use super::*;
use std::collections::HashSet;

pub(super) const CHUNK_BYTES: u64 = 4 * 1024 * 1024;
type WriterKey = (PathBuf, String);
static WRITERS: OnceLock<Mutex<HashSet<WriterKey>>> = OnceLock::new();
static UPLOADS: OnceLock<Mutex<HashMap<String, Upload>>> = OnceLock::new();

struct Writer(WriterKey);
impl Writer {
    fn claim(root: &Path, digest: &str) -> Result<Self> {
        let key = (root.canonicalize()?, digest.to_owned());
        let mut writers = WRITERS
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "Blob writers unavailable")?;
        if writers.contains(&key) || writers.iter().filter(|(path, _)| path == &key.0).count() >= 4
        {
            return Err(errors::api(503, "File transfer is busy"));
        }
        writers.insert(key.clone());
        Ok(Self(key))
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        if let Some(writers) = WRITERS.get()
            && let Ok(mut writers) = writers.lock()
        {
            writers.remove(&self.0);
        }
    }
}

pub(super) fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

// statvfs field widths differ between 32-bit Android and 64-bit Linux.
#[allow(clippy::unnecessary_cast)]
fn free_space(root: &Path) -> Result<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let name = CString::new(root.as_os_str().as_bytes())?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        // Both pointers remain valid for the system call; inspect stat only on success.
        if unsafe { libc::statvfs(name.as_ptr(), stat.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let stat = unsafe { stat.assume_init() };
        Ok((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let name: Vec<u16> = root.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut free = 0u64;
        if unsafe {
            windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                name.as_ptr(),
                &mut free,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(free)
    }
}

fn partial(root: &Path, digest: &str, size: u64) -> PathBuf {
    layout::incoming(root).join(format!("{digest}.{size}.upload.part"))
}

pub(super) fn publish(root: &Path, temp: &Path, digest: &str) -> Result<()> {
    let lock = attachments::organizer(root, digest)?;
    let _publishing = lock
        .lock()
        .map_err(|_| "Attachment organizer unavailable")?;
    let target = attachments::path(root, digest);
    let size = fs::metadata(temp)?.len();
    if !verified_files::check(temp, digest, size)? {
        return Err(errors::api(400, "Checksum mismatch"));
    }
    if target.exists() {
        if fs::symlink_metadata(&target)?.file_type().is_symlink() {
            return Err("附件路径包含链接".into());
        }
        if verified_files::check(&target, digest, size)? {
            fs::remove_file(temp)?;
            return Ok(());
        }
        preserve_modified(root, &target)?;
    }
    fs::rename(temp, &target)?;
    sync_directory(target.parent().ok_or("Invalid attachment path")?)?;
    sync_directory(&layout::incoming(root))?;
    Ok(())
}

pub(super) fn preserve_modified(root: &Path, path: &Path) -> Result<()> {
    fn linked(metadata: &fs::Metadata) -> bool {
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            metadata.file_attributes() & 0x400 != 0
        }
        #[cfg(not(windows))]
        {
            metadata.file_type().is_symlink()
        }
    }
    let boundary = root.canonicalize()?;
    let system = layout::system(root);
    if linked(&fs::symlink_metadata(&system)?) || !system.canonicalize()?.starts_with(&boundary) {
        return Err("恢复目录位置异常，原文件已保留".into());
    }
    let recovery = layout::system(root).join("recovered");
    if let Ok(metadata) = fs::symlink_metadata(&recovery)
        && (!metadata.is_dir() || linked(&metadata))
    {
        return Err("恢复目录位置异常，原文件已保留".into());
    }
    fs::create_dir_all(&recovery)?;
    if linked(&fs::symlink_metadata(&recovery)?) || !recovery.canonicalize()?.starts_with(&boundary)
    {
        return Err("恢复目录位置异常，原文件已保留".into());
    }
    let mut name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    // Leave room for the unique prefix on filesystems with a 255-byte filename
    // limit. Keep the suffix (including the extension) useful for recovery.
    while name.len() > 200 {
        name.remove(0);
    }
    fs::rename(
        path,
        recovery.join(format!("{}-{name}", uuid::Uuid::new_v4())),
    )?;
    sync_directory(&recovery)?;
    Ok(())
}

pub(super) fn commit_staged(
    root: &Path,
    temp: &Path,
    size: u64,
    expected: Option<&str>,
) -> Result<String> {
    if size > MAX_FILE
        || temp.canonicalize()?.parent() != Some(layout::incoming(root).canonicalize()?.as_path())
    {
        return Err(errors::api(400, "Invalid staged file"));
    }
    let file = fs::OpenOptions::new().read(true).write(true).open(temp)?;
    if file.metadata()?.len() != size {
        return Err(errors::api(400, "Incomplete file"));
    }
    file.sync_all()?;
    drop(file);
    let actual = hash_file(temp)?;
    if expected.is_some_and(|expected| expected != actual) {
        return Err(errors::api(400, "Checksum mismatch"));
    }
    publish(root, temp, &actual)?;
    Ok(actual)
}

pub(super) struct Upload {
    root: PathBuf,
    pub path: PathBuf,
    digest: String,
    length: u64,
    offset: u64,
    size: u64,
    resumed: bool,
    _writer: Writer,
}

impl Upload {
    pub fn begin(root: &Path, digest: &str, length: u64, range: Option<&str>) -> Result<Self> {
        if !valid_digest(digest) {
            return Err(errors::api(400, "Invalid file digest"));
        }
        if length > MAX_FILE {
            return Err(errors::api(413, "Content too large"));
        }
        fs::create_dir_all(layout::incoming(root))?;
        fs::create_dir_all(layout::pending(root))?;
        let writer = Writer::claim(root, digest)?;
        let (offset, size) = if let Some(range) = range {
            let parsed = range
                .strip_prefix("bytes ")
                .and_then(|r| r.split_once('/'))
                .and_then(|(span, size)| {
                    span.split_once('-').map(|(start, end)| (start, end, size))
                })
                .and_then(|(start, end, size)| {
                    Some((
                        start.parse::<u64>().ok()?,
                        end.parse::<u64>().ok()?,
                        size.parse::<u64>().ok()?,
                    ))
                });
            let (start, end, size) =
                parsed.ok_or_else(|| errors::api(400, "Invalid chunk range"))?;
            if start > end
                || end >= size
                || size > MAX_FILE
                || length != end - start + 1
                || length > CHUNK_BYTES
            {
                return Err(errors::api(400, "Invalid chunk range"));
            }
            let path = partial(root, digest, size);
            let offset = fs::metadata(path).map(|v| v.len()).unwrap_or(0);
            if offset != start {
                return Err(errors::api(409, "Upload offset changed; retry"));
            }
            (start, size)
        } else {
            (0, length)
        };
        // Staging a chunk also needs temporary room before appending it.
        if free_space(root)? < size - offset + length.min(CHUNK_BYTES) + 64 * 1024 * 1024 {
            return Err(errors::api(507, "Not enough free disk space"));
        }
        let path = layout::incoming(root).join(format!("{}.stage", uuid::Uuid::new_v4()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        Ok(Self {
            root: root.to_owned(),
            path,
            digest: digest.to_owned(),
            length,
            offset,
            size,
            resumed: range.is_some(),
            _writer: writer,
        })
    }

    pub fn finish(self) -> Result<Value> {
        if fs::metadata(&self.path)?.len() != self.length {
            return Err(errors::api(400, "Incomplete upload"));
        }
        if !self.resumed {
            commit_staged(&self.root, &self.path, self.size, Some(&self.digest))?;
            return Ok(json!({"sha256":self.digest}));
        }
        let part = partial(&self.root, &self.digest, self.size);
        let mut output = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&part)?;
        if output.metadata()?.len() != self.offset {
            return Err(errors::api(409, "Upload offset changed; retry"));
        }
        let result = (|| -> Result<()> {
            let copied = std::io::copy(&mut File::open(&self.path)?, &mut output)?;
            if copied != self.length {
                return Err(errors::api(400, "Incomplete chunk"));
            }
            output.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            output.set_len(self.offset)?;
            output.sync_all()?;
        }
        drop(output);
        result?;
        let next = self.offset + self.length;
        if next == self.size {
            if hash_file(&part)? != self.digest {
                fs::remove_file(&part)?;
                return Err(errors::api(400, "Checksum mismatch"));
            }
            publish(&self.root, &part, &self.digest)?;
        }
        Ok(json!({"offset":next,"sha256":if next==self.size {Some(&self.digest)} else {None}}))
    }
}

impl Drop for Upload {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(super) fn read_spec(
    root: &Path,
    digest: &str,
    size: Option<u64>,
    range: Option<&str>,
    head: bool,
) -> Result<Value> {
    if !valid_digest(digest) || size.is_some_and(|v| v > MAX_FILE) {
        return Err(errors::api(400, "Invalid file request"));
    }
    if head
        && WRITERS
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "Blob writers unavailable")?
            .contains(&(root.canonicalize()?, digest.to_owned()))
    {
        return Err(errors::api(503, "File transfer is busy"));
    }
    let target = attachments::path(root, digest);
    if !target.is_file() {
        let mut offset = 0;
        if let Some(size) = size {
            let part = partial(root, digest, size);
            if part.is_file() {
                offset = fs::metadata(&part)?.len();
                if offset == size {
                    let _writer = Writer::claim(root, digest)?;
                    if hash_file(&part)? == digest {
                        publish(root, &part, digest)?;
                    } else {
                        fs::remove_file(&part)?;
                        offset = 0;
                    }
                }
            }
        }
        if !target.is_file() {
            return Ok(json!({"status":404,"offset":offset,"length":0}));
        }
    }
    let length = fs::metadata(&target)?.len();
    if !verified_files::check(&target, digest, length)? {
        // A valid copy from the sender can repair this path through publish(),
        // which preserves the externally modified bytes before replacing them.
        return Ok(json!({"status":404,"offset":0,"length":0}));
    }
    let mut start = 0;
    let mut end = length;
    let mut status = 200;
    if let Some(range) = range.filter(|_| !head) {
        let parsed = range
            .strip_prefix("bytes=")
            .and_then(|v| v.split_once('-'))
            .and_then(|(a, b)| {
                Some((
                    a.parse::<u64>().ok()?,
                    if b.is_empty() {
                        length.checked_sub(1)?
                    } else {
                        b.parse().ok()?
                    },
                ))
            });
        let Some((first, last)) = parsed.filter(|(first, last)| first <= last && *last < length)
        else {
            return Ok(json!({"status":416,"length":0,"contentRange":format!("bytes */{length}")}));
        };
        start = first;
        end = last + 1;
        status = 206;
    }
    let mut value =
        json!({"status":status,"path":target,"start":start,"end":end,"length":end-start});
    if status == 206 {
        value["contentRange"] = json!(format!("bytes {start}-{}/{length}", end - 1));
    }
    Ok(value)
}

pub(super) fn dispatch(root: &Path, request: &Value) -> Result<Value> {
    match string(request, "op")? {
        "blob_read" => read_spec(
            root,
            string(request, "digest")?,
            request["size"].as_u64(),
            request["range"].as_str(),
            request["head"].as_bool().unwrap_or(false),
        ),
        "blob_begin" => {
            let upload = Upload::begin(
                root,
                string(request, "digest")?,
                request["length"].as_u64().ok_or("Invalid length")?,
                request["range"].as_str(),
            )?;
            let id = uuid::Uuid::new_v4().simple().to_string();
            let value = json!({"id":id,"path":upload.path});
            UPLOADS
                .get_or_init(Default::default)
                .lock()
                .map_err(|_| "Uploads unavailable")?
                .insert(id, upload);
            Ok(value)
        }
        "blob_finish" | "blob_abort" => {
            let upload = UPLOADS
                .get_or_init(Default::default)
                .lock()
                .map_err(|_| "Uploads unavailable")?
                .remove(string(request, "id")?);
            if request["op"] == "blob_abort" {
                return Ok(json!(true));
            }
            upload.ok_or("Upload no longer exists")?.finish()
        }
        "blob_commit" => Ok(json!(commit_staged(
            root,
            Path::new(string(request, "path")?),
            request["size"].as_u64().ok_or("Invalid size")?,
            request["digest"].as_str()
        )?)),
        _ => Err("Unknown blob operation".into()),
    }
}

pub(super) fn abort_root(root: &Path) {
    if let Some(uploads) = UPLOADS.get()
        && let Ok(mut uploads) = uploads.lock()
    {
        let root = root.canonicalize().unwrap_or_else(|_| root.to_owned());
        uploads.retain(|_, upload| upload._writer.0.0 != root);
    }
}

pub(super) fn has_writers(root: &Path) -> Result<bool> {
    let root = root.canonicalize()?;
    Ok(WRITERS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "Blob writers unavailable")?
        .iter()
        .any(|(path, _)| path == &root))
}

pub(super) fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(hex::encode(hash.finalize()))
}

pub(super) fn import_file(root: &Path, source: &Path) -> Result<Value> {
    fs::create_dir_all(layout::incoming(root))?;
    fs::create_dir_all(layout::pending(root))?;
    let temp = layout::incoming(root).join(format!("{}.part", uuid::Uuid::new_v4()));
    let result = (|| -> Result<Value> {
        let mut input = File::open(source)?;
        let mut output = File::create(&temp)?;
        let mut hash = Sha256::new();
        let mut bytes = 0_u64;
        let mut buffer = vec![0; 256 * 1024];
        loop {
            let n = input.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            bytes += n as u64;
            if bytes > MAX_FILE {
                return Err("File too large".into());
            }
            output.write_all(&buffer[..n])?;
            hash.update(&buffer[..n]);
        }
        output.sync_all()?;
        drop(output);
        let digest = hex::encode(hash.finalize());
        publish(root, &temp, &digest)?;
        Ok(json!({"sha256":digest,"size":bytes}))
    })();
    let _ = fs::remove_file(temp);
    result
}
