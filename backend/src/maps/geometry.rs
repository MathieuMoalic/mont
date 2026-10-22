//! Slippy-tile math and route bounds, ported from gpx2img's `core.py`.
//!
//! The formulas reproduce the Python implementation exactly (including
//! clamping and the antimeridian handling) so both tools produce identical
//! tile sets for the same GPX.

// The arithmetic below mirrors the Python original operation-for-operation on
// purpose: fusing multiply-adds or rewriting (a+b)/2 as `midpoint` would
// change results in the last bits, and tile selection floors those values.
#![allow(clippy::suboptimal_flops, clippy::manual_midpoint)]

use anyhow::{Context, bail};

/// The only zoom level Zepp OS watches render for these maps.
pub const ZOOM: u32 = 11;

/// Web-Mercator latitude limits.
pub const MIN_LAT: f64 = -85.051_128_78;
pub const MAX_LAT: f64 = 85.051_128_78;

/// Kilometres per degree of latitude (gpx2img constant).
const KM_PER_DEG_LAT: f64 = 110.574;
/// Kilometres per degree of longitude at the equator (gpx2img constant).
const KM_PER_DEG_LON_EQUATOR: f64 = 111.320;

/// A lon/lat bounding box. `min_lon > max_lon` is meaningful: it encodes an
/// interval wrapping around the antimeridian.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub min_lat: f64,
    pub min_lon: f64,
    pub max_lat: f64,
    pub max_lon: f64,
}

#[must_use]
pub fn normalize_lon(lon: f64) -> f64 {
    (lon + 180.0).rem_euclid(360.0) - 180.0
}

/// Extract every route point (`trkpt`, `rtept`, `wpt`) as `(lat, lon)`.
///
/// # Errors
/// The document is not valid XML/UTF-8, or a point is missing or has
/// malformed coordinates.
pub fn gpx_points(data: &[u8]) -> anyhow::Result<Vec<(f64, f64)>> {
    let text = std::str::from_utf8(data).map_err(|_| anyhow::anyhow!("GPX is not valid UTF-8"))?;
    let doc = roxmltree::Document::parse(text)
        .map_err(|e| anyhow::anyhow!("Invalid GPX XML: {e}"))
        .context("Parsing GPX")?;
    let mut points = Vec::new();
    for node in doc.descendants() {
        let name = node.tag_name().name();
        if !matches!(name, "trkpt" | "rtept" | "wpt") {
            continue;
        }
        let lat = node
            .attribute("lat")
            .context("GPX point is missing a lat attribute")?
            .parse::<f64>()
            .map_err(|e| anyhow::anyhow!("Invalid GPX lat: {e}"))?;
        let lon = node
            .attribute("lon")
            .context("GPX point is missing a lon attribute")?
            .parse::<f64>()
            .map_err(|e| anyhow::anyhow!("Invalid GPX lon: {e}"))?;
        points.push((lat, lon));
    }
    Ok(points)
}

/// Smallest lon interval containing all points, in `(min, max)` form.
///
/// Routes crossing the antimeridian yield an *inverted* interval
/// (`min > max`); a set of points spread around the whole globe yields the
/// full `(-180, 180)` range.
///
/// # Errors
/// `lons` is empty.
pub fn smallest_lon_interval(lons: &[f64]) -> anyhow::Result<(f64, f64)> {
    let Some(&first) = lons.first() else {
        bail!("No longitudes provided");
    };
    if lons.len() == 1 {
        let lon = normalize_lon(first);
        return Ok((lon, lon));
    }

    let mut values: Vec<f64> = lons
        .iter()
        .map(|lon| (lon + 360.0).rem_euclid(360.0))
        .collect();
    values.sort_by(f64::total_cmp);
    let mut max_gap = -1.0f64;
    let mut gap_start = values[0];
    let mut gap_end = values[0];
    for (i, &current) in values.iter().enumerate() {
        let mut next = values[(i + 1) % values.len()];
        if i == values.len() - 1 {
            next += 360.0;
        }
        let gap = next - current;
        if gap > max_gap {
            max_gap = gap;
            gap_start = current;
            gap_end = next;
        }
    }

    let span_start = gap_end;
    let span_end = gap_start + 360.0;
    if span_end - span_start >= 359.999_999 {
        return Ok((-180.0, 180.0));
    }
    Ok((normalize_lon(span_start), normalize_lon(span_end)))
}

