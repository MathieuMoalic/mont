//! Geofabrik OSM source resolution, ported from gpx2img's `osm_source.py`.
//!
//! Given the required zoom-11 area for a route, pick the smallest single
//! Geofabrik extract covering it (falling back to a greedy set cover of
//! multiple extracts, cropped and merged with `osmium`), with a disk cache
//! for the index and downloaded `.osm.pbf` files.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use geo::{Area, BooleanOps, BoundingRect, Coord, LineString, MultiPolygon, Polygon};
use serde::Deserialize;
use tokio::io::AsyncWriteExt;

use super::geometry::{self, Bounds, ZOOM};
use super::run_command;

pub const GEOFABRIK_INDEX_URL: &str = "https://download.geofabrik.de/index-v1.json";
pub const DEFAULT_INDEX_TTL_SECS: u64 = 24 * 3600;
pub const DEFAULT_PBF_TTL_SECS: u64 = 7 * 24 * 3600;

/// Absolute area below which remaining geometry counts as covered.
const AREA_TOLERANCE: f64 = 1e-12;
/// Relative slack for `covers` checks. Shapely's `covers` is topological and
/// exact; the area-based approximation here needs enough slack to ignore
/// boundary slivers that the boolean-op backend rounds away (~1e-8 relative
/// on real Geofabrik admin polygons) while still rejecting genuinely
/// uncovered regions, which miss by orders of magnitude more.
const COVER_EPSILON: f64 = 1e-6;
/// A valid `.osm.pbf` is at least this many bytes.
const PBF_MIN_BYTES: u64 = 1024;

/// Disjoint polygon parts (normalized via union at construction).
type Geom = MultiPolygon<f64>;

#[derive(Debug, Clone)]
pub struct GeofabrikRegion {
    pub id: String,
    pub name: String,
    pub parent: Option<String>,
    pub pbf_url: String,
    pub geometry: Geom,
    pub depth: usize,
    pub area: f64,
}

#[derive(Debug)]
pub struct OsmResolution {
    pub pbf_path: PathBuf,
    pub mode: &'static str,
    pub region_ids: Vec<String>,
    pub tile_count: usize,
    pub required_bounds: Bounds,
}

/// Parameters for [`GeofabrikResolver::resolve`].
#[derive(Debug, Clone, Copy)]
pub struct ResolveOptions {
    pub buffer_km: f64,
    pub overlap_degrees: f64,
    pub refresh_osm: bool,
}

#[derive(Debug)]
pub struct RequiredArea {
    pub tiles: Vec<(u32, u32)>,
    pub bounds: Bounds,
    pub geometry: Geom,
}

fn rect_polygon(b: Bounds) -> Polygon<f64> {
    Polygon::new(
        LineString::new(vec![
            Coord {
                x: b.min_lon,
                y: b.min_lat,
            },
            Coord {
                x: b.max_lon,
                y: b.min_lat,
            },
            Coord {
                x: b.max_lon,
                y: b.max_lat,
            },
            Coord {
                x: b.min_lon,
                y: b.max_lat,
            },
            Coord {
                x: b.min_lon,
                y: b.min_lat,
            },
        ]),
        vec![],
    )
}

fn union_fold(polys: Vec<Polygon<f64>>) -> Geom {
    polys
        .into_iter()
        .map(|poly| MultiPolygon::new(vec![poly]))
        .reduce(|acc, poly| acc.union(&poly))
        .unwrap_or_else(|| MultiPolygon::new(vec![]))
}

fn area_of(g: &Geom) -> f64 {
    g.unsigned_area()
}

fn intersection_area(a: &Geom, b: &Geom) -> f64 {
    a.intersection(b).unsigned_area()
}

/// `covers` in the shapely sense: `b` is inside `a` or on its boundary.
fn covers(a: &Geom, b: &Geom) -> bool {
    let b_area = area_of(b);
    intersection_area(a, b) >= b_area - (b_area * COVER_EPSILON).max(AREA_TOLERANCE)
}

fn intersects(a: &Geom, b: &Geom) -> bool {
    intersection_area(a, b) > AREA_TOLERANCE
}

