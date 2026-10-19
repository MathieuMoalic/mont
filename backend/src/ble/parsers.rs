//! Parsers for Huami 0x004b fetch payloads.
//!
//! Formats follow Gadgetbridge's fetch operations for this watch family:
//! - activity (0x01): 8-byte samples per minute — kind, intensity, steps, hr,
//!   unk, sleep, deepSleep, remSleep (no header; length must be a multiple of
//!   8). Timestamps are minute steps from the fetch start timestamp.
//! - resting (0x3a) / max (0x3d) heart rate: 6-byte records — u32 LE epoch,
//!   i8 tz quarter-hours, u8 hr.
//! - HRV (0x49): 6-byte records — u32 LE epoch, u8 unknown, u8 value.

/// One per-minute activity sample (raw watch values; filtering happens at
/// aggregation time, matching the GB-zip SQL conventions).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActivitySample {
    pub ts: i64,
    pub kind: u8,
    pub steps: u8,
    pub hr: u8,
    /// Asleep flag byte (1 = asleep this minute).
    pub sleep: u8,
    /// Deep-sleep minutes byte.
    pub deep_sleep: u8,
    /// REM-sleep minutes byte.
    pub rem_sleep: u8,
}

/// One resting/max HR daily record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HrMark {
    pub epoch: i64,
    pub hr: u8,
}

/// One HRV reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HrvSample {
    pub ts: i64,
    pub value: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    BadLength,
}

/// Parse 8-byte-per-minute activity samples starting at `start_epoch`.
///
/// # Errors
/// Returns [`ParseError::BadLength`] when the payload is not a multiple of 8.
pub fn parse_activity_samples(
    payload: &[u8],
    start_epoch: i64,
) -> Result<Vec<ActivitySample>, ParseError> {
    if !payload.len().is_multiple_of(8) {
        return Err(ParseError::BadLength);
    }
    Ok(payload
        .chunks_exact(8)
        .enumerate()
        .map(|(i, s)| ActivitySample {
            ts: start_epoch + i64::try_from(i).unwrap_or(0) * 60,
            kind: s[0],
            steps: s[2],
            hr: s[3],
            sleep: s[5],
            deep_sleep: s[6],
            rem_sleep: s[7],
        })
        .collect())
}

/// Parse 6-byte epoch+hr records (resting 0x3a / max 0x3d).
///
/// Layout per GB's `FetchHr*Operation`: u32 LE epoch (true UTC), i8 timezone
/// in quarter-hours, u8 hr.
///
/// # Errors
/// Returns [`ParseError::BadLength`] when the payload is not a multiple of 6.
pub fn parse_hr_marks(payload: &[u8]) -> Result<Vec<HrMark>, ParseError> {
    if !payload.len().is_multiple_of(6) {
        return Err(ParseError::BadLength);
    }
    Ok(payload
        .chunks_exact(6)
        .map(|r| HrMark {
            epoch: i64::from(i32::from_le_bytes([r[0], r[1], r[2], r[3]]))
                + tz_offset_seconds(r[4]),
            hr: r[5],
        })
        .collect())
}

/// Parse 6-byte HRV records (0x49), same layout as the HR marks: u32 LE epoch
/// (true UTC), i8 timezone quarter-hours, u8 value.
///
/// # Errors
/// Returns [`ParseError::BadLength`] when the payload is not a multiple of 6.
pub fn parse_hrv_samples(payload: &[u8]) -> Result<Vec<HrvSample>, ParseError> {
    if !payload.len().is_multiple_of(6) {
        return Err(ParseError::BadLength);
    }
    Ok(payload
        .chunks_exact(6)
        .map(|r| HrvSample {
            ts: i64::from(i32::from_le_bytes([r[0], r[1], r[2], r[3]])) + tz_offset_seconds(r[4]),
            value: r[5],
        })
        .collect())
}

/// The signed quarter-hour timezone byte shared by the 6-byte record types
/// (e.g. 8 = UTC+02:00), in seconds.
fn tz_offset_seconds(b: u8) -> i64 {
    #[allow(clippy::cast_possible_wrap)] // the protocol encodes it as signed i8
    let quarters = b as i8;
    i64::from(quarters) * 900
}

/// One per-minute stress sample (0x13, auto stress).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StressSample {
    pub ts: i64,
    pub stress: u8,
}

