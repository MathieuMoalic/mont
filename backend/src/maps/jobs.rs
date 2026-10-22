//! In-memory job registry and the background pipeline for map builds.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use serde::Serialize;

use crate::map_styles;
use crate::models::AppState;

use super::compile::{self, CompileParams};
use super::geometry;
use super::osm_source::GeofabrikResolver;

/// Finished jobs (and their temp dirs) are dropped this long after creation.
const JOB_TTL: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum JobStatus {
    Queued,
    Running,
    Done,
    Error,
}

#[derive(Debug)]
struct JobState {
    status: JobStatus,
    logs: Vec<String>,
    error: Option<String>,
    temp_dir: PathBuf,
    zip_path: Option<PathBuf>,
    created_at: SystemTime,
}

/// Read-only view of a job, as returned by `GET /maps/jobs/{id}`.
#[derive(Debug, Clone, Serialize)]
pub struct JobSnapshot {
    pub job_id: String,
    pub status: JobStatus,
    pub logs: Vec<String>,
    pub error: Option<String>,
    pub ready: bool,
}

/// Options accepted by `POST /maps/jobs`.
#[derive(Debug, Clone)]
pub struct MapJobParams {
    pub style: String,
    pub buffer_km: f64,
    pub overlap_degrees: f64,
    pub refresh_osm: bool,
}

/// Why a job's ZIP cannot be downloaded yet.
#[derive(Debug)]
pub enum DownloadError {
    UnknownJob,
    NotFinished,
    Failed(String),
}

/// Registry of in-flight map-build jobs. Cloneable handle sharing one
/// `Arc<Mutex<HashMap>>` (mirrors `RateLimitState`).
#[derive(Clone, Default)]
pub struct Jobs(Arc<Mutex<HashMap<String, JobState>>>);

impl Jobs {
    #[must_use]
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(HashMap::new())))
    }

    /// Lock the registry, recovering from poisoning (a panicked job task must
    /// not take the whole registry down).
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, JobState>> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Remove finished jobs older than [`JOB_TTL`], returning their temp dirs
    /// for deletion outside the lock.
    fn prune_expired(&self) -> Vec<PathBuf> {
        let expired: Vec<String> = {
            let map = self.lock();
            map.iter()
                .filter(|(_, job)| {
                    matches!(job.status, JobStatus::Done | JobStatus::Error)
                        && job.created_at.elapsed().is_ok_and(|age| age > JOB_TTL)
                })
                .map(|(id, _)| id.clone())
                .collect()
        };
        let mut temp_dirs = Vec::new();
        for id in expired {
            let mut map = self.lock();
            if let Some(job) = map.remove(&id) {
                temp_dirs.push(job.temp_dir);
            }
        }
        temp_dirs
    }

    /// Register a queued job (also prunes expired finished jobs).
    pub fn insert(&self, id: String, temp_dir: PathBuf) {
        {
            let mut map = self.lock();
            map.insert(
                id,
                JobState {
                    status: JobStatus::Queued,
                    logs: vec!["Upload received".to_string(), "Job queued".to_string()],
                    error: None,
                    temp_dir,
                    zip_path: None,
                    created_at: SystemTime::now(),
                },
            );
        }
        for dir in self.prune_expired() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    pub fn log(&self, id: &str, message: &str) {
        let mut map = self.lock();
        if let Some(job) = map.get_mut(id) {
            job.logs.push(message.to_string());
        }
    }

    pub(crate) fn set_running(&self, id: &str) {
        let mut map = self.lock();
        if let Some(job) = map.get_mut(id) {
            job.status = JobStatus::Running;
        }
    }

    pub(crate) fn finish(&self, id: &str, zip_path: PathBuf) {
        let mut map = self.lock();
        if let Some(job) = map.get_mut(id) {
            job.status = JobStatus::Done;
            job.zip_path = Some(zip_path);
        }
    }

    pub(crate) fn fail(&self, id: &str, error: &str) {
        let mut map = self.lock();
        if let Some(job) = map.get_mut(id) {
            job.status = JobStatus::Error;
            job.error = Some(error.to_string());
        }
    }

    /// Read-only snapshot for the status endpoint.
    #[must_use]
    pub fn snapshot(&self, id: &str) -> Option<JobSnapshot> {
        let map = self.lock();
        map.get(id).map(|job| JobSnapshot {
            job_id: id.to_string(),
            status: job.status,
            logs: job.logs.clone(),
            error: job.error.clone(),
            ready: job.status == JobStatus::Done && job.zip_path.is_some(),
        })
    }

    /// Claim a finished job's ZIP for download: removes the job entry and
    /// returns the ZIP plus temp-dir paths (the caller deletes the temp dir
    /// after serving). Downloads are single-use, like gpx2img's; unfinished
    /// and failed jobs stay in the registry so clients can poll again.
    ///
    /// # Errors
    /// [`DownloadError`] when the job is unknown, unfinished, or failed.
    pub fn take_download(&self, id: &str) -> Result<(PathBuf, PathBuf), DownloadError> {
        let mut map = self.lock();
        let result = match map.get(id).map(|job| job.status) {
            None => Err(DownloadError::UnknownJob),
            Some(JobStatus::Done) => match map.remove(id) {
                Some(job) => match job.zip_path {
                    Some(zip_path) => Ok((zip_path, job.temp_dir)),
                    None => Err(DownloadError::Failed("Job produced no ZIP".to_string())),
                },
                None => Err(DownloadError::UnknownJob),
            },
            Some(JobStatus::Error) => Err(DownloadError::Failed(
                map.get(id)
                    .and_then(|job| job.error.clone())
                    .unwrap_or_else(|| "Job failed".to_string()),
            )),
            Some(_) => Err(DownloadError::NotFinished),
        };
        drop(map);
        result
    }
}

