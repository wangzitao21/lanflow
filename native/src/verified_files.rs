use super::*;

// Cache only fingerprints with a filesystem identity and change timestamp.
// Restoring a file's mtime or replacing it with equally-sized bytes cannot make
// that file inherit a previous successful verification.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct Stamp(Vec<u64>);
static VERIFIED: OnceLock<Mutex<HashMap<Stamp, String>>> = OnceLock::new();

fn settled(stamp: &Stamp) -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|time| time.as_nanos())
        .unwrap_or(0);
    #[cfg(unix)]
    let changed = (stamp.0[5] as u128)
        .saturating_mul(1_000_000_000)
        .saturating_add(stamp.0[6] as u128);
    #[cfg(windows)]
    let changed = (stamp.0[6] as u128)
        .saturating_sub(116_444_736_000_000_000)
        .saturating_mul(100);
    // Some filesystems coalesce very rapid writes into one timestamp. Never
    // cache recently written files, including after a caller restores mtime.
    now.saturating_sub(changed) >= 5_000_000_000 && changed <= now
}

fn stamp(file: &File) -> Option<Stamp> {
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(Stamp(vec![
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mtime() as u64,
            metadata.mtime_nsec() as u64,
            metadata.ctime() as u64,
            metadata.ctime_nsec() as u64,
        ]))
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_BASIC_INFO, FILE_ID_INFO, FileBasicInfo, FileIdInfo, GetFileInformationByHandleEx,
        };
        let mut basic = std::mem::MaybeUninit::<FILE_BASIC_INFO>::uninit();
        let mut identity = std::mem::MaybeUninit::<FILE_ID_INFO>::uninit();
        // The buffers have exactly the sizes required by the selected classes.
        let valid = unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle(),
                FileBasicInfo,
                basic.as_mut_ptr().cast(),
                std::mem::size_of::<FILE_BASIC_INFO>() as u32,
            ) != 0
                && GetFileInformationByHandleEx(
                    file.as_raw_handle(),
                    FileIdInfo,
                    identity.as_mut_ptr().cast(),
                    std::mem::size_of::<FILE_ID_INFO>() as u32,
                ) != 0
        };
        if !valid {
            return None;
        }
        let (basic, identity) = unsafe { (basic.assume_init(), identity.assume_init()) };
        let id = identity.FileId.Identifier;
        Some(Stamp(vec![
            identity.VolumeSerialNumber,
            u64::from_le_bytes(id[..8].try_into().ok()?),
            u64::from_le_bytes(id[8..].try_into().ok()?),
            metadata.len(),
            basic.CreationTime as u64,
            basic.LastWriteTime as u64,
            basic.ChangeTime as u64,
        ]))
    }
}

pub(super) fn check(path: &Path, expected: &str, size: u64) -> Result<bool> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Do not reuse cached metadata while another handle can still modify
        // the file with a deferred Windows last-write/change timestamp.
        options.share_mode(1 | 4); // FILE_SHARE_READ | FILE_SHARE_DELETE
    }
    let mut file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if file.metadata()?.len() != size {
        return Ok(false);
    }
    let before = stamp(&file);
    if let Some(before) = &before
        && VERIFIED
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "File verification unavailable")?
            .get(before)
            .is_some_and(|digest| digest == expected)
    {
        return Ok(true);
    }
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let actual = hex::encode(hasher.finalize());
    let after = stamp(&file);
    if before != after || file.metadata()?.len() != size {
        return Ok(false);
    }
    // Filesystems without reliable change identities are checked every time.
    if let Some(after) = after.filter(settled) {
        let mut cache = VERIFIED
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| "File verification unavailable")?;
        if cache.len() >= 2048 {
            cache.clear();
        }
        cache.insert(after, actual.clone());
    }
    Ok(actual == expected)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn same_size_edit_and_replacement_cannot_reuse_verified_content() {
        let root = crate::tests::root();
        fs::create_dir_all(&root).unwrap();
        let path = root.join("file.bin");
        fs::write(&path, b"ABCD").unwrap();
        // Exercise a real cache hit rather than only the recent-write fallback.
        std::thread::sleep(Duration::from_millis(5100));
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        let before = stamp(&File::open(&path).unwrap());
        let sha = digest(b"ABCD");
        assert!(check(&path, &sha, 4).unwrap());
        if let Some(before) = &before {
            assert_eq!(
                VERIFIED.get().unwrap().lock().unwrap().get(before),
                Some(&sha)
            );
        }
        assert!(check(&path, &sha, 4).unwrap());
        fs::write(&path, b"WXYZ").unwrap();
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert!(
            !check(&path, &sha, 4).unwrap(),
            "before={before:?}, after={:?}",
            stamp(&File::open(&path).unwrap())
        );
        fs::remove_file(&path).unwrap();
        fs::write(&path, b"1234").unwrap();
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert!(!check(&path, &sha, 4).unwrap());
        crate::tests::cleanup(&root);
    }
}