#[must_use]
pub fn lon_span(bounds: Bounds) -> f64 {
    if bounds.min_lon <= bounds.max_lon {
        bounds.max_lon - bounds.min_lon
    } else {
        (180.0 - bounds.min_lon) + (bounds.max_lon + 180.0)
    }
}

#[must_use]
pub fn lon_center(bounds: Bounds) -> f64 {
    normalize_lon(bounds.min_lon + lon_span(bounds) / 2.0)
}

#[must_use]
pub fn interval_from_center(center: f64, span: f64) -> (f64, f64) {
    if span >= 359.999_999 {
        return (-180.0, 180.0);
    }
    (
        normalize_lon(center - span / 2.0),
        normalize_lon(center + span / 2.0),
    )
}

/// # Errors
/// The point list is empty.
pub fn parse_gpx_bounds(points: &[(f64, f64)]) -> anyhow::Result<Bounds> {
    anyhow::ensure!(!points.is_empty(), "GPX has no route/track points");
    let (mut min_lat, mut max_lat) = (f64::MAX, f64::MIN);
    let mut lons = Vec::with_capacity(points.len());
    for &(lat, lon) in points {
        min_lat = min_lat.min(lat);
        max_lat = max_lat.max(lat);
        lons.push(lon);
    }
    let (min_lon, max_lon) = smallest_lon_interval(&lons)?;
    Ok(Bounds {
        min_lat,
        min_lon,
        max_lat,
        max_lon,
    })
}

/// # Errors
/// `buffer_km` is negative.
pub fn expand_bounds(bounds: Bounds, buffer_km: f64) -> anyhow::Result<Bounds> {
    anyhow::ensure!(buffer_km >= 0.0, "buffer_km must be >= 0");
    let lat_pad = buffer_km / KM_PER_DEG_LAT;
    let mid_lat = (bounds.min_lat + bounds.max_lat) / 2.0;
    let cos_lat = mid_lat.to_radians().cos().abs().max(1e-6);
    let lon_pad = buffer_km / (KM_PER_DEG_LON_EQUATOR * cos_lat);
    let span = (lon_span(bounds) + 2.0 * lon_pad).min(360.0);
    let (min_lon, max_lon) = interval_from_center(lon_center(bounds), span);
    Ok(Bounds {
        min_lat: (bounds.min_lat - lat_pad).max(MIN_LAT),
        min_lon,
        max_lat: (bounds.max_lat + lat_pad).min(MAX_LAT),
        max_lon,
    })
}

#[allow(
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss
)]
fn floor_clamp_to_u32(value: f64, limit: u32) -> u32 {
    // `value` is floored then clamped into [0, limit] here, so the cast is in
    // range. (u32 also fits f64 exactly, hence the precision-loss allow.)
    value.floor().clamp(0.0, f64::from(limit)) as u32
}

#[must_use]
pub fn latlon_to_tile(lat: f64, lon: f64, zoom: u32) -> (u32, u32) {
    let lat = lat.clamp(MIN_LAT, MAX_LAT);
    let lon = normalize_lon(lon);
    let n = 2_u32.pow(zoom);
    let x = (lon + 180.0) / 360.0 * f64::from(n);
    let lat_rad = lat.to_radians();
    let y = (1.0 - lat_rad.tan().asinh() / std::f64::consts::PI) / 2.0 * f64::from(n);
    (floor_clamp_to_u32(x, n - 1), floor_clamp_to_u32(y, n - 1))
}