/// The zoom-11 tiles plus their union geometry (tile boxes clamped at
/// ±180 with the antimeridian patch from the Python implementation).
///
/// # Errors
/// See [`geometry::required_tiles_and_bounds`].
pub fn required_osm_geometry(
    points: &[(f64, f64)],
    buffer_km: f64,
    overlap_degrees: f64,
) -> anyhow::Result<RequiredArea> {
    let (tiles, bounds) = geometry::required_tiles_and_bounds(points, buffer_km, overlap_degrees)?;
    let mut polys = Vec::with_capacity(tiles.len());
    for &(x, y) in &tiles {
        let tb = geometry::tile_bounds(x, y, ZOOM);
        let mut b = geometry::tile_extract_bounds(x, y, overlap_degrees, ZOOM, buffer_km);
        // tile_extract_bounds clamps at ±180; relax those to exactly ±180 so
        // the boxes stay valid rectangles on the antimeridian edge.
        if tb.max_lon >= 179.9 && b.max_lon >= 180.0 {
            b.max_lon = 180.0;
        }
        if tb.min_lon <= -179.9 && b.min_lon <= -180.0 {
            b.min_lon = -180.0;
        }
        polys.push(rect_polygon(b));
    }
    Ok(RequiredArea {
        tiles,
        bounds,
        geometry: union_fold(polys),
    })
}

// ── GeoJSON parsing ──────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct IndexDoc {
    #[serde(default)]
    features: serde_json::Value,
}