/// Queue a map-build job to run in the background.
pub fn spawn(state: AppState, job_id: String, temp_dir: PathBuf, params: MapJobParams) {
    tokio::spawn(async move {
        if let Err(error) = run_pipeline(&state, &job_id, &temp_dir, &params).await {
            let detail = format!("{error:#}");
            state.maps_jobs.log(&job_id, &format!("Error: {detail}"));
            state.maps_jobs.fail(&job_id, &detail);
        }
    });
}

async fn run_pipeline(
    state: &AppState,
    job_id: &str,
    temp_dir: &Path,
    params: &MapJobParams,
) -> anyhow::Result<()> {
    state.maps_jobs.set_running(job_id);

    let jobs_for_progress = state.maps_jobs.clone();
    let id_for_progress = job_id.to_string();
    let progress = move |message: &str| jobs_for_progress.log(&id_for_progress, message);

    let gpx_path = temp_dir.join("upload.gpx");
    let gpx_bytes = tokio::fs::read(&gpx_path).await?;
    let points = geometry::gpx_points(&gpx_bytes)?;
    // Fail fast on routes that produce no tiles, before any downloads happen.
    geometry::required_tiles_and_bounds(&points, params.buffer_km, params.overlap_degrees)?;

    let style_dir = if params.style == "cheetah-topo" {
        map_styles::extract_style("CheetahTopo", &temp_dir.join("styles"))?
    } else {
        None
    };
    anyhow::ensure!(
        params.style != "cheetah-topo" || style_dir.is_some(),
        "CheetahTopo style files are missing from this build"
    );

    let resolver = GeofabrikResolver::new(state.config.osm_cache_dir());
    let resolution = resolver
        .resolve(
            &state.http,
            &points,
            &super::osm_source::ResolveOptions {
                buffer_km: params.buffer_km,
                overlap_degrees: params.overlap_degrees,
                refresh_osm: params.refresh_osm,
            },
            temp_dir,
            &progress,
        )
        .await?;

    let jar = state
        .config
        .mkgmap_jar
        .clone()
        .expect("validated at job creation");
    compile::compile_tiles(
        &gpx_path,
        &resolution.pbf_path,
        &jar,
        temp_dir,
        &CompileParams {
            buffer_km: params.buffer_km,
            overlap_degrees: params.overlap_degrees,
            levels: None,
            overview_levels: None,
            style: params.style.clone(),
        },
        style_dir.as_deref(),
        &progress,
    )
    .await?;

    progress("Packaging ZIP archive");
    let zip_path = temp_dir.join("11.zip");
    zip_tiles(&temp_dir.join("11"), &zip_path)?;
    state.maps_jobs.finish(job_id, zip_path);
    Ok(())
}