#[must_use]
pub fn tile_bounds(x: u32, y: u32, zoom: u32) -> Bounds {
    let n = f64::from(2_u32.pow(zoom));
    let min_lon = f64::from(x) / n * 360.0 - 180.0;
    let max_lon = f64::from(x + 1) / n * 360.0 - 180.0;
    let max_lat = (std::f64::consts::PI * (1.0 - 2.0 * f64::from(y) / n))
        .sinh()
        .atan()
        .to_degrees();
    let min_lat = (std::f64::consts::PI * (1.0 - 2.0 * f64::from(y + 1) / n))
        .sinh()
        .atan()
        .to_degrees();
    Bounds {
        min_lat,
        min_lon,
        max_lat,
        max_lon,
    }
}

/// Convert a kilometre padding into `(lat_deg, lon_deg)` at `latitude`.
///
/// # Errors
/// `buffer_km` is negative.
pub fn buffer_km_to_degrees(buffer_km: f64, latitude: f64) -> anyhow::Result<(f64, f64)> {
    anyhow::ensure!(buffer_km >= 0.0, "buffer_km must be >= 0");
    let lat_deg = buffer_km / KM_PER_DEG_LAT;
    let cos_lat = latitude.to_radians().cos().abs().max(1e-6);
    let lon_deg = buffer_km / (KM_PER_DEG_LON_EQUATOR * cos_lat);
    Ok((lat_deg, lon_deg))
}

/// Tile box padded for osmium extraction: per axis the padding is
/// `max(overlap_degrees, buffer padding at the tile's mid latitude)`. Unlike
/// [`expand_bounds`] this clamps at ±180 instead of wrapping.
///
/// A negative `buffer_km` simply never wins the `max` against a
/// non-negative overlap; callers validate it separately.
#[must_use]
#[allow(clippy::neg_cmp_op_on_partial_ord)]
pub fn tile_extract_bounds(
    x: u32,
    y: u32,
    overlap_degrees: f64,
    zoom: u32,
    buffer_km: f64,
) -> Bounds {
    let tb = tile_bounds(x, y, zoom);
    let mid_lat = (tb.min_lat + tb.max_lat) / 2.0;
    let buf_lat = buffer_km / KM_PER_DEG_LAT;
    let cos_lat = mid_lat.to_radians().cos().abs().max(1e-6);
    let buf_lon = buffer_km / (KM_PER_DEG_LON_EQUATOR * cos_lat);
    let pad_lat = if overlap_degrees > buf_lat {
        overlap_degrees
    } else {
        buf_lat
    };
    let pad_lon = if overlap_degrees > buf_lon {
        overlap_degrees
    } else {
        buf_lon
    };
    Bounds {
        min_lat: (tb.min_lat - pad_lat).max(MIN_LAT),
        min_lon: (tb.min_lon - pad_lon).max(-180.0),
        max_lat: (tb.max_lat + pad_lat).min(MAX_LAT),
        max_lon: (tb.max_lon + pad_lon).min(180.0),
    }
}

/// All zoom-`zoom` tiles covering `bounds`, sorted x-major then y.
///
/// Supports inverted (antimeridian-wrapping) lon intervals.
#[must_use]
pub fn tiles_for_bounds(bounds: Bounds, zoom: u32) -> Vec<(u32, u32)> {
    let n = 2_u32.pow(zoom);
    let (_, y_max) = latlon_to_tile(bounds.min_lat, 0.0, zoom);
    let (_, y_min) = latlon_to_tile(bounds.max_lat, 0.0, zoom);
    let (ys_lo, ys_hi) = (y_min.min(y_max), y_min.max(y_max));

    let (x_min, _) = latlon_to_tile(0.0, bounds.min_lon, zoom);
    let (x_max, _) = latlon_to_tile(0.0, bounds.max_lon, zoom);
    let xs: Vec<u32> = if bounds.min_lon <= bounds.max_lon {
        (x_min.min(x_max)..=x_min.max(x_max)).collect()
    } else {
        (x_min..n).chain(0..=x_max).collect()
    };

    let mut tiles = Vec::new();
    for x in xs {
        for y in ys_lo..=ys_hi {
            tiles.push((x, y));
        }
    }
    tiles.sort_unstable();
    tiles
}