#[derive(Deserialize)]
struct Feature {
    #[serde(default)]
    properties: Option<FeatureProps>,
    #[serde(default)]
    geometry: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct FeatureProps {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    parent: Option<String>,
    #[serde(default)]
    urls: Option<FeatureUrls>,
}

#[derive(Deserialize)]
struct FeatureUrls {
    #[serde(default)]
    pbf: Option<String>,
}

// The exact float comparison is intentional: a closed GeoJSON ring repeats
// its first coordinate verbatim.
#[allow(clippy::float_cmp)]
fn ring_to_line_string(ring: &[serde_json::Value]) -> Option<LineString<f64>> {
    let mut coords = Vec::with_capacity(ring.len());
    for point in ring {
        let pair = point.as_array()?;
        if pair.len() < 2 {
            return None;
        }
        coords.push(Coord {
            x: pair[0].as_f64()?,
            y: pair[1].as_f64()?,
        });
    }
    // GeoJSON rings are closed; close them anyway if the source omits it.
    match (coords.first(), coords.last()) {
        (Some(first), Some(last)) if first.x != last.x || first.y != last.y => {
            coords.push(*first);
        }
        _ => {}
    }
    Some(LineString::new(coords))
}

fn polygon_from_rings(rings: &[serde_json::Value]) -> Option<Polygon<f64>> {
    let mut rings = rings.iter();
    let exterior = ring_to_line_string(rings.next()?.as_array()?)?;
    let holes: Vec<LineString<f64>> = rings
        .filter_map(|r| r.as_array().and_then(|r| ring_to_line_string(r)))
        .collect();
    Some(Polygon::new(exterior, holes))
}

/// Convert a `GeoJSON` `Polygon` or `MultiPolygon` into normalized (disjoint)
/// parts.
fn geometry_from_geojson(value: &serde_json::Value) -> Option<Geom> {
    let kind = value.get("type")?.as_str()?;
    let coords = value.get("coordinates")?.as_array()?;
    let polys: Vec<Polygon<f64>> = match kind {
        // Polygon coordinates are the rings array itself.
        "Polygon" => polygon_from_rings(coords).into_iter().collect(),
        "MultiPolygon" => coords
            .iter()
            .filter_map(|p| p.as_array().and_then(|rings| polygon_from_rings(rings)))
            .collect(),
        _ => return None,
    };
    if polys.is_empty() {
        return None;
    }
    let geom = union_fold(polys);
    if geom.0.is_empty() { None } else { Some(geom) }
}

// ── Region selection (pure logic, unit-testable) ─────────────────────────────

fn choose_single_cover(regions: &[GeofabrikRegion], required: &Geom) -> Option<GeofabrikRegion> {
    let mut covers: Vec<&GeofabrikRegion> = regions
        .iter()
        .filter(|r| covers(&r.geometry, required))
        .collect();
    covers.sort_by(|a, b| {
        b.depth
            .cmp(&a.depth)
            .then(a.area.total_cmp(&b.area))
            .then(a.id.cmp(&b.id))
    });
    covers.first().map(|r| (*r).clone())
}

fn choose_multi_cover(
    regions: &[GeofabrikRegion],
    required: &Geom,
) -> anyhow::Result<Vec<GeofabrikRegion>> {
    let mut candidates: Vec<&GeofabrikRegion> = regions
        .iter()
        .filter(|r| intersects(&r.geometry, required))
        .collect();
    candidates.sort_by(|a, b| {
        b.depth
            .cmp(&a.depth)
            .then(a.area.total_cmp(&b.area))
            .then(a.id.cmp(&b.id))
    });

    let mut selected: Vec<GeofabrikRegion> = Vec::new();
    let mut covered = MultiPolygon::new(vec![]);
    let mut remaining = required.clone();
    let mut remaining_area = area_of(&remaining);

    loop {
        if remaining_area <= AREA_TOLERANCE {
            break;
        }
        let mut best: Option<&GeofabrikRegion> = None;
        let mut best_key: Option<(f64, usize, f64, f64, &str)> = None;
        for region in &candidates {
            let gain = intersection_area(&remaining, &region.geometry);
            if gain <= AREA_TOLERANCE {
                continue;
            }
            let ratio = gain / region.area.max(AREA_TOLERANCE);
            let key = (ratio, region.depth, gain, -region.area, region.id.as_str());
            let better = best_key.is_none_or(|prev| {
                key.0
                    .total_cmp(&prev.0)
                    .then(key.1.cmp(&prev.1))
                    .then(key.2.total_cmp(&prev.2))
                    .then(key.3.total_cmp(&prev.3))
                    .then(key.4.cmp(prev.4))
                    == std::cmp::Ordering::Greater
            });
            if better {
                best_key = Some(key);
                best = Some(region);
            }
        }
        let Some(region) = best else { break };
        selected.push(region.clone());
        // Union with an empty accumulator is a no-op the boolean-op backend
        // may not special-case, so seed it directly on the first pick.
        covered = if covered.0.is_empty() {
            region.geometry.clone()
        } else {
            covered.union(&region.geometry)
        };
        remaining = required.difference(&covered);
        remaining_area = area_of(&remaining);
    }

    if selected.is_empty() {
        return Ok(vec![]);
    }

    let selected = prune_redundant(selected, required);
    let union = selected
        .iter()
        .map(|r| r.geometry.clone())
        .reduce(|acc, g| acc.union(&g))
        .unwrap_or_else(|| MultiPolygon::new(vec![]));
    anyhow::ensure!(
        covers(&union, required),
        "Unable to cover required area with Geofabrik extracts"
    );
    let mut selected = selected;
    selected.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(selected)
}

fn prune_redundant(selected: Vec<GeofabrikRegion>, required: &Geom) -> Vec<GeofabrikRegion> {
    let mut pruned = selected;
    let mut changed = true;
    while changed {
        changed = false;
        let mut order = pruned.clone();
        order.sort_by(|a, b| {
            b.area
                .total_cmp(&a.area)
                .then(a.depth.cmp(&b.depth))
                .then(a.id.cmp(&b.id))
        });
        for region in &order {
            let trial: Vec<GeofabrikRegion> = pruned
                .iter()
                .filter(|r| r.id != region.id)
                .cloned()
                .collect();
            if trial.is_empty() {
                continue;
            }
            let union = trial
                .iter()
                .map(|r| r.geometry.clone())
                .reduce(|acc, g| acc.union(&g))
                .unwrap_or_else(|| MultiPolygon::new(vec![]));
            if covers(&union, required) {
                pruned = trial;
                changed = true;
                break;
            }
        }
    }
    pruned
}

fn pick_best_strategy(
    best_single: Option<GeofabrikRegion>,
    multi: Vec<GeofabrikRegion>,
) -> anyhow::Result<Vec<GeofabrikRegion>> {
    match (best_single, multi) {
        (None, multi) => {
            anyhow::ensure!(
                !multi.is_empty(),
                "No Geofabrik extract could cover required area"
            );
            Ok(multi)
        }
        (Some(single), multi) if multi.is_empty() => Ok(vec![single]),
        (Some(single), multi) => {
            let multi_area: f64 = multi.iter().map(|r| r.area).sum();
            if multi.len() > 1 && multi_area * 3.0 < single.area {
                Ok(multi)
            } else {
                Ok(vec![single])
            }
        }
    }
}

// ── Resolver (I/O + cache) ───────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct GeofabrikResolver {
    pub cache_dir: PathBuf,
    pub index_ttl: Duration,
    pub pbf_ttl: Duration,
}

