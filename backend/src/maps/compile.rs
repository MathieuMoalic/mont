//! Tile compilation with `osmium` + mkgmap, ported from gpx2img's
//! `compile_tiles` (without the dry-run/manifest paths mont doesn't use).

use std::path::{Path, PathBuf};

use anyhow::Context;

use super::geometry::{self, ZOOM};
use super::run_command;

/// Options for one tile-compilation run.
#[derive(Debug, Clone)]
pub struct CompileParams {
    pub buffer_km: f64,
    pub overlap_degrees: f64,
    pub levels: Option<String>,
    pub overview_levels: Option<String>,
    pub style: String,
}

/// Resolve mkgmap `--levels`/`--overview-levels`, defaulting to the style's
/// scheme when the caller doesn't override them.
#[must_use]
pub fn resolve_levels(
    style_dir: Option<&Path>,
    levels: Option<String>,
    overview_levels: Option<String>,
) -> (String, String) {
    match style_dir {
        None => (
            levels.unwrap_or_else(|| "0:24,1:22,2:20,3:18,4:16".to_string()),
            overview_levels.unwrap_or_else(|| "3:18,4:16".to_string()),
        ),
        Some(_) => (
            levels.unwrap_or_else(|| "0:22,1:20,2:18,3:16".to_string()),
            overview_levels.unwrap_or_else(|| "2:18,3:16".to_string()),
        ),
    }
}

/// Build the java invocation for mkgmap.
///
/// When a `lib/` directory sits next to the jar (full mkgmap distributions,
/// e.g. the Nix-bundled one), launch via classpath so the bundled
/// dependencies are picked up.
#[must_use]
pub fn mkgmap_command(mkgmap_jar: &Path, args: &[String]) -> Vec<String> {
    let classpath_dir = mkgmap_jar.parent().unwrap_or_else(|| Path::new(""));
    let lib_dir = classpath_dir.join("lib");
    if lib_dir.is_dir() {
        let classpath = format!(
            "{}:{}",
            classpath_dir.join("mkgmap.jar").display(),
            lib_dir.join("*").display()
        );
        let mut command = vec![
            "java".to_string(),
            "-cp".to_string(),
            classpath,
            "uk.me.parabola.mkgmap.main.Main".to_string(),
        ];
        command.extend(args.iter().cloned());
        return command;
    }
    let mut command = vec![
        "java".to_string(),
        "-jar".to_string(),
        mkgmap_jar.display().to_string(),
    ];
    command.extend(args.iter().cloned());
    command
}

/// Remove `.img` files under `tile_root` that are not in `tiles`, and delete
/// child directories left empty. Returns the removed paths in sorted order.
///
/// # Errors
/// Directory traversal fails.
pub fn prune_stale_tiles(tile_root: &Path, tiles: &[(u32, u32)]) -> anyhow::Result<Vec<PathBuf>> {
    let mut removed = Vec::new();
    if !tile_root.is_dir() {
        return Ok(removed);
    }
    let mut imgs = Vec::new();
    collect_imgs(tile_root, &mut imgs)?;
    imgs.sort();
    for img in imgs {
        let Ok(rel) = img.strip_prefix(tile_root) else {
            continue;
        };
        let mut parts = rel.components();
        let (Some(first), Some(second)) = (parts.next(), parts.next()) else {
            continue;
        };
        if parts.next().is_some() {
            continue;
        }
        let std::path::Component::Normal(x_str) = first else {
            continue;
        };
        let Some(x) = x_str.to_string_lossy().parse::<u32>().ok() else {
            continue;
        };
        let std::path::Component::Normal(y_name) = second else {
            continue;
        };
        let y_str = y_name.to_string_lossy();
        let Some(y) = y_str
            .strip_suffix(".img")
            .and_then(|stem| stem.parse::<u32>().ok())
        else {
            continue;
        };
        if !tiles.contains(&(x, y)) {
            std::fs::remove_file(&img)
                .with_context(|| format!("Removing stale tile {}", img.display()))?;
            removed.push(img);
        }
    }
    for entry in std::fs::read_dir(tile_root)? {
        let dir = entry?.path();
        if dir.is_dir() && is_empty_dir(&dir) {
            std::fs::remove_dir(&dir)?;
        }
    }
    Ok(removed)
}