/// One sleep session (0x48, fixed 594-byte records) — layout per GB's
/// `HuamiSleepSessionSampleProvider.SleepSession`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SleepSession {
    pub ts: i64,
    /// Midnight of the wake day (watch-local-as-UTC epoch).
    pub midnight_ts: i64,
    /// Minutes since the midnight *before* `midnight_ts`.
    pub sleep_start_min: u16,
    pub sleep_end_min: u16,
    pub avg_hr: u8,
    /// Watch-computed sleep score (Zepp's own metric; kept, not shown).
    pub score: u8,
    pub stages: Vec<SleepStage>,
    pub deep_min: u16,
    pub light_min: u16,
    pub rem_min: u16,
    pub wake_min: u16,
}

/// One stage interval; `raw_type`: 4=light, 5=deep, 8=REM, 7=awake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SleepStage {
    pub start_min: u16,
    pub end_min: u16,
    pub raw_type: u8,
}

/// Normalized stage code used in the DB: 0=awake, 1=light, 2=deep, 3=REM.
#[must_use]
pub const fn sleep_stage_code(raw_type: u8) -> i64 {
    match raw_type {
        5 => 2,
        8 => 3,
        7 => 0,
        _ => 1,
    }
}

/// Parse sleep-session payload: one or more 594-byte session records.
///
/// # Errors
/// Returns [`ParseError::BadLength`] when the payload is not a multiple of
/// 594.
pub fn parse_sleep_sessions(payload: &[u8]) -> Result<Vec<SleepSession>, ParseError> {
    const REC: usize = 594;
    const MAX_STAGES: usize = (REC - 0x56) / 5;
    if !payload.len().is_multiple_of(REC) {
        return Err(ParseError::BadLength);
    }
    Ok(payload
        .chunks_exact(REC)
        .map(|b| {
            let u16le = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]);
            let u32le =
                |o: usize| i64::from(u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]));
            let num_stages = usize::from(b[0x54]).min(MAX_STAGES);
            SleepSession {
                ts: u32le(0x00),
                midnight_ts: u32le(0x04),
                sleep_start_min: u16le(0x0a),
                sleep_end_min: u16le(0x0c),
                avg_hr: b[0x15],
                score: b[0x16],
                stages: (0..num_stages)
                    .map(|i| {
                        let o = 0x56 + 5 * i;
                        SleepStage {
                            start_min: u16le(o),
                            end_min: u16le(o + 2),
                            raw_type: b[o + 4],
                        }
                    })
                    .collect(),
                rem_min: u16le(0x024a),
                light_min: u16le(0x024c),
                deep_min: u16le(0x024e),
                wake_min: u16le(0x0250),
            }
        })
        .collect())
}