impl GeofabrikResolver {
    #[must_use]
    pub const fn new(cache_dir: PathBuf) -> Self {
        Self {
            cache_dir,
            index_ttl: Duration::from_secs(DEFAULT_INDEX_TTL_SECS),
            pbf_ttl: Duration::from_secs(DEFAULT_PBF_TTL_SECS),
        }
    }

    /// Resolve the OSM source for the required area.
    ///
    /// # Errors
    /// Index download/parse failures, download failures, or the required
    /// area cannot be covered by Geofabrik extracts.
    pub async fn resolve(
        &self,
        http: &reqwest::Client,
        points: &[(f64, f64)],
        options: &ResolveOptions,
        work_dir: &Path,
        progress: &(dyn Fn(&str) + Send + Sync),
    ) -> anyhow::Result<OsmResolution> {
        let required = required_osm_geometry(points, options.buffer_km, options.overlap_degrees)?;
        progress(&format!(
            "GPX requires {} zoom-11 tiles",
            required.tiles.len()
        ));
        progress(&format!(
            "Required OSM bounds: {:.6},{:.6} -> {:.6},{:.6}",
            required.bounds.min_lat,
            required.bounds.min_lon,
            required.bounds.max_lat,
            required.bounds.max_lon
        ));

        progress("Loading Geofabrik index");
        let regions = self
            .load_regions(http, options.refresh_osm, progress)
            .await?;
        let best_single = choose_single_cover(&regions, &required.geometry);
        let multi = choose_multi_cover(&regions, &required.geometry)?;
        let chosen = pick_best_strategy(best_single, multi)?;

        if chosen.len() == 1 {
            let region = &chosen[0];
            let pbf = self
                .ensure_pbf(http, region, options.refresh_osm, progress)
                .await?;
            progress(&format!("OSM source: {}", region.id));
            return Ok(OsmResolution {
                pbf_path: pbf,
                mode: "single",
                region_ids: vec![region.id.clone()],
                tile_count: required.tiles.len(),
                required_bounds: required.bounds,
            });
        }

        progress(&format!(
            "Route crosses multiple OSM extracts: {}",
            chosen
                .iter()
                .map(|r| r.id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
        let mut extracted_inputs: Vec<PathBuf> = Vec::new();
        for region in &chosen {
            let source = self
                .ensure_pbf(http, region, options.refresh_osm, progress)
                .await?;
            extracted_inputs.extend(
                self.crop_to_required_parts(
                    &source,
                    &required.geometry,
                    work_dir,
                    &region.id,
                    progress,
                )
                .await?,
            );
        }

        anyhow::ensure!(
            !extracted_inputs.is_empty(),
            "Could not create cropped OSM extracts for merge"
        );
        let merged = work_dir.join("resolved-source.osm.pbf");
        progress(&format!(
            "Merging {} cropped extracts",
            extracted_inputs.len()
        ));
        let args: Vec<String> = std::iter::once("osmium".to_string())
            .chain([
                "merge".to_string(),
                "--overwrite".to_string(),
                "-o".to_string(),
            ])
            .chain(std::iter::once(merged.to_string_lossy().into_owned()))
            .chain(
                extracted_inputs
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned()),
            )
            .collect();
        run_command(&args, "Merging source extracts failed").await?;
        validate_pbf_file(&merged).await?;
        Ok(OsmResolution {
            pbf_path: merged,
            mode: "merged",
            region_ids: chosen.iter().map(|r| r.id.clone()).collect(),
            tile_count: required.tiles.len(),
            required_bounds: required.bounds,
        })
    }

    fn index_cache_path(&self) -> PathBuf {
        self.cache_dir.join("geofabrik-index-v1.json")
    }

    async fn load_regions(
        &self,
        http: &reqwest::Client,
        refresh: bool,
        progress: &(dyn Fn(&str) + Send + Sync),
    ) -> anyhow::Result<Vec<GeofabrikRegion>> {
        tokio::fs::create_dir_all(&self.cache_dir).await?;
        let index_path = self.index_cache_path();
        if refresh || is_stale(&index_path, self.index_ttl).await {
            progress("Downloading Geofabrik index");
            self.download_to(http, &index_path, GEOFABRIK_INDEX_URL)
                .await?;
        }

        let raw = tokio::fs::read_to_string(&index_path).await?;
        let doc: IndexDoc = serde_json::from_str(&raw).map_err(|e| {
            anyhow::anyhow!(
                "Invalid cached Geofabrik index at {}: {e}",
                index_path.display()
            )
        })?;
        let features = doc
            .features
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Geofabrik index is missing a valid feature list"))?;

        // (name, parent, pbf_url, geometry) per id — insertion order kept.
        let mut parsed: Vec<(String, String, Option<String>, String, Geom)> = Vec::new();
        for feature in features {
            let feature: Feature = serde_json::from_value(feature.clone())
                .map_err(|e| anyhow::anyhow!("Invalid Geofabrik feature: {e}"))?;
            let Some(props) = feature.properties else {
                continue;
            };
            let Some(region_id) = props.id.filter(|id| !id.is_empty()) else {
                continue;
            };
            let Some(pbf_url) = props.urls.and_then(|u| u.pbf) else {
                continue;
            };
            let Some(geometry) = feature.geometry.as_ref().and_then(geometry_from_geojson) else {
                continue;
            };
            let name = props
                .name
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| region_id.clone());
            parsed.push((region_id, name, props.parent, pbf_url, geometry));
        }
        let parents: HashMap<String, Option<String>> = parsed
            .iter()
            .map(|(id, _, parent, _, _)| (id.clone(), parent.clone()))
            .collect();

        let mut depth_cache: HashMap<String, usize> = HashMap::new();
        let mut regions = Vec::with_capacity(parsed.len());
        for (region_id, name, parent, pbf_url, geometry) in &parsed {
            let depth = depth_for(region_id, &parents, &mut depth_cache);
            let area = area_of(geometry);
            regions.push(GeofabrikRegion {
                id: region_id.clone(),
                name: name.clone(),
                parent: parent.clone(),
                pbf_url: pbf_url.clone(),
                geometry: geometry.clone(),
                depth,
                area,
            });
        }
        anyhow::ensure!(
            !regions.is_empty(),
            "No usable regions found in Geofabrik index"
        );
        Ok(regions)
    }

    async fn ensure_pbf(
        &self,
        http: &reqwest::Client,
        region: &GeofabrikRegion,
        refresh: bool,
        progress: &(dyn Fn(&str) + Send + Sync),
    ) -> anyhow::Result<PathBuf> {
        let filename = region
            .pbf_url
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .map_or_else(
                || format!("{}.osm.pbf", region.id.replace('/', "-")),
                str::to_string,
            );
        let target = self
            .cache_dir
            .join("extracts")
            .join(&region.id)
            .join(filename);
        if !refresh && !is_stale(&target, self.pbf_ttl).await {
            progress(&format!("Using cached OSM extract: {}", region.id));
            return Ok(target);
        }
        progress(&format!("Downloading OSM extract: {}", region.id));
        self.download_to(http, &target, &region.pbf_url).await?;
        validate_pbf_file(&target).await?;
        Ok(target)
    }

    async fn download_to(
        &self,
        http: &reqwest::Client,
        target: &Path,
        url: &str,
    ) -> anyhow::Result<()> {
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let tmp = target.with_extension(format!(
            "{}.part-{}-{}",
            target
                .extension()
                .map_or_else(String::new, |e| e.to_string_lossy().into_owned()),
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or_default(),
        ));
        let result = download_into(http, url, &tmp).await;
        match result {
            Ok(()) => {
                let size = tokio::fs::metadata(&tmp).await?.len();
                anyhow::ensure!(size > 0, "Downloaded file is empty");
                tokio::fs::rename(&tmp, target).await?;
                Ok(())
            }
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                Err(anyhow::anyhow!("Failed to download {url}: {e}"))
            }
        }
    }

