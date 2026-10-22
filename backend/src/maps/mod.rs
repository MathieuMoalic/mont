//! Watch map tile generation (`11/<x>/<y>.img` from a GPX route), ported
//! from the standalone gpx2img tool.

pub mod compile;
pub mod geometry;
pub mod jobs;
pub mod osm_source;

pub use jobs::Jobs;

use anyhow::{Context, bail};
use tokio::process::Command;

/// Styles accepted by `POST /maps/jobs`. `default` uses mkgmap's built-in
/// style; `cheetah-topo` ships the embedded `CheetahTopo` hiking style for
/// Amazfit watches.
pub const STYLES: [&str; 2] = ["default", "cheetah-topo"];

/// Default for the API form (matches what the standalone web UI selected).
pub const DEFAULT_STYLE: &str = "cheetah-topo";

/// Run an external command, capturing output (port of gpx2img `run_command`).
///
/// # Errors
/// The binary is missing or the command exits non-zero, with the captured
/// stderr/stdout as the error detail.
pub(crate) async fn run_command(args: &[String], label: &str) -> anyhow::Result<()> {
    let Some((program, rest)) = args.split_first() else {
        bail!("{label} failed: empty command");
    };
    let output = match Command::new(program).args(rest).output().await {
        Ok(output) => output,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            bail!("Missing required binary while running {label}")
        }
        Err(e) => return Err(e).context(format!("Spawning {label} failed")),
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let details = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("exit status {}", output.status.code().unwrap_or(-1))
        };
        bail!("{label} failed: {details}");
    }
    Ok(())
}

/// Check that a required binary is on `PATH` (port of gpx2img
/// `require_binary`).
///
/// # Errors
/// The binary is not found.
pub(crate) fn require_binary(name: &str) -> anyhow::Result<()> {
    if which::which(name).is_ok() {
        Ok(())
    } else {
        bail!("Missing required binary: {name}")
    }
}
