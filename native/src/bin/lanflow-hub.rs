use lanflow_core::hub::{self, Config};
use std::{env, path::PathBuf, time::Duration};

fn main() {
    if let Err(error) = run() {
        eprintln!("LanFlow NAS: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut config = Config {
        data: PathBuf::from(env::var("LANFLOW_DATA").unwrap_or_else(|_| "/data".into())),
        host: "0.0.0.0".into(),
        port: 53320,
        name: env::var("LANFLOW_NAME").unwrap_or_else(|_| "LanFlow NAS".into()),
        certificate: None,
        private_key: None,
    };
    let mut healthcheck = false;
    let mut args = env::args().skip(1);
    while let Some(argument) = args.next() {
        if argument == "--healthcheck" {
            healthcheck = true;
            continue;
        }
        if argument == "--help" {
            println!(
                "lanflow-hub [--data DIR] [--host IP] [--port PORT] [--certificate PEM] [--private-key PEM] [--healthcheck]"
            );
            return Ok(());
        }
        let value = args.next().ok_or("Missing argument value")?;
        match argument.as_str() {
            "--data" => config.data = value.into(),
            "--host" => config.host = value,
            "--port" => config.port = value.parse()?,
            "--certificate" => config.certificate = Some(value.into()),
            "--private-key" => config.private_key = Some(value.into()),
            _ => return Err(format!("Unknown argument: {argument}").into()),
        }
    }
    if healthcheck {
        // Container-local liveness only; client sync continues to pin certificates.
        let client = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(true)
            .no_proxy()
            .timeout(Duration::from_secs(3))
            .build()?;
        client
            .get(format!("https://127.0.0.1:{}/health", config.port))
            .send()?
            .error_for_status()?;
        return Ok(());
    }
    hub::run(config)
}