    async fn crop_to_required_parts(
        &self,
        source: &Path,
        required: &Geom,
        work_dir: &Path,
        region_id: &str,
        progress: &(dyn Fn(&str) + Send + Sync),
    ) -> anyhow::Result<Vec<PathBuf>> {
        let safe_id = region_id.replace('/', "_");
        let mut out_paths = Vec::new();
        for (i, part) in required.0.iter().enumerate() {
            let Some(rect) = part.bounding_rect() else {
                continue;
            };
            let bbox_arg = format!(
                "{},{},{},{}",
                rect.min().x,
                rect.min().y,
                rect.max().x,
                rect.max().y
            );
            let cropped = work_dir.join(format!("{safe_id}-{i}.crop.osm.pbf"));
            progress(&format!(
                "Cropping extract {region_id} (part {}/{})",
                i + 1,
                required.0.len()
            ));
            let args = vec![
                "osmium".to_string(),
                "extract".to_string(),
                "--overwrite".to_string(),
                "--bbox".to_string(),
                bbox_arg,
                "--output".to_string(),
                cropped.to_string_lossy().into_owned(),
                source.to_string_lossy().into_owned(),
            ];
            run_command(&args, &format!("Cropping extract failed for {region_id}")).await?;
            let size = tokio::fs::metadata(&cropped)
                .await
                .map(|m| m.len())
                .unwrap_or(0);
            if size > 0 {
                out_paths.push(cropped);
            }
        }
        Ok(out_paths)
    }
}

