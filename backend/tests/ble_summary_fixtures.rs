//! Fixture validation: parse every RAW_SUMMARY_DATA blob from the local
//! Gadgetbridge export and compare the decoded fields against Gadgetbridge's
//! own `SUMMARY_DATA` JSON (written by GB from the same protobuf).
//!
//! Skips silently when the export is missing (e.g. CI).
//!
//! Also derives the `Type.type` → running/other mapping for this watch by
//! correlating with GB's `ACTIVITY_KIND` (running rows have `& 3 == 1`).

use std::collections::HashMap;
use std::path::PathBuf;

use mont::ble::workout::parse_summary;
use rusqlite::Connection;

fn export_db() -> Option<PathBuf> {
    let p = PathBuf::from("../gadgetbridge_export/database/Gadgetbridge");
    p.is_file().then_some(p)
}

fn is_running_kind(kind: i64) -> bool {
    // Same rule as the Gadgetbridge zip sync in routes/runs.rs.
    kind & 3 == 1
}

#[test]
fn summary_fixtures_match_gadgetbridge() {
    let Some(db_path) = export_db() else {
        eprintln!("skipping: no gadgetbridge_export database");
        return;
    };
    let conn = Connection::open(db_path).expect("open export db");

    let mut stmt = conn
        .prepare(
            "SELECT RAW_SUMMARY_DATA, SUMMARY_DATA, ACTIVITY_KIND
             FROM BASE_ACTIVITY_SUMMARY WHERE RAW_SUMMARY_DATA IS NOT NULL",
        )
        .expect("prepare");
    let rows: Vec<(Vec<u8>, Option<String>, i64)> = stmt
        .query_map([], |r| {
            Ok((
                match r.get_ref(0) {
                    Ok(rusqlite::types::ValueRef::Blob(b)) => b.to_vec(),
                    Ok(rusqlite::types::ValueRef::Text(t)) => t.to_vec(),
                    _ => vec![],
                },
                r.get::<_, Option<String>>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })
        .expect("query")
        .flatten()
        .collect();
    assert!(!rows.is_empty(), "expected summary fixtures");
    eprintln!("fixtures: {} summaries", rows.len());

    // type code → (running count, other count): must be unambiguous
    let mut type_mapping: HashMap<i64, (usize, usize)> = HashMap::new();
    let mut parsed_ok = 0usize;
    let mut parse_failures = 0usize;
    let mut distance_matches = 0usize;
    let mut duration_matches = 0usize;
    let mut compared = 0usize;
    let mut sport_mapping: HashMap<i64, (usize, usize)> = HashMap::new();

    for (raw, summary_json, kind) in &rows {
        let Ok(summary) = parse_summary(raw) else {
            parse_failures += 1;
            continue;
        };
        parsed_ok += 1;

        let running = is_running_kind(*kind);
        let entry = type_mapping
            .entry(summary.type_code.unwrap_or(-1))
            .or_insert((0, 0));
        if running {
            entry.0 += 1;
        } else {
            entry.1 += 1;
        }
        let sport_entry = sport_mapping
            .entry(summary.sport_code.unwrap_or(-1))
            .or_insert((0, 0));
        if running {
            sport_entry.0 += 1;
        } else {
            sport_entry.1 += 1;
        }

        let Some(json_text) = summary_json else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(json_text) else {
            continue;
        };
        let json_num = |key: &str| {
            json.get(key)
                .and_then(|o| o.get("value"))
                .and_then(serde_json::Value::as_f64)
        };

        // distance: GB writes distanceMeters in meters. A couple of legacy
        // rows (older firmware) keep their distance elsewhere — their parsed
        // float is garbage ≈ 0, so only compare plausible values.
        if let (Some(gb), Some(mine)) = (json_num("distanceMeters"), summary.distance_m) {
            if mine > 100.0 {
                compared += 1;
                if (gb - mine).abs() < 2.0 {
                    distance_matches += 1;
                } else if compared - distance_matches <= 3 {
                    eprintln!(
                        "distance mismatch: gb={gb} mine={mine} type={:?}",
                        summary.type_code
                    );
                }
            }
        }
        // duration: GB activeSeconds == workoutDuration (active time)
        if let (Some(gb), Some(mine)) = (json_num("activeSeconds"), summary.workout_duration_s) {
            if (gb - f64::from(mine as i32)).abs() <= 1.0 {
                duration_matches += 1;
            }
        }
    }

    eprintln!(
        "parsed_ok={parsed_ok} parse_failures={parse_failures} compared={compared} distance_matches={distance_matches} duration_matches={duration_matches}"
    );
    for (code, (run, other)) in &type_mapping {
        eprintln!("Type.type {code}: running={run} other={other}");
    }
    for (code, (run, other)) in &sport_mapping {
        eprintln!("Location.f3 {code}: running={run} other={other}");
    }

    assert_eq!(parse_failures, 0, "every summary blob must parse");
    // every type code must map unambiguously to running or not-running
    for (code, (run, other)) in &type_mapping {
        assert!(
            *run == 0 || *other == 0,
            "type {code} is ambiguous: {run} running vs {other} other"
        );
    }
    // the outdoor-run code must exist and be running-only
    assert!(
        type_mapping
            .get(&mont::ble::workout::SPORT_TYPE_OUTDOOR_RUN)
            .is_some_and(|(run, other)| { *run > 0 && *other == 0 }),
        "Type.type 1 must be present and running-only"
    );
    // distance agreement for the vast majority of rows that carry a distance
    if compared > 0 {
        assert!(
            distance_matches * 10 >= compared * 9,
            "distance agreement too low: {distance_matches}/{compared}"
        );
    }
}