fn collect_imgs(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            collect_imgs(&path, out)?;
        } else if path.extension().is_some_and(|ext| ext == "img") {
            out.push(path);
        }
    }
    Ok(())
}

fn is_empty_dir(dir: &Path) -> bool {
    std::fs::read_dir(dir).is_ok_and(|mut entries| entries.next().is_none())
}

/// Compile the zoom-11 tiles for a GPX route. Returns the compiled tile list.
///
/// # Errors
/// Missing binaries/jar/input files, GPX parsing, or a failing `osmium` /
/// mkgmap invocation.
pub async fn compile_tiles(
    gpx_path: &Path,
    osm_pbf_path: &Path,
    mkgmap_jar: &Path,
    output_dir: &Path,
    params: &CompileParams,
    style_dir: Option<&Path>,
    progress: &(dyn Fn(&str) + Send + Sync),
) -> anyhow::Result<Vec<(u32, u32)>> {
    super::require_binary("java")?;
    super::require_binary("osmium")?;
    anyhow::ensure!(gpx_path.exists(), "Missing GPX: {}", gpx_path.display());
    anyhow::ensure!(
        mkgmap_jar.exists(),
        "Missing mkgmap jar: {}",
        mkgmap_jar.display()
    );
    anyhow::ensure!(
        osm_pbf_path.exists(),
        "Missing OSM PBF: {}",
        osm_pbf_path.display()
    );

    let (levels, overview_levels) = resolve_levels(
        style_dir,
        params.levels.clone(),
        params.overview_levels.clone(),
    );

    let points = geometry::gpx_points(&std::fs::read(gpx_path)?)?;
    let route_bounds = geometry::parse_gpx_bounds(&points)?;
    let buffered = geometry::expand_bounds(route_bounds, params.buffer_km)?;
    let tiles = geometry::tiles_for_bounds(buffered, ZOOM);
    anyhow::ensure!(!tiles.is_empty(), "No tiles generated for GPX bounds");
    progress(&format!("Generating {} tiles", tiles.len()));

    let tile_root = output_dir.join("11");
    std::fs::create_dir_all(&tile_root)?;
    let stale = prune_stale_tiles(&tile_root, &tiles)?;
    if !stale.is_empty() {
        progress(&format!("Removed {} stale tiles", stale.len()));
    }
    let work_dir = output_dir.join("_work");
    std::fs::create_dir_all(&work_dir)?;

    let total = tiles.len();
    for (idx, &(x, y)) in tiles.iter().enumerate() {
        let bbox =
            geometry::tile_extract_bounds(x, y, params.overlap_degrees, ZOOM, params.buffer_km);
        let bbox_arg = format!(
            "{},{},{},{}",
            bbox.min_lon, bbox.min_lat, bbox.max_lon, bbox.max_lat
        );
        let osm_extract = work_dir.join(format!("{x}_{y}.osm.pbf"));
        // 8-digit zero-padded mkgmap mapname.
        let mapname = format!("{x:04}{y:04}");
        let raw_img = work_dir.join(format!("{mapname}.img"));
        let final_dir = tile_root.join(x.to_string());
        let final_img = final_dir.join(format!("{y}.img"));

        progress(&format!(
            "[{}/{}] Extracting tile source data for z11/{x}/{y}",
            idx + 1,
            total
        ));
        run_command(
            &[
                "osmium".to_string(),
                "extract".to_string(),
                "--overwrite".to_string(),
                "--bbox".to_string(),
                bbox_arg,
                "--output".to_string(),
                osm_extract.display().to_string(),
                osm_pbf_path.display().to_string(),
            ],
            &format!("osmium extract z11/{x}/{y}"),
        )
        .await?;

        progress(&format!(
            "[{}/{}] Running mkgmap for z11/{x}/{y}",
            idx + 1,
            total
        ));
        let mut mkgmap_args = vec![
            format!("--output-dir={}", work_dir.display()),
            format!("--mapname={mapname}"),
            "--description=OSM street map".to_string(),
            "--family-id=6324".to_string(),
            "--product-id=1".to_string(),
            format!("--levels={levels}"),
            format!("--overview-levels={overview_levels}"),
        ];
        if let Some(style) = style_dir {
            mkgmap_args.push(format!("--style-file={}", style.display()));
        }
        mkgmap_args.push(osm_extract.display().to_string());
        run_command(
            &mkgmap_command(mkgmap_jar, &mkgmap_args),
            &format!("mkgmap z11/{x}/{y}"),
        )
        .await?;

        std::fs::create_dir_all(&final_dir)?;
        std::fs::rename(&raw_img, &final_img)
            .with_context(|| format!("Moving {} to {}", raw_img.display(), final_img.display()))?;
        let _ = tokio::fs::remove_file(&osm_extract).await;
    }
    Ok(tiles)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_default_to_style_scheme() {
        let (levels, overview) = resolve_levels(None, None, None);
        assert_eq!(levels, "0:24,1:22,2:20,3:18,4:16");
        assert_eq!(overview, "3:18,4:16");

        let (levels, overview) = resolve_levels(Some(Path::new("/styles/CheetahTopo")), None, None);
        assert_eq!(levels, "0:22,1:20,2:18,3:16");
        assert_eq!(overview, "2:18,3:16");

        let (levels, _) = resolve_levels(None, Some("1:20".to_string()), None);
        assert_eq!(levels, "1:20");
    }

    #[test]
    fn mkgmap_command_uses_classpath_when_lib_dir_present() {
        let dir = tempfile::tempdir().expect("tempdir");
        let jar = dir.path().join("mkgmap.jar");
        std::fs::write(&jar, b"jar").expect("write jar");
        std::fs::create_dir(dir.path().join("lib")).expect("mkdir");

        let command = mkgmap_command(&jar, &["--levels=1:20".to_string()]);
        assert_eq!(command[0], "java");
        assert_eq!(command[1], "-cp");
        assert_eq!(
            command[2],
            format!(
                "{}/mkgmap.jar:{}/lib/*",
                dir.path().display(),
                dir.path().display()
            )
        );
        assert_eq!(command[3], "uk.me.parabola.mkgmap.main.Main");
        assert_eq!(command[4], "--levels=1:20");
    }

    #[test]
    fn mkgmap_command_uses_jar_without_lib_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let jar = dir.path().join("mkgmap.jar");
        std::fs::write(&jar, b"jar").expect("write jar");

        let command = mkgmap_command(&jar, &[]);
        assert_eq!(
            command,
            vec!["java", "-jar", jar.display().to_string().as_str()]
        );
    }

    #[test]
    fn prune_stale_tiles_removes_missing_tiles_and_empty_dirs() {
        let dir = tempfile::tempdir().expect("tempdir");
        let tile_root = dir.path().join("11");
        std::fs::create_dir_all(tile_root.join("1120")).expect("mkdir");
        std::fs::create_dir_all(tile_root.join("1119")).expect("mkdir");
        std::fs::write(tile_root.join("1120/672.img"), b"keep").expect("write");
        std::fs::write(tile_root.join("1119/673.img"), b"stale").expect("write");

        let removed = prune_stale_tiles(&tile_root, &[(1120, 672)]).expect("prune");
        assert_eq!(removed, vec![tile_root.join("1119/673.img")]);
        assert!(tile_root.join("1120/672.img").exists());
        assert!(!tile_root.join("1119").exists());
    }

    #[test]
    fn prune_stale_tiles_ignores_unrelated_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        let tile_root = dir.path().join("11");
        std::fs::create_dir_all(&tile_root).expect("mkdir");
        std::fs::write(tile_root.join("readme.txt"), b"txt").expect("write");
        std::fs::write(tile_root.join("deep"), b"file at root").expect("write");

        let removed = prune_stale_tiles(&tile_root, &[]).expect("prune");
        assert!(removed.is_empty());
        assert!(tile_root.join("readme.txt").exists());
    }
}