/// Zip the `11/` tile tree into `zip_path`, with `11/` as the archive root
/// (the layout Gadgetbridge expects on the watch).
///
/// # Errors
/// Filesystem or zip-writing failures.
fn zip_tiles(tile_root: &Path, zip_path: &Path) -> anyhow::Result<()> {
    let prefix = tile_root.file_name().map_or_else(
        || "11".to_string(),
        |name: &std::ffi::OsStr| name.to_string_lossy().into_owned(),
    );
    let file = std::fs::File::create(zip_path)?;
    let mut writer = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let mut added = 0_usize;
    let mut files: Vec<PathBuf> = Vec::new();
    let mut stack = vec![tile_root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                files.push(path);
            }
        }
    }
    // Deterministic archive order.
    files.sort();
    for path in files {
        let rel = path.strip_prefix(tile_root)?;
        writer.start_file(format!("{prefix}/{}", rel.display()), options)?;
        std::io::Write::write_all(&mut writer, &std::fs::read(&path)?)?;
        added += 1;
    }
    anyhow::ensure!(added > 0, "No tiles produced to package");
    writer.finish()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_lifecycle_insert_snapshot_take_download() {
        let jobs = Jobs::new();
        let temp = tempfile::tempdir().expect("tempdir");
        let temp_dir = temp.path().to_path_buf();

        jobs.insert("job1".to_string(), temp_dir.clone());
        let snapshot = jobs.snapshot("job1").expect("snapshot");
        assert_eq!(snapshot.status, JobStatus::Queued);
        assert!(!snapshot.ready);
        assert_eq!(snapshot.logs.len(), 2);

        jobs.log("job1", "Step");
        assert_eq!(jobs.snapshot("job1").expect("snapshot").logs.len(), 3);

        // Not finished yet.
        assert!(matches!(
            jobs.take_download("job1"),
            Err(DownloadError::NotFinished)
        ));

        // Failed jobs surface their error on download.
        jobs.fail("job1", "boom");
        assert!(matches!(
            jobs.take_download("job1"),
            Err(DownloadError::Failed(message)) if message == "boom"
        ));

        // Done jobs yield the zip once, then the job is gone.
        jobs.insert("job2".to_string(), temp_dir.clone());
        let zip_path = temp_dir.join("11.zip");
        std::fs::write(&zip_path, b"zip").expect("write zip");
        jobs.finish("job2", zip_path.clone());
        assert!(jobs.snapshot("job2").expect("snapshot").ready);
        let (taken_zip, taken_temp) = jobs.take_download("job2").expect("download");
        assert_eq!(taken_zip, zip_path);
        assert_eq!(taken_temp, temp_dir);
        assert!(jobs.snapshot("job2").is_none());
        assert!(matches!(
            jobs.take_download("job2"),
            Err(DownloadError::UnknownJob)
        ));

        assert!(matches!(
            jobs.take_download("unknown"),
            Err(DownloadError::UnknownJob)
        ));
    }

    #[test]
    fn zip_tiles_packages_11_tree() {
        let temp = tempfile::tempdir().expect("tempdir");
        let tile_root = temp.path().join("11");
        std::fs::create_dir_all(tile_root.join("1120")).expect("mkdir");
        std::fs::write(tile_root.join("1120/672.img"), b"tile").expect("write");
        std::fs::write(tile_root.join("readme.txt"), b"txt").expect("write");

        let zip_path = temp.path().join("11.zip");
        zip_tiles(&tile_root, &zip_path).expect("zip");

        let file = std::fs::File::open(&zip_path).expect("open zip");
        let mut archive = zip::ZipArchive::new(file).expect("archive");
        let names: Vec<String> = (0..archive.len())
            .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_string()))
            .collect();
        // Everything under 11/ is packaged (matches gpx2img's make_archive).
        assert_eq!(names, vec!["11/1120/672.img", "11/readme.txt"]);
    }

    #[test]
    fn zip_tiles_without_tiles_is_an_error() {
        let temp = tempfile::tempdir().expect("tempdir");
        let tile_root = temp.path().join("11");
        std::fs::create_dir_all(&tile_root).expect("mkdir");
        let zip_path = temp.path().join("11.zip");
        assert!(zip_tiles(&tile_root, &zip_path).is_err());
    }
}
