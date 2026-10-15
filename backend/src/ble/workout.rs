//! Workout summary parsing: fetch type 0x05 payloads.
//!
//! Raw payload = `[u16 LE 0x8000][protobuf WorkoutSummary]` (Gadgetbridge's
//! `huami.proto`). Only the fields mont needs are decoded; unknown fields are
//! skipped in a wire-format-safe way.

/// Parsed workout summary (watch "local-as-UTC" epoch for the start).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkoutSummary {
    /// `Type.type` — GB's coarse type message (top-level field 3).
    pub type_code: Option<i64>,
    /// `Location.f3` — per-sport code on Zepp OS watches (8 = outdoor run on
    /// this Cheetah Pro, per the ble-health-import branch).
    pub sport_code: Option<i64>,
    /// `Location.startTimestamp` (seconds).
    pub start_epoch: Option<i64>,
    /// `Time.totalDuration` (seconds, includes pauses).
    pub total_duration_s: Option<i64>,
    /// `Time.workoutDuration` (seconds, active time).
    pub workout_duration_s: Option<i64>,
    /// `Distance.distance` (meters).
    pub distance_m: Option<f64>,
    pub avg_hr: Option<i64>,
    pub max_hr: Option<i64>,
    /// `Calories.calories` (kcal).
    pub calories: Option<i64>,
}

/// `Type.type` code for outdoor runs (verified: 196/196 running rows in the
/// GB export carry type 1, and no non-running row does).
pub const SPORT_TYPE_OUTDOOR_RUN: i64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    TooShort,
    BadVersion,
    Malformed,
}

/// Strip the version prefix and parse the protobuf summary.
///
/// # Errors
/// Returns [`ParseError::TooShort`] / [`ParseError::BadVersion`] for framing
/// problems and [`ParseError::Malformed`] for a corrupt protobuf.
pub fn parse_summary(raw: &[u8]) -> Result<WorkoutSummary, ParseError> {
    if raw.len() < 3 {
        return Err(ParseError::TooShort);
    }
    let version = u16::from_le_bytes([raw[0], raw[1]]);
    if version != 0x8000 {
        return Err(ParseError::BadVersion);
    }
    let mut out = WorkoutSummary::default();
    parse_message(&raw[2..], &mut out)?;
    Ok(out)
}

#[derive(Debug, Clone, Copy)]
struct Field<'a> {
    number: u32,
    /// Varint value (wire type 0).
    varint: u64,
    /// Payload slice (wire type 2).
    bytes: &'a [u8],
}

fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, ParseError> {
    let mut value = 0u64;
    for i in 0..10 {
        let Some(&b) = data.get(*pos) else {
            return Err(ParseError::Malformed);
        };
        *pos += 1;
        value |= u64::from(b & 0x7f) << (i * 7);
        if b & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(ParseError::Malformed)
}

#[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)] // protobuf keys/lengths are spec-bounded; lengths are bounds-checked below
fn next_field<'a>(data: &'a [u8], pos: &mut usize) -> Result<Option<Field<'a>>, ParseError> {
    if *pos >= data.len() {
        return Ok(None);
    }
    let key = read_varint(data, pos)?;
    let wire = (key & 0x07) as u8;
    let number = (key >> 3) as u32;
    let field = match wire {
        0 => Field {
            number,
            varint: read_varint(data, pos)?,
            bytes: &[],
        },
        1 => {
            let Some(end) = pos.checked_add(8).filter(|&e| e <= data.len()) else {
                return Err(ParseError::Malformed);
            };
            let f = Field {
                number,
                varint: 0,
                bytes: &data[*pos..end],
            };
            *pos = end;
            f
        }
        2 => {
            let len = read_varint(data, pos)? as usize;
            let Some(end) = pos.checked_add(len).filter(|&e| e <= data.len()) else {
                return Err(ParseError::Malformed);
            };
            let f = Field {
                number,
                varint: 0,
                bytes: &data[*pos..end],
            };
            *pos = end;
            f
        }
        5 => {
            let Some(end) = pos.checked_add(4).filter(|&e| e <= data.len()) else {
                return Err(ParseError::Malformed);
            };
            let f = Field {
                number,
                varint: 0,
                bytes: &data[*pos..end],
            };
            *pos = end;
            f
        }
        _ => return Err(ParseError::Malformed),
    };
    Ok(Some(field))
}

fn f32_le(bytes: &[u8]) -> Option<f64> {
    if bytes.len() < 4 {
        return None;
    }
    Some(f64::from(f32::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3],
    ])))
}

fn parse_message(data: &[u8], out: &mut WorkoutSummary) -> Result<(), ParseError> {
    let mut pos = 0usize;
    while let Some(field) = next_field(data, &mut pos)? {
        match field.number {
            2 => parse_location(field.bytes, out)?,
            3 => out.type_code = parse_type_message(field.bytes)?,
            4 => out.distance_m = f32_le(field.bytes),
            7 => parse_time(field.bytes, out)?,
            16 => out.calories = Some(field.varint.cast_signed()),
            19 => parse_heart_rate(field.bytes, out)?,
            _ => {}
        }
    }
    Ok(())
}