async fn download_into(http: &reqwest::Client, url: &str, tmp: &Path) -> anyhow::Result<()> {
    let mut response = http.get(url).send().await?.error_for_status()?;
    let mut file = tokio::fs::File::create(tmp).await?;
    let mut written = 0_u64;
    while let Some(chunk) = response.chunk().await? {
        file.write_all(&chunk).await?;
        written += chunk.len() as u64;
    }
    anyhow::ensure!(written > 0, "Downloaded file is empty");
    file.flush().await?;
    file.sync_all().await?;
    Ok(())
}

async fn validate_pbf_file(path: &Path) -> anyhow::Result<()> {
    anyhow::ensure!(
        path.exists(),
        "Downloaded extract is missing: {}",
        path.display()
    );
    let size = tokio::fs::metadata(path).await?.len();
    anyhow::ensure!(
        size >= PBF_MIN_BYTES,
        "Downloaded extract looks invalid (too small): {}",
        path.display()
    );
    Ok(())
}

async fn is_stale(path: &Path, ttl: Duration) -> bool {
    let Ok(meta) = tokio::fs::metadata(path).await else {
        return true;
    };
    meta.modified().map_or(true, |modified| {
        modified.elapsed().map_or(true, |age| age > ttl)
    })
}

fn depth_for(
    region_id: &str,
    parents: &HashMap<String, Option<String>>,
    memo: &mut HashMap<String, usize>,
) -> usize {
    if let Some(depth) = memo.get(region_id) {
        return *depth;
    }
    // Walk up the parent chain iteratively, with a cycle guard (the Python
    // original recursed without one).
    let mut depth = 0_usize;
    let mut seen = HashSet::new();
    seen.insert(region_id.to_string());
    let mut current = parents.get(region_id).cloned().flatten();
    while let Some(parent) = current {
        if !parents.contains_key(&parent) {
            break;
        }
        if !seen.insert(parent.clone()) {
            depth = 0; // parent cycle: chain is untrustworthy
            break;
        }
        depth += 1;
        current = parents.get(&parent).cloned().flatten();
    }
    memo.insert(region_id.to_string(), depth);
    depth
}

#[cfg(test)]
mod tests {
    use super::*;

    fn box_geom(min_lon: f64, min_lat: f64, max_lon: f64, max_lat: f64) -> Geom {
        MultiPolygon::new(vec![rect_polygon(Bounds {
            min_lat,
            min_lon,
            max_lat,
            max_lon,
        })])
    }

    fn region(id: &str, parent: Option<&str>, depth: usize, b: Bounds) -> GeofabrikRegion {
        GeofabrikRegion {
            id: id.to_string(),
            name: id.to_string(),
            parent: parent.map(str::to_string),
            pbf_url: format!("https://example.org/{id}.osm.pbf"),
            geometry: box_geom(b.min_lon, b.min_lat, b.max_lon, b.max_lat),
            depth,
            area: 0.0, // recomputed below
        }
    }

    fn region_with_area(
        id: &str,
        parent: Option<&str>,
        depth: usize,
        b: Bounds,
    ) -> GeofabrikRegion {
        let mut r = region(id, parent, depth, b);
        r.area = area_of(&r.geometry);
        r
    }

