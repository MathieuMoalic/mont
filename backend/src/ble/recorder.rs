//! NDJSON session recorder: one file per relay session, one JSON line per frame.
//!
//! Recorded sessions are the debugging backbone — they are replayable fixtures
//! for offline driver/parser work, so a hardware session is never wasted.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

/// Direction of a recorded frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameDir {
    /// client → backend
    C2s,
    /// backend → client
    S2c,
    /// internal driver/system annotation
    Sys,
}

impl FrameDir {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::C2s => "c2s",
            Self::S2c => "s2c",
            Self::Sys => "sys",
        }
    }
}

#[derive(Serialize)]
struct Line<'a> {
    ts: f64,
    dir: &'static str,
    data: &'a serde_json::Value,
}

pub struct SessionRecorder {
    path: PathBuf,
    writer: Mutex<BufWriter<File>>,
}

impl SessionRecorder {
    /// Create a new session file named `session-<local time>-<uuid>.ndjson` in `dir`.
    ///
    /// # Errors
    /// Returns the underlying IO error if the directory cannot be created or the
    /// file cannot be opened.
    pub fn create(dir: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let path = dir.join(format!(
            "session-{stamp}-{}.ndjson",
            uuid::Uuid::new_v4().simple()
        ));
        let file = File::create(&path)?;
        Ok(Self {
            path,
            writer: Mutex::new(BufWriter::new(file)),
        })
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Append one frame to the session file.
    pub fn log(&self, dir: FrameDir, data: &serde_json::Value) {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let line = Line {
            ts,
            dir: dir.as_str(),
            data,
        };
        if let Ok(mut w) = self.writer.lock() {
            let _ = serde_json::to_writer(&mut *w, &line);
            let _ = w.write_all(b"\n");
            let _ = w.flush();
        }
    }
}