/// Parse stress-auto payload: one byte per minute starting at `start_epoch`;
/// `0xFF` marks a minute without a reading.
#[must_use]
pub fn parse_stress_samples(payload: &[u8], start_epoch: i64) -> Vec<StressSample> {
    payload
        .iter()
        .enumerate()
        .filter(|(_, b)| **b != 0xFF)
        .map(|(i, b)| StressSample {
            ts: start_epoch + i64::try_from(i).unwrap_or(0) * 60,
            stress: *b,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_samples_round_trip() {
        let mut payload = Vec::new();
        for i in 0..3u8 {
            payload.extend_from_slice(&[70 + i, 10, i * 5, 60 + i, 0, 0, 0, 0]);
        }
        let samples = parse_activity_samples(&payload, 1_700_000_000).unwrap();
        assert_eq!(samples.len(), 3);
        assert_eq!(samples[0].ts, 1_700_000_000);
        assert_eq!(samples[1].ts, 1_700_000_060);
        assert_eq!(samples[2].kind, 72);
        assert_eq!(samples[2].steps, 10);
        assert_eq!(samples[2].hr, 62);
    }

    #[test]
    fn activity_samples_reject_bad_length() {
        assert_eq!(
            parse_activity_samples(&[0u8; 7], 0),
            Err(ParseError::BadLength)
        );
        assert_eq!(
            parse_activity_samples(&[0u8; 9], 0),
            Err(ParseError::BadLength)
        );
        assert!(parse_activity_samples(&[0u8; 16], 0).is_ok());
    }

    #[test]
    fn hr_marks_parse() {
        let epoch: i32 = 1_700_000_000;
        let mut payload = Vec::new();
        payload.extend_from_slice(&epoch.to_le_bytes());
        payload.extend_from_slice(&[8, 55]); // tz quarter-hours: 8 = UTC+02:00
        payload.extend_from_slice(&(epoch + 86_400).to_le_bytes());
        payload.extend_from_slice(&[0xfc, 61]); // tz −1 h
        let marks = parse_hr_marks(&payload).unwrap();
        assert_eq!(marks.len(), 2);
        // the timezone byte shifts the epoch onto watch-local time
        assert_eq!(marks[0].epoch, 1_700_000_000 + 7_200);
        assert_eq!(marks[0].hr, 55);
        assert_eq!(marks[1].epoch, 1_700_086_400 - 3_600);
        assert_eq!(marks[1].hr, 61);
        assert_eq!(parse_hr_marks(&[0; 5]), Err(ParseError::BadLength));
    }

    #[test]
    fn hrv_samples_parse() {
        let epoch: i32 = 1_700_012_345;
        let mut payload = Vec::new();
        payload.extend_from_slice(&epoch.to_le_bytes());
        payload.extend_from_slice(&[8, 42]); // tz quarter-hours: 8 = UTC+02:00
        let samples = parse_hrv_samples(&payload).unwrap();
        assert_eq!(samples.len(), 1);
        // the timezone byte shifts the epoch onto watch-local time
        assert_eq!(samples[0].ts, 1_700_012_345 + 7_200);
        assert_eq!(samples[0].value, 42);
        assert_eq!(parse_hrv_samples(&[0; 4]), Err(ParseError::BadLength));
    }

    #[test]
    fn sleep_sessions_parse() {
        let mut rec = [0u8; 594];
        rec[0..4].copy_from_slice(&1_700_000_000i32.to_le_bytes());
        rec[4..8].copy_from_slice(&1_700_006_400i32.to_le_bytes()); // midnight
        rec[0x0a..0x0c].copy_from_slice(&1380u16.to_le_bytes()); // 23:00
        rec[0x0c..0x0e].copy_from_slice(&1860u16.to_le_bytes()); // 07:00
        rec[0x15] = 52; // avg hr
        rec[0x16] = 91; // score
        rec[0x54] = 3; // stages
        for (i, (start, end, kind)) in [(1380u16, 1410u16, 5u8), (1410, 1500, 8), (1500, 1860, 4)]
            .into_iter()
            .enumerate()
        {
            let o = 0x56 + 5 * i;
            rec[o..o + 2].copy_from_slice(&start.to_le_bytes());
            rec[o + 2..o + 4].copy_from_slice(&end.to_le_bytes());
            rec[o + 4] = kind;
        }
        rec[0x024a..0x024c].copy_from_slice(&90u16.to_le_bytes()); // rem
        rec[0x024c..0x024e].copy_from_slice(&390u16.to_le_bytes()); // light
        rec[0x024e..0x0250].copy_from_slice(&30u16.to_le_bytes()); // deep
        rec[0x0250..0x0252].copy_from_slice(&30u16.to_le_bytes()); // wake

        let sessions = parse_sleep_sessions(&rec).unwrap();
        assert_eq!(sessions.len(), 1);
        let s = &sessions[0];
        assert_eq!(s.ts, 1_700_000_000);
        assert_eq!(s.midnight_ts, 1_700_006_400);
        assert_eq!(s.sleep_start_min, 1380);
        assert_eq!(s.sleep_end_min, 1860);
        assert_eq!(s.avg_hr, 52);
        assert_eq!(s.score, 91);
        assert_eq!(s.deep_min, 30);
        assert_eq!(s.light_min, 390);
        assert_eq!(s.rem_min, 90);
        assert_eq!(s.wake_min, 30);
        assert_eq!(s.stages.len(), 3);
        assert_eq!(s.stages[0].start_min, 1380);
        assert_eq!(s.stages[0].raw_type, 5);
        assert_eq!(sleep_stage_code(5), 2);
        assert_eq!(sleep_stage_code(8), 3);
        assert_eq!(sleep_stage_code(4), 1);
        assert_eq!(sleep_stage_code(7), 0);
        assert_eq!(
            parse_sleep_sessions(&[0u8; 593]),
            Err(ParseError::BadLength)
        );

        // corrupt stage count must not panic (clamped to the record capacity)
        let mut bad = rec;
        bad[0x54] = 200;
        assert_eq!(parse_sleep_sessions(&bad).unwrap()[0].stages.len(), 101);
    }
}
