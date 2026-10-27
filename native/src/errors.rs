#[derive(Debug)]
pub(crate) struct ApiError {
    pub status: u16,
    pub message: String,
    pub category: Option<&'static str>,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for ApiError {}

pub(crate) fn api(
    status: u16,
    message: impl Into<String>,
) -> Box<dyn std::error::Error + Send + Sync> {
    Box::new(ApiError {
        status,
        message: message.into(),
        category: None,
    })
}

pub(crate) fn api_category(
    status: u16,
    category: &'static str,
    message: impl Into<String>,
) -> Box<dyn std::error::Error + Send + Sync> {
    Box::new(ApiError {
        status,
        message: message.into(),
        category: Some(category),
    })
}

pub(crate) fn status(error: &(dyn std::error::Error + 'static)) -> u16 {
    if let Some(error) = error.downcast_ref::<ApiError>() {
        error.status
    } else if error.is::<std::io::Error>() || error.is::<rusqlite::Error>() {
        507
    } else {
        400
    }
}

pub(crate) fn category(error: &(dyn std::error::Error + 'static)) -> &'static str {
    if let Some(error) = error.downcast_ref::<ApiError>() {
        if let Some(category) = error.category {
            return category;
        }
        return match error.status {
            401 | 403 => "authentication",
            404 => "protocol",
            409 => "conflict",
            499 => "cancelled",
            408 | 504 => "timeout",
            425 => "source_pending",
            429 | 502 | 503 => "busy",
            507 => "storage",
            _ => "invalid",
        };
    }
    if let Some(network) = error.downcast_ref::<reqwest::Error>() {
        let mut cause = error.source();
        while let Some(value) = cause {
            if value
                .to_string()
                .contains("Device certificate identity mismatch")
            {
                return "identity";
            }
            cause = value.source();
        }
        if network.is_timeout() {
            return "timeout";
        }
        if network.is_connect() {
            return "offline";
        }
        if let Some(status) = network.status() {
            return match status.as_u16() {
                401 | 403 => "authentication",
                404 => "protocol",
                409 => "conflict",
                408 | 504 => "timeout",
                429 | 502 | 503 => "busy",
                507 => "remote_storage",
                _ => "invalid",
            };
        }
        return "offline";
    }
    if let Some(io) = error.downcast_ref::<std::io::Error>() {
        // reqwest's blocking body reader preserves its network error inside an
        // io::Error. Inspect that cause before treating IO as a disk failure.
        if let Some(inner) = io.get_ref() {
            let kind = category(inner);
            if kind != "unknown" {
                return kind;
            }
        }
        return match io.kind() {
            std::io::ErrorKind::TimedOut => "timeout",
            std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionRefused
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::BrokenPipe => "offline",
            _ => "storage",
        };
    }
    if error.is::<rusqlite::Error>() {
        return "storage";
    }
    if matches!(
        error.to_string().as_str(),
        "File checksum mismatch" | "Remote file checksum mismatch" | "Local file is incomplete"
    ) {
        return "integrity";
    }
    "unknown"
}
