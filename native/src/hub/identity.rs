use super::*;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

pub(super) struct Identity {
    pub config: Value,
    pub tls: Arc<rustls::ServerConfig>,
    pub code: String,
}

#[derive(serde::Serialize)]
struct ConnectionCode<'a> {
    id: &'a str,
    token: &'a str,
    fingerprint: String,
}

fn write_new(path: &Path, bytes: &[u8], private: bool) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(if private { 0o600 } else { 0o644 });
    }
    #[cfg(not(unix))]
    let _ = private;
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    blobs::sync_directory(path.parent().ok_or("Missing identity directory")?)?;
    Ok(())
}

impl Identity {
    pub fn load(config: &Config) -> Result<Self> {
        layout::relocate(
            &config.data.join("hub.json"),
            &layout::system(&config.data).join("hub.json"),
        )?;
        if config.certificate.is_none() {
            layout::relocate(
                &config.data.join("certificate.pem"),
                &layout::system(&config.data).join("certificate.pem"),
            )?;
        }
        if config.private_key.is_none() {
            layout::relocate(
                &config.data.join("private-key.pem"),
                &layout::system(&config.data).join("private-key.pem"),
            )?;
        }
        let path = layout::system(&config.data).join("hub.json");
        if !path.exists() {
            let mut random = [0u8; 32];
            rustls::crypto::ring::default_provider()
                .secure_random
                .fill(&mut random)
                .map_err(|_| "Secure random generator unavailable")?;
            let value = json!({"id":uuid::Uuid::new_v4().simple().to_string(),"token":URL_SAFE_NO_PAD.encode(random)});
            write_new(&path, &serde_json::to_vec(&value)?, true)?;
        }
        let value: Value = serde_json::from_slice(&fs::read(path)?)?;
        id(&value, "id")?;
        let token = string(&value, "token")?;
        if token.len() != 43 || !valid_id(token) {
            return Err("Invalid persisted NAS identity; original files were preserved".into());
        }
        let certificate = config
            .certificate
            .clone()
            .unwrap_or_else(|| layout::system(&config.data).join("certificate.pem"));
        let private_key = config
            .private_key
            .clone()
            .unwrap_or_else(|| layout::system(&config.data).join("private-key.pem"));
        if !certificate.exists() && !private_key.exists() {
            let rcgen::CertifiedKey { cert, signing_key } =
                rcgen::generate_simple_self_signed(vec!["lanflow.local".to_owned()])?;
            write_new(&private_key, signing_key.serialize_pem().as_bytes(), true)?;
            write_new(&certificate, cert.pem().as_bytes(), false)?;
        }
        // Read both files as-is, including the RSA PEM keys from the Python NAS.
        // A missing/damaged half is an error, never a reason to replace an identity.
        let certs = CertificateDer::pem_file_iter(&certificate)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let first = certs.first().ok_or("Missing NAS certificate")?;
        let connection = ConnectionCode {
            id: string(&value, "id")?,
            token,
            fingerprint: digest(first.as_ref()),
        };
        let code = format!(
            "lanflow1:{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&connection)?)
        );
        let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_single_cert(certs, PrivateKeyDer::from_pem_file(private_key)?)?;
        Ok(Self {
            config: value,
            tls: Arc::new(tls),
            code,
        })
    }
}