    fn req(min_lon: f64, min_lat: f64, max_lon: f64, max_lat: f64) -> Geom {
        box_geom(min_lon, min_lat, max_lon, max_lat)
    }

    #[test]
    fn single_country_selection_prefers_deepest() {
        let regions = vec![
            region_with_area(
                "europe",
                None,
                0,
                Bounds {
                    min_lat: 35.0,
                    min_lon: -10.0,
                    max_lat: 71.0,
                    max_lon: 40.0,
                },
            ),
            region_with_area(
                "europe/poland",
                Some("europe"),
                1,
                Bounds {
                    min_lat: 49.0,
                    min_lon: 14.0,
                    max_lat: 55.0,
                    max_lon: 24.2,
                },
            ),
        ];
        let required = req(16.0, 51.0, 17.0, 52.0);
        let single = choose_single_cover(&regions, &required).expect("single cover");
        assert_eq!(single.id, "europe/poland");
    }

    #[test]
    fn boundary_case_falls_back_to_parent_single_extract() {
        // Required box pokes past bayern's east edge: children don't cover.
        let regions = vec![
            region_with_area(
                "europe/germany",
                Some("europe"),
                1,
                Bounds {
                    min_lat: 47.2,
                    min_lon: 5.8,
                    max_lat: 55.1,
                    max_lon: 15.1,
                },
            ),
            region_with_area(
                "europe/bayern",
                Some("europe/germany"),
                2,
                Bounds {
                    min_lat: 47.2,
                    min_lon: 8.9,
                    max_lat: 50.7,
                    max_lon: 13.9,
                },
            ),
            region_with_area(
                "europe/sachsen",
                Some("europe/germany"),
                2,
                Bounds {
                    min_lat: 50.1,
                    min_lon: 11.8,
                    max_lat: 51.7,
                    max_lon: 15.1,
                },
            ),
        ];
        let required = req(13.5, 49.5, 14.5, 50.5);
        let single = choose_single_cover(&regions, &required).expect("single cover");
        assert_eq!(single.id, "europe/germany");
    }

    #[test]
    fn cross_country_prefers_multi_over_huge_single() {
        let regions = vec![
            region_with_area(
                "europe",
                None,
                0,
                Bounds {
                    min_lat: 35.0,
                    min_lon: -10.0,
                    max_lat: 71.0,
                    max_lon: 40.0,
                },
            ),
            region_with_area(
                "europe/germany",
                Some("europe"),
                1,
                Bounds {
                    min_lat: 47.2,
                    min_lon: 5.8,
                    max_lat: 55.1,
                    max_lon: 14.5,
                },
            ),
            region_with_area(
                "europe/poland",
                Some("europe"),
                1,
                Bounds {
                    min_lat: 49.0,
                    min_lon: 14.5,
                    max_lat: 55.0,
                    max_lon: 24.2,
                },
            ),
        ];
        let required = req(14.0, 50.5, 15.0, 51.5);
        let single = choose_single_cover(&regions, &required);
        assert_eq!(single.as_ref().expect("europe covers").id, "europe");
        let multi = choose_multi_cover(&regions, &required).expect("multi cover");
        assert_eq!(
            multi.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            vec!["europe/germany", "europe/poland"]
        );
        let chosen = pick_best_strategy(single, multi).expect("strategy");
        assert_eq!(
            chosen.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            vec!["europe/germany", "europe/poland"]
        );
    }

    #[test]
    fn single_region_multi_does_not_beat_single() {
        let regions = vec![
            region_with_area(
                "a",
                None,
                0,
                Bounds {
                    min_lat: 40.0,
                    min_lon: 10.0,
                    max_lat: 50.0,
                    max_lon: 20.0,
                },
            ),
            region_with_area(
                "b",
                None,
                0,
                Bounds {
                    min_lat: 44.0,
                    min_lon: 15.0,
                    max_lat: 54.0,
                    max_lon: 25.0,
                },
            ),
        ];
        let required = req(18.5, 45.5, 19.5, 49.5);
        let single = choose_single_cover(&regions, &required);
        let multi = choose_multi_cover(&regions, &required).expect("multi cover");
        let chosen = pick_best_strategy(single, multi).expect("strategy");
        assert_eq!(chosen.len(), 1);
        assert_eq!(chosen[0].id, "a");
    }