/// Top-level field 3 is the `Type` message `{ type = 1, ai = 2 }` (proto3:
/// absent/0 values may be elided, so a missing field means 0).
fn parse_type_message(data: &[u8]) -> Result<Option<i64>, ParseError> {
    let mut pos = 0usize;
    let mut code = Some(0);
    while let Some(field) = next_field(data, &mut pos)? {
        if field.number == 1 {
            code = Some(field.varint.cast_signed());
        }
    }
    Ok(code)
}

fn parse_location(data: &[u8], out: &mut WorkoutSummary) -> Result<(), ParseError> {
    let mut pos = 0usize;
    while let Some(field) = next_field(data, &mut pos)? {
        match field.number {
            1 => out.start_epoch = Some(i64::from(u32::try_from(field.varint).unwrap_or(0))),
            3 => out.sport_code = Some(field.varint.cast_signed()),
            _ => {}
        }
    }
    Ok(())
}

fn parse_time(data: &[u8], out: &mut WorkoutSummary) -> Result<(), ParseError> {
    let mut pos = 0usize;
    while let Some(field) = next_field(data, &mut pos)? {
        match field.number {
            1 => out.total_duration_s = Some(field.varint.cast_signed()),
            2 => out.workout_duration_s = Some(field.varint.cast_signed()),
            _ => {}
        }
    }
    Ok(())
}

fn parse_heart_rate(data: &[u8], out: &mut WorkoutSummary) -> Result<(), ParseError> {
    let mut pos = 0usize;
    while let Some(field) = next_field(data, &mut pos)? {
        match field.number {
            1 => out.avg_hr = Some(field.varint.cast_signed()),
            2 => out.max_hr = Some(field.varint.cast_signed()),
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wire-format tag: proper varint of `(num << 3) | wire` (fields ≥ 16
    /// need two bytes).
    fn tag(num: u32, wire: u32) -> Vec<u8> {
        let mut key = u64::from(num << 3) | u64::from(wire);
        let mut out = Vec::new();
        loop {
            let b = (key & 0x7f) as u8;
            key >>= 7;
            if key == 0 {
                out.push(b);
                break;
            }
            out.push(b | 0x80);
        }
        out
    }

    /// Build protobuf bytes by hand: field(num, wire) helpers.
    fn varint_field(num: u32, value: u64) -> Vec<u8> {
        let mut out = tag(num, 0);
        let mut v = value;
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                break;
            }
            out.push(b | 0x80);
        }
        out
    }

    fn len_field(num: u32, payload: &[u8]) -> Vec<u8> {
        let mut out = tag(num, 2);
        let mut v = payload.len() as u64;
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                break;
            }
            out.push(b | 0x80);
        }
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn parses_synthetic_summary() {
        let location = {
            let mut l = varint_field(1, 1_700_000_000); // startTimestamp
            l.extend(varint_field(5, 49 * 6_000_000)); // baseLatitude
            l
        };
        let time = {
            let mut t = varint_field(1, 4_680); // totalDuration
            t.extend(varint_field(2, 4_600)); // workoutDuration
            t
        };
        let hr = {
            let mut h = varint_field(1, 129);
            h.extend(varint_field(2, 141));
            h
        };
        let mut proto = Vec::new();
        proto.extend(len_field(2, &location));
        proto.extend(len_field(3, &varint_field(1, 8))); // Type { type: 8 }
        proto.extend(len_field(4, &9876f32.to_le_bytes())); // distance
        proto.extend(len_field(7, &time));
        proto.extend(len_field(19, &hr));
        proto.extend(varint_field(16, 350)); // calories
        proto.extend(varint_field(99, 1)); // unknown field must be skipped

        let raw = {
            let mut r = 0x8000u16.to_le_bytes().to_vec();
            r.extend_from_slice(&proto);
            r
        };
        let s = parse_summary(&raw).unwrap();
        assert_eq!(s.type_code, Some(8));
        assert_eq!(s.start_epoch, Some(1_700_000_000));
        assert_eq!(s.total_duration_s, Some(4_680));
        assert_eq!(s.workout_duration_s, Some(4_600));
        assert_eq!(s.distance_m, Some(9876.0));
        assert_eq!((s.avg_hr, s.max_hr), (Some(129), Some(141)));
        assert_eq!(s.calories, Some(350));
    }

    #[test]
    fn rejects_bad_version_and_short() {
        assert_eq!(
            parse_summary(&[0x01, 0x80, 0x00]),
            Err(ParseError::BadVersion)
        );
        assert_eq!(parse_summary(&[0x00]), Err(ParseError::TooShort));
    }

    #[test]
    fn truncated_protobuf_is_malformed() {
        let raw = [0x00, 0x80, 0x12, 0x40]; // field 2, length 0x40 but no data
        assert_eq!(parse_summary(&raw), Err(ParseError::Malformed));
    }
}
