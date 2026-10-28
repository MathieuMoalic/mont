//! GPX route → `ZeppOS` watch route file (`.dat`) encoder.
//!
//! Byte-exact port of Gadgetbridge's `ZeppOsGpxRouteFile`: parses track
//! points (with optional elevation), waypoints and bounds from a GPX, and
//! encodes the compact binary format the watch's workout/route list consumes
//! (coordinates scaled ×3000000, 14-byte track points, 68-byte waypoints).
//!
//! The `float`/`int` arithmetic intentionally mirrors the Java original op for
//! op (truncating/wrapping casts, no `mul_add`), so the produced bytes are
//! identical.
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_possible_wrap
)]

use anyhow::Context as _;

const COORD_MULTIPLIER: f64 = 3_000_000.0;
/// Track/waypoint names are truncated to 47 bytes in a 48-byte field.
const NAME_FIELD_LEN: usize = 48;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RoutePoint {
    pub lat: f64,
    pub lon: f64,
    /// Meters; missing elevation is 0 (Gadgetbridge's default).
    pub ele: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Waypoint {
    pub lat: f64,
    pub lon: f64,
    pub ele: f64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GpxRoute {
    pub points: Vec<RoutePoint>,
    pub waypoints: Vec<Waypoint>,
}

fn route_points(doc: &roxmltree::Document) -> anyhow::Result<Vec<RoutePoint>> {
    let mut points = Vec::new();
    for node in doc.descendants() {
        let name = node.tag_name().name();
        if !matches!(name, "trkpt" | "rtept") {
            continue;
        }
        points.push(point_from_node(node)?);
    }
    Ok(points)
}

fn waypoints(doc: &roxmltree::Document) -> Vec<Waypoint> {
    let mut out = Vec::new();
    for node in doc.descendants() {
        if node.tag_name().name() != "wpt" {
            continue;
        }
        let (Some(lat_attr), Some(lon_attr)) = (node.attribute("lat"), node.attribute("lon"))
        else {
            continue;
        };
        let (Ok(lat), Ok(lon)) = (lat_attr.parse::<f64>(), lon_attr.parse::<f64>()) else {
            continue;
        };
        let ele = node
            .children()
            .find(|n| n.tag_name().name() == "ele")
            .and_then(|n| n.text())
            .and_then(|t| t.parse::<f64>().ok())
            .unwrap_or(0.0);
        let name = node
            .children()
            .find(|n| n.tag_name().name() == "name")
            .and_then(|n| n.text())
            .unwrap_or("")
            .to_string();
        out.push(Waypoint {
            lat,
            lon,
            ele,
            name,
        });
    }
    out
}

fn point_from_node(node: roxmltree::Node) -> anyhow::Result<RoutePoint> {
    let lat = node
        .attribute("lat")
        .context("point is missing a lat attribute")?
        .parse::<f64>()
        .map_err(|e| anyhow::anyhow!("Invalid lat: {e}"))?;
    let lon = node
        .attribute("lon")
        .context("point is missing a lon attribute")?
        .parse::<f64>()
        .map_err(|e| anyhow::anyhow!("Invalid lon: {e}"))?;
    let ele = node
        .children()
        .find(|n| n.tag_name().name() == "ele")
        .and_then(|n| n.text())
        .and_then(|t| t.parse::<f64>().ok())
        .unwrap_or(0.0);
    Ok(RoutePoint { lat, lon, ele })
}

/// Parses a GPX file into route points + waypoints.
///
/// # Errors
/// Invalid XML/UTF-8 or a malformed track point.
pub fn parse_gpx_route(data: &[u8]) -> anyhow::Result<GpxRoute> {
    let text = std::str::from_utf8(data).map_err(|_| anyhow::anyhow!("GPX is not valid UTF-8"))?;
    let doc = roxmltree::Document::parse(text)
        .map_err(|e| anyhow::anyhow!("Invalid GPX XML: {e}"))
        .context("Parsing GPX")?;
    let points = route_points(&doc)?;
    anyhow::ensure!(!points.is_empty(), "GPX has no route/track points");
    let waypoints = waypoints(&doc);
    Ok(GpxRoute { points, waypoints })
}

/// Great-circle distance in meters (haversine). Gadgetbridge uses Android's
/// `Location.distanceTo`; the tiny differences are display-only on the watch.
/// Great-circle distance in meters (haversine). Gadgetbridge uses Android.s
/// `Location.distanceTo`; the tiny differences are display-only on the watch.
/// The float math mirrors that computation, hence the lint allows.
#[allow(clippy::suboptimal_flops)]
fn distance_between(a: &RoutePoint, b: &RoutePoint) -> f64 {
    const EARTH_RADIUS_M: f64 = 6_371_000.0;
    let (lat1, lon1) = (a.lat.to_radians(), a.lon.to_radians());
    let (lat2, lon2) = (b.lat.to_radians(), b.lon.to_radians());
    let dlat = lat2 - lat1;
    let dlon = lon2 - lon1;
    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_M * h.sqrt().asin()
}

fn u32le(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn truncate_pad_string(s: &str) -> [u8; NAME_FIELD_LEN] {
    let mut out = [0u8; NAME_FIELD_LEN];
    let bytes = s.as_bytes();
    let len = bytes.len().min(NAME_FIELD_LEN - 1);
    out[..len].copy_from_slice(&bytes[..len]);
    out
}

/// Encodes the route into the watch's binary `.dat` format.
///
/// `timestamp` is unix seconds (Gadgetbridge stamps encode time); `name` is
/// truncated to 47 bytes.
#[must_use]
pub fn encode_route_dat(route: &GpxRoute, timestamp: i64, name: &str) -> Vec<u8> {
    let (mut min_lat, mut max_lat) = (180.0_f64, -180.0_f64);
    let (mut min_lon, mut max_lon) = (180.0_f64, -180.0_f64);
    let (mut min_ele, mut max_ele) = (10_000.0_f64, -10_000.0_f64);
    for p in &route.points {
        min_lat = min_lat.min(p.lat);
        max_lat = max_lat.max(p.lat);
        min_lon = min_lon.min(p.lon);
        max_lon = max_lon.max(p.lon);
        min_ele = min_ele.min(p.ele);
        max_ele = max_ele.max(p.ele);
    }

    let mut out = Vec::new();

    u32le(&mut out, 0); // ?
    u32le(&mut out, 0x54); // ?
    u32le(&mut out, 0x01); // ?
    u32le(&mut out, timestamp as i32);
    u32le(&mut out, (min_lat * COORD_MULTIPLIER) as i32);
    u32le(&mut out, (max_lat * COORD_MULTIPLIER) as i32);
    u32le(&mut out, (min_lon * COORD_MULTIPLIER) as i32);
    u32le(&mut out, (max_lon * COORD_MULTIPLIER) as i32);
    u32le(&mut out, min_ele as i32);
    u32le(&mut out, max_ele as i32);
    out.extend_from_slice(&truncate_pad_string(name));
    u32le(&mut out, 0); // ?

    if !route.waypoints.is_empty() {
        u32le(&mut out, 2);
        u32le(&mut out, (route.waypoints.len() * 68) as i32);
        for w in &route.waypoints {
            u32le(&mut out, 0x1a); // ?
            u32le(&mut out, (w.lat * COORD_MULTIPLIER) as i32);
            u32le(&mut out, (w.lon * COORD_MULTIPLIER) as i32);
            u32le(&mut out, w.ele as i32);
            out.extend_from_slice(&truncate_pad_string(&w.name));
            u32le(&mut out, 0); // ?
        }
    }

    u32le(&mut out, 1);
    u32le(&mut out, (route.points.len() * 14) as i32);

    let mut total_dist = 0.0_f64;
    let mut prev: Option<RoutePoint> = None;
    for point in &route.points {
        if let Some(prev) = &prev {
            total_dist += distance_between(prev, point);
        }
        prev = Some(*point);
        u32le(&mut out, total_dist as i32);
        u32le(&mut out, (point.lat * COORD_MULTIPLIER) as i32);
        u32le(&mut out, (point.lon * COORD_MULTIPLIER) as i32);
        // Java `(int)` truncates; the u16 wrap mirrors fromUint16.
        out.extend_from_slice(&(point.ele as i32 as u16).to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test">
  <wpt lat="52.5" lon="16.75"><name>Start</name><ele>70</ele></wpt>
  <trk><name>Walk</name><trkseg>
    <trkpt lat="52.5" lon="16.75"><ele>70.5</ele></trkpt>
    <trkpt lat="52.625" lon="16.875"><ele>72</ele></trkpt>
    <trkpt lat="52.75" lon="17"><ele>75</ele></trkpt>
  </trkseg></trk>
</gpx>"#;

    #[test]
    fn parses_points_waypoints_and_bounds() {
        let route = parse_gpx_route(SAMPLE).expect("route");
        assert_eq!(route.points.len(), 3);
        assert_eq!(route.waypoints.len(), 1);
        assert_eq!(route.waypoints[0].name, "Start");
        assert!((route.points[0].ele - 70.5).abs() < 1e-9);
    }

    #[test]
    fn dat_layout_matches_gadgetbridge() {
        let route = parse_gpx_route(SAMPLE).expect("route");
        let dat = encode_route_dat(&route, 1_700_000_000, "My route");

        // Header: 0, 0x54, 1, timestamp, then scaled bounds (i32 LE).
        // Coordinates are dyadic so the f64 math is exact.
        assert_eq!(&dat[0..4], &0u32.to_le_bytes());
        assert_eq!(&dat[4..8], &0x54u32.to_le_bytes());
        assert_eq!(&dat[8..12], &1u32.to_le_bytes());
        assert_eq!(&dat[12..16], &1_700_000_000i32.to_le_bytes());
        // min lat 52.5 * 3000000 = 157500000
        assert_eq!(&dat[16..20], &157_500_000i32.to_le_bytes());
        // max lat 52.75 * 3000000 = 158250000
        assert_eq!(&dat[20..24], &158_250_000i32.to_le_bytes());
        // min lon 16.75 * 3000000 = 50250000
        assert_eq!(&dat[24..28], &50_250_000i32.to_le_bytes());
        // max lon 17 * 3000000 = 51000000
        assert_eq!(&dat[28..32], &51_000_000i32.to_le_bytes());

        // min ele 70.5 → 70, max ele 75
        assert_eq!(&dat[32..36], &70i32.to_le_bytes());
        assert_eq!(&dat[36..40], &75i32.to_le_bytes());

        // 48-byte name field: "My route" then nulls.
        assert_eq!(&dat[40..48], b"My route");
        assert!(dat[48..80].iter().all(|&b| b == 0));
        assert_eq!(&dat[80..84], &0u32.to_le_bytes()); // trailing ?

        // SAMPLE has a waypoint → waypoint section first (tag 2, 1*68 bytes).
        assert_eq!(&dat[92..96], &2u32.to_le_bytes());
        assert_eq!(&dat[96..100], &68i32.to_le_bytes());
        assert_eq!(&dat[100..104], &0x1au32.to_le_bytes());
        // Then the points section (tag 1, 3*14 bytes).
        let track_off = 92 + 8 + 68;
        assert_eq!(&dat[track_off..track_off + 4], &1u32.to_le_bytes());
        assert_eq!(&dat[track_off + 4..track_off + 8], &42i32.to_le_bytes());

        // First point: dist 0, then scaled coords, altitude u16.
        let p0_off = track_off + 8;
        let p0 = &dat[p0_off..p0_off + 14];
        assert_eq!(&p0[0..4], &0i32.to_le_bytes());
        assert_eq!(&p0[4..8], &((52.5 * COORD_MULTIPLIER) as i32).to_le_bytes());
        assert_eq!(&p0[12..14], &70u16.to_le_bytes());

        // Total size: header (40 + 48 + 4) + waypoint (8 + 68) + track (8 + 3*14).
        assert_eq!(dat.len(), 40 + 48 + 4 + 8 + 68 + 8 + 3 * 14);
    }

    #[test]
    fn waypoint_section_is_emitted_when_present() {
        let route = GpxRoute {
            points: vec![RoutePoint {
                lat: 10.0,
                lon: 20.0,
                ele: 5.0,
            }],
            waypoints: vec![Waypoint {
                lat: 11.0,
                lon: 21.0,
                ele: 6.0,
                name: "WP".to_string(),
            }],
        };
        let dat = encode_route_dat(&route, 42, "t");
        // After the header (40 + 48 + 4): waypoint tag 2, size 1*68.
        assert_eq!(&dat[92..96], &2u32.to_le_bytes());
        assert_eq!(&dat[96..100], &68i32.to_le_bytes());
        // First waypoint word: 0x1a.
        assert_eq!(&dat[100..104], &0x1au32.to_le_bytes());
        // Then the track section: tag 1, 1*14.
        assert_eq!(&dat[100 + 68..104 + 68], &1u32.to_le_bytes());
    }

    #[test]
    fn missing_elevation_defaults_to_zero() {
        let xml = br#"<gpx version="1.1"><trk><trkseg>
            <trkpt lat="1.0" lon="2.0"/>
        </trkseg></trk></gpx>"#;
        let route = parse_gpx_route(xml).expect("route");
        assert_eq!(route.points[0].ele, 0.0);
        let dat = encode_route_dat(&route, 1, "n");
        // Point record: dist u32 | lat u32 | lon u32 | alt u16.
        // Layout: 40 header + 48 name + 4 trailer + 4 tag + 4 count = 100.
        let alt_off = 100 + 12;
        assert_eq!(&dat[alt_off..alt_off + 2], &0u16.to_le_bytes());
    }

    #[test]
    fn rejects_gpx_without_points() {
        let xml = br#"<gpx version="1.1"/>"#;
        assert!(parse_gpx_route(xml).is_err());
    }
}