/// Union of the padded extract boxes of every tile covering the buffered
/// route. Returns the sorted tile list and the required OSM bounds.
///
/// # Errors
/// The GPX has no points, `buffer_km` is negative, or no tiles were computed.
pub fn required_tiles_and_bounds(
    points: &[(f64, f64)],
    buffer_km: f64,
    overlap_degrees: f64,
) -> anyhow::Result<(Vec<(u32, u32)>, Bounds)> {
    let route = parse_gpx_bounds(points)?;
    let buffered = expand_bounds(route, buffer_km)?;
    let tiles = tiles_for_bounds(buffered, ZOOM);
    anyhow::ensure!(!tiles.is_empty(), "No zoom-11 tiles computed from GPX");

    let mut extracts = tiles
        .iter()
        .map(|&(x, y)| tile_extract_bounds(x, y, overlap_degrees, ZOOM, buffer_km));
    let Some(first) = extracts.next() else {
        anyhow::bail!("No zoom-11 tiles computed from GPX");
    };
    let required = extracts.fold(first, |acc, b| Bounds {
        min_lat: acc.min_lat.min(b.min_lat),
        min_lon: acc.min_lon.min(b.min_lon),
        max_lat: acc.max_lat.max(b.max_lat),
        max_lon: acc.max_lon.max(b.max_lon),
    });
    Ok((tiles, required))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_gpx(points: &[(f64, f64)]) -> Vec<u8> {
        let mut xml = String::from(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test"><trk><trkseg>"#,
        );
        for (lat, lon) in points {
            xml.push_str(&format!(r#"<trkpt lat="{lat}" lon="{lon}"/>"#));
        }
        xml.push_str("</trkseg></trk></gpx>");
        xml.into_bytes()
    }

    #[test]
    fn known_tile_coordinate() {
        assert_eq!(latlon_to_tile(49.629_944, 19.757_944, ZOOM), (1136, 697));
    }

    #[test]
    fn tiles_for_babia_bounds() {
        let bounds = Bounds {
            min_lat: 49.55,
            min_lon: 19.45,
            max_lat: 49.65,
            max_lon: 19.80,
        };
        let tiles = tiles_for_bounds(bounds, ZOOM);
        assert!(tiles.contains(&(1134, 698)));
        assert!(tiles.contains(&(1135, 698)));
    }

    #[test]
    fn expand_bounds_increases_area() {
        let base = Bounds {
            min_lat: 49.6,
            min_lon: 19.7,
            max_lat: 49.61,
            max_lon: 19.71,
        };
        let grown = expand_bounds(base, 1.0).expect("expand");
        assert!(grown.min_lat < base.min_lat);
        assert!(grown.max_lat > base.max_lat);
        assert!(lon_span(grown) > lon_span(base));
    }

    #[test]
    fn tile_extract_bounds_padded_by_buffer() {
        let base = tile_bounds(1120, 672, ZOOM);
        let padded = tile_extract_bounds(1120, 672, 0.002, ZOOM, 1.0);
        assert!(padded.min_lat < base.min_lat);
        assert!(padded.min_lon < base.min_lon);
        assert!(padded.max_lat > base.max_lat);
        assert!(padded.max_lon > base.max_lon);
        let (buf_lat, _) = buffer_km_to_degrees(1.0, 52.43).expect("degrees");
        // Latitude padding is latitude-independent, so the buffer wins the
        // max against the overlap floor and the shift equals buf_lat exactly.
        assert!((base.min_lat - padded.min_lat - buf_lat).abs() < 1e-6);
    }

    #[test]
    fn tile_extract_bounds_overlap_is_floor() {
        let default_pad = tile_extract_bounds(1120, 672, 0.002, ZOOM, 0.0);
        let big_overlap = tile_extract_bounds(1120, 672, 0.05, ZOOM, 0.0);
        assert!(big_overlap.min_lon < default_pad.min_lon);
        assert!(big_overlap.max_lon > default_pad.max_lon);
    }

    #[test]
    fn buffer_km_to_degrees_matches_expand_bounds() {
        let base = Bounds {
            min_lat: 52.0,
            min_lon: 20.0,
            max_lat: 52.0,
            max_lon: 20.0,
        };
        let expanded = expand_bounds(base, 2.0).expect("expand");
        let (lat_pad, lon_pad) = buffer_km_to_degrees(2.0, 52.0).expect("degrees");
        assert!((base.min_lat - expanded.min_lat - lat_pad).abs() < 1e-9);
        assert!(lon_pad > lat_pad);
        let ratio = lat_pad / lon_pad;
        assert!((ratio - 0.610_069_1).abs() < 0.01, "ratio {ratio}");
    }

    #[test]
    fn antimeridian_gpx_bounds_are_not_worldwide() {
        let points = vec![(10.0, 179.8), (10.1, -179.8)];
        let bytes = write_gpx(&points);
        let parsed = gpx_points(&bytes).expect("gpx points");
        let bounds = parse_gpx_bounds(&parsed).expect("bounds");
        assert!(
            bounds.min_lon > bounds.max_lon,
            "expected inverted interval, got {bounds:?}"
        );
        let tiles = tiles_for_bounds(bounds, ZOOM);
        assert!(
            (1..30).contains(&tiles.len()),
            "expected a handful of tiles, got {}",
            tiles.len()
        );
    }

    #[test]
    fn gpx_points_include_routes_and_waypoints() {
        let xml = br#"<?xml version="1.0"?>
<gpx version="1.1" creator="t">
  <wpt lat="1.5" lon="2.5"/>
  <rte><rtept lat="3.5" lon="4.5"/></rte>
  <trk><trkseg><trkpt lat="5.5" lon="6.5"/></trkseg></trk>
</gpx>"#;
        let points = gpx_points(xml).expect("points");
        assert_eq!(points, vec![(1.5, 2.5), (3.5, 4.5), (5.5, 6.5)]);
    }

    #[test]
    fn required_bounds_cover_all_generated_tile_extracts() {
        let points = vec![(52.20, 20.90), (52.25, 21.00), (52.23, 21.05)];
        for buffer_km in [0.0, 1.0] {
            let (tiles, required) =
                required_tiles_and_bounds(&points, buffer_km, 0.002).expect("required");
            assert!(!tiles.is_empty());
            for &(x, y) in &tiles {
                let b = tile_extract_bounds(x, y, 0.002, ZOOM, buffer_km);
                assert!(b.min_lat >= required.min_lat);
                assert!(b.min_lon >= required.min_lon);
                assert!(b.max_lat <= required.max_lat);
                assert!(b.max_lon <= required.max_lon);
            }
        }
    }

    #[test]
    fn required_bounds_grow_with_buffer() {
        let points = vec![(52.20, 20.90), (52.25, 21.00)];
        let (_, small) = required_tiles_and_bounds(&points, 0.0, 0.002).expect("required");
        let (_, large) = required_tiles_and_bounds(&points, 1.0, 0.002).expect("required");
        assert!(large.min_lat < small.min_lat);
        assert!(large.max_lat > small.max_lat);
        assert!(large.min_lon < small.min_lon);
        assert!(large.max_lon > small.max_lon);
    }

    #[test]
    fn gpx_without_points_is_an_error() {
        let xml = br#"<?xml version="1.0"?><gpx version="1.1"/>"#;
        let points = gpx_points(xml).expect("points");
        assert!(parse_gpx_bounds(&points).is_err());
    }
}
