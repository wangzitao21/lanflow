mod attachments;
mod backup;
mod blobs;
mod bridge;
mod errors;
mod events;
mod favorites;
mod history;
#[cfg(feature = "hub")]
pub mod hub;
mod layout;
mod maintenance;
mod maintenance_gc;
mod search;
mod short_search;
mod storage;
mod sync;
mod sync_control;
mod transfers;
mod verified_files;

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
type Database = Arc<Mutex<Connection>>;
static DATABASES: OnceLock<Mutex<HashMap<PathBuf, Database>>> = OnceLock::new();
const MAX_FILE: u64 = 100 * 1024 * 1024 * 1024;

fn valid_id(s: &str) -> bool {
    (16..=64).contains(&s.len())
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
}
fn valid_digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .ok_or_else(|| format!("Invalid {key}").into())
}
fn id(v: &Value, key: &str) -> Result<String> {
    let value = string(v, key)?;
    if !valid_id(value) {
        return Err(format!("Invalid {key}").into());
    }
    Ok(value.to_owned())
}
#[cfg(test)]
fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Micros, true)
}
fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

use blobs::{hash_file, import_file};
use bridge::dispatch;
use events::{apply, deleted, item_event, validate_item};
use storage::{database, initialize, page, snapshot_since};

// The ABI owns returned strings; callers release them with lanflow_free.
/// # Safety
/// `request` must be null or point to a valid, NUL-terminated UTF-8 C string
/// that remains readable for this call. Release the result with `lanflow_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lanflow_call(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        if request.is_null() {
            return Err("Missing request".into());
        }
        let text = unsafe { CStr::from_ptr(request) }.to_str()?;
        dispatch(serde_json::from_str(text)?)
    });
    let response = match result {
        Ok(Ok(value)) => json!({"ok":true,"value":value}),
        Ok(Err(error)) => {
            json!({"ok":false,"error":error.to_string(),"status":errors::status(error.as_ref()),"category":errors::category(error.as_ref())})
        }
        Err(_) => json!({"ok":false,"error":"Native operation failed"}),
    };
    CString::new(response.to_string()).unwrap().into_raw()
}
#[unsafe(no_mangle)]
/// # Safety
/// `value` must be null or an unfreed pointer returned by `lanflow_call`.
pub unsafe extern "C" fn lanflow_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod attachment_tests;
#[cfg(test)]
mod blob_tests;
#[cfg(test)]
mod bootstrap_tests;
#[cfg(test)]
mod favorite_snapshot_tests;
#[cfg(test)]
mod storage_behavior_tests;
#[cfg(test)]
mod sync_regression_tests;
#[cfg(test)]
mod tests;
