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
        })
        .collect())
}

/// Parse 6-byte epoch+hr records (resting 0x3a / max 0x3d).
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
            epoch: i64::from(i32::from_le_bytes([r[0], r[1], r[2], r[3]])),
            hr: r[5],
        })
        .collect())
}

/// Parse 6-byte HRV records (0x49).
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
            ts: i64::from(i32::from_le_bytes([r[0], r[1], r[2], r[3]])),
            value: r[5],
        })
        .collect())
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
        payload.extend_from_slice(&[4, 55]);
        payload.extend_from_slice(&(epoch + 86_400).to_le_bytes());
        payload.extend_from_slice(&[4, 61]);
        let marks = parse_hr_marks(&payload).unwrap();
        assert_eq!(marks.len(), 2);
        assert_eq!(marks[0].epoch, 1_700_000_000);
        assert_eq!(marks[0].hr, 55);
        assert_eq!(marks[1].hr, 61);
        assert_eq!(parse_hr_marks(&[0; 5]), Err(ParseError::BadLength));
    }

    #[test]
    fn hrv_samples_parse() {
        let epoch: i32 = 1_700_012_345;
        let mut payload = Vec::new();
        payload.extend_from_slice(&epoch.to_le_bytes());
        payload.extend_from_slice(&[1, 42]);
        let samples = parse_hrv_samples(&payload).unwrap();
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].ts, 1_700_012_345);
        assert_eq!(samples[0].value, 42);
        assert_eq!(parse_hrv_samples(&[0; 4]), Err(ParseError::BadLength));
    }
}