    #[test]
    fn pruning_removes_parent_child_duplication() {
        let germany = region_with_area(
            "germany",
            None,
            0,
            Bounds {
                min_lat: 47.2,
                min_lon: 5.8,
                max_lat: 55.1,
                max_lon: 15.1,
            },
        );
        let bayern = region_with_area(
            "bayern",
            Some("germany"),
            1,
            Bounds {
                min_lat: 47.2,
                min_lon: 8.9,
                max_lat: 50.7,
                max_lon: 13.9,
            },
        );
        let required = req(9.5, 48.0, 12.5, 50.0);
        let pruned = prune_redundant(vec![germany, bayern], &required);
        assert_eq!(pruned.len(), 1);
        assert_eq!(pruned[0].id, "bayern");
    }

    #[test]
    fn no_cover_at_all_is_an_error() {
        let regions: Vec<GeofabrikRegion> = vec![];
        let required = req(0.0, 0.0, 1.0, 1.0);
        let single = choose_single_cover(&regions, &required);
        let multi = choose_multi_cover(&regions, &required).expect("no candidates");
        assert!(single.is_none());
        assert!(multi.is_empty());
        assert!(pick_best_strategy(single, multi).is_err());
    }

    #[test]
    fn index_parsing_extracts_regions_and_depth() {
        let index = r#"{
            "features": [
                {"properties": {"id": "europe", "name": "Europe", "urls": {"pbf": "https://x/europe.osm.pbf"}},
                 "geometry": {"type": "Polygon", "coordinates": [[[-10,35],[40,35],[40,71],[-10,71],[-10,35]]]}},
                {"properties": {"id": "europe/poland", "parent": "europe", "urls": {"pbf": "https://x/poland.osm.pbf"}},
                 "geometry": {"type": "Polygon", "coordinates": [[[14,49],[24,49],[24,55],[14,55],[14,49]]]}},
                {"properties": {"id": "no-pbf"}},
                {"properties": {"id": "bad-geom", "urls": {"pbf": "https://x/bad.osm.pbf"}}, "geometry": {"type": "Point", "coordinates": [1,2]}}
            ]
        }"#;
        let doc: IndexDoc = serde_json::from_str(index).expect("index doc");
        let features = doc.features.as_array().expect("features");
        let mut parsed: Vec<(String, String, Option<String>, String, Geom)> = Vec::new();
        for feature in features {
            let feature: Feature = serde_json::from_value(feature.clone()).expect("feature");
            let Some(props) = feature.properties else {
                continue;
            };
            let Some(region_id) = props.id else { continue };
            let Some(pbf_url) = props.urls.and_then(|u| u.pbf) else {
                continue;
            };
            let Some(geometry) = feature.geometry.as_ref().and_then(geometry_from_geojson) else {
                continue;
            };
            parsed.push((
                region_id,
                props.name.unwrap_or_else(|| "id".to_string()),
                props.parent,
                pbf_url,
                geometry,
            ));
        }
        let parents: HashMap<String, Option<String>> = parsed
            .iter()
            .map(|(id, _, parent, _, _)| (id.clone(), parent.clone()))
            .collect();
        let mut memo = HashMap::new();
        let poland_depth = depth_for("europe/poland", &parents, &mut memo);
        let europe_depth = depth_for("europe", &parents, &mut memo);
        assert_eq!(europe_depth, 0);
        assert_eq!(poland_depth, 1);
        // no-pbf and bad-geom features were skipped
        assert_eq!(parsed.len(), 2);
    }

    #[test]
    fn required_osm_geometry_builds_nonempty_union() {
        let points = vec![(52.20, 20.90), (52.25, 21.00)];
        let area = required_osm_geometry(&points, 1.0, 0.002).expect("geometry");
        assert!(!area.tiles.is_empty());
        assert!(area_of(&area.geometry) > 0.0);
    }

    #[test]
    fn depth_handles_cycles_without_hanging() {
        let mut parents = HashMap::new();
        parents.insert("a".to_string(), Some("b".to_string()));
        parents.insert("b".to_string(), Some("a".to_string()));
        let mut memo = HashMap::new();
        let depth = depth_for("a", &parents, &mut memo);
        assert_eq!(depth, 0);
    }
}
