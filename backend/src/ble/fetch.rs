//! Fetch engine for the activity-fetch channel (chunked endpoint `0x004b`,
//! bulk data on characteristic 0x0005) — mirrors Gadgetbridge's
//! `AbstractFetchOperation` flow:
//!
//! 1. request `{0x01, type, ts…}` → response `{0x10,0x01,0x01,len,startTs}` (or
//!    `len == 0` for "no data")
//! 2. `{0x02}` → data packets `{counter, payload…}` on 0x0005 (counter +1 each)
//! 3. end `{0x10,0x02,0x01[,crc32]}` → verify CRC → ack `{0x03,0x09}`
//!    (**always keep data on the watch** — never send `0x01`, which deletes the
//!    data and advances the watch's transfer pointer)
//! 4. ack reply `{0x10,0x03,…}` → operation finished

/// Data fetch types (GB `HuamiFetchDataType`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchType {
    Activity = 0x01,
    SportsSummaries = 0x05,
    SportsDetails = 0x06,
    Stress = 0x13,
    RestingHr = 0x3a,
    MaxHr = 0x3d,
    Hrv = 0x49,
    SleepSession = 0x48,
}

impl FetchType {
    #[must_use]
    pub const fn id(self) -> u8 {
        self as u8
    }

    /// Stable `snake_case` name (sync-log rows, UI labels).
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Activity => "activity",
            Self::SportsSummaries => "workout_summary",
            Self::SportsDetails => "workout",
            Self::Stress => "stress",
            Self::RestingHr => "resting_hr",
            Self::MaxHr => "max_hr",
            Self::Hrv => "hrv",
            Self::SleepSession => "sleep_session",
        }
    }

    /// Name for a fetch-type id (inverse of [`FetchType::id`]).
    #[must_use]
    pub fn name_for_id(id: u8) -> &'static str {
        const ALL: [FetchType; 8] = [
            FetchType::Activity,
            FetchType::SportsSummaries,
            FetchType::SportsDetails,
            FetchType::Stress,
            FetchType::RestingHr,
            FetchType::MaxHr,
            FetchType::Hrv,
            FetchType::SleepSession,
        ];
        for t in ALL {
            if t.id() == id {
                return t.name();
            }
        }
        "unknown"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchEvent {
    /// Response said there is no data for the requested range.
    NoData,
    /// Transfer accepted: expect `expected_len` payload bytes starting at
    /// `start_epoch` (watch "local-as-UTC" seconds).
    Response { expected_len: u32, start_epoch: i64 },
    /// End marker received; payload is complete, CRC validated when present.
    Complete {
        payload: Vec<u8>,
        crc_ok: Option<bool>,
    },
    /// The watch acknowledged our ack — operation closed.
    Acked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    AwaitingResponse,
    Streaming,
    AwaitingAckReply,
}

pub struct FetchTracker {
    fetch_type: FetchType,
    state: State,
    last_counter: Option<u8>,
    buffer: Vec<u8>,
    expected_len: u32,
    start_epoch: i64,
}

impl FetchTracker {
    #[must_use]
    pub const fn new(fetch_type: FetchType) -> Self {
        Self {
            fetch_type,
            state: State::AwaitingResponse,
            last_counter: None,
            buffer: Vec::new(),
            expected_len: 0,
            start_epoch: 0,
        }
    }

    #[must_use]
    pub const fn fetch_type(&self) -> FetchType {
        self.fetch_type
    }

    #[must_use]
    pub const fn received_len(&self) -> usize {
        self.buffer.len()
    }

    /// Build the fetch request payload for `since_epoch` (watch local-as-UTC
    /// seconds, truncated to the minute like Gadgetbridge's default).
    #[must_use]
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)] // calendar values are in range
    pub fn build_request(fetch_type: FetchType, since_epoch: i64, tz_quarter_hours: i8) -> Vec<u8> {
        use chrono::{Datelike, TimeZone, Timelike, Utc};
        let dt = Utc
            .timestamp_opt(since_epoch - since_epoch.rem_euclid(60), 0)
            .single()
            .unwrap_or_default();
        vec![
            0x01,
            fetch_type.id(),
            (dt.year() as u16).to_le_bytes()[0],
            (dt.year() as u16).to_le_bytes()[1],
            dt.month() as u8,
            dt.day() as u8,
            dt.hour() as u8,
            dt.minute() as u8,
            dt.second() as u8,
            tz_quarter_hours as u8,
        ]
    }

    /// Feed one control payload from chunked endpoint 0x004b.
    pub fn on_control(&mut self, payload: &[u8]) -> Option<FetchEvent> {
        if payload.len() < 3 || payload[0] != 0x10 {
            return None;
        }
        match (self.state, payload[1]) {
            (State::AwaitingResponse, 0x01) => {
                if payload[2] != 0x01 {
                    return Some(FetchEvent::NoData);
                }
                if payload.len() < 15 {
                    return Some(FetchEvent::NoData);
                }
                self.expected_len =
                    u32::from_le_bytes([payload[3], payload[4], payload[5], payload[6]]);
                self.start_epoch = watch_ts_to_epoch(&payload[7..15]);
                if self.expected_len == 0 {
                    return Some(FetchEvent::NoData);
                }
                self.buffer = Vec::with_capacity(self.expected_len as usize);
                self.last_counter = None;
                self.state = State::Streaming;
                Some(FetchEvent::Response {
                    expected_len: self.expected_len,
                    start_epoch: self.start_epoch,
                })
            }
            (State::Streaming, 0x02) => {
                if payload[2] != 0x01 {
                    return None;
                }
                let crc_ok = if payload.len() >= 7 {
                    let received =
                        u32::from_le_bytes([payload[3], payload[4], payload[5], payload[6]]);
                    Some(crc32fast::hash(&self.buffer) == received)
                } else {
                    None
                };
                self.state = State::AwaitingAckReply;
                let payload = std::mem::take(&mut self.buffer);
                Some(FetchEvent::Complete { payload, crc_ok })
            }
            // The watch's ack-reply closes the operation from any state (GB
            // treats it as the operation end marker).
            (_, 0x03) => {
                self.state = State::AwaitingResponse;
                Some(FetchEvent::Acked)
            }
            _ => None,
        }
    }

    /// Feed one raw data packet from characteristic 0x0005 (`{counter, bytes…}`).
    ///
    /// # Errors
    /// Returns an error when the packet counter is not the expected increment.
    pub fn on_data(&mut self, packet: &[u8]) -> Result<(), String> {
        if self.state != State::Streaming {
            return Err("data packet while not streaming".into());
        }
        if packet.is_empty() {
            return Err("empty data packet".into());
        }
        let counter = packet[0];
        match self.last_counter {
            None => {
                // First packet: accept any counter, remember it.
                self.last_counter = Some(counter);
            }
            Some(last) => {
                if counter != last.wrapping_add(1) {
                    return Err(format!("packet counter {counter} after {last}"));
                }
                self.last_counter = Some(counter);
            }
        }
        self.buffer.extend_from_slice(&packet[1..]);
        Ok(())
    }
}

/// Watch timestamps: u16 LE year, then month/day/hour/minute/second bytes and
/// a tz byte we ignore — interpreted as UTC wall-clock ("local-as-UTC", the
/// Huami convention the existing GB zip sync uses).
#[must_use]
pub fn watch_ts_to_epoch(bytes: &[u8]) -> i64 {
    use chrono::{TimeZone, Utc};
    if bytes.len() < 7 {
        return 0;
    }
    let year = u16::from_le_bytes([bytes[0], bytes[1]]);
    let month = i32::from(bytes[2]);
    let day = i32::from(bytes[3]);
    let hour = i32::from(bytes[4]);
    let min = i32::from(bytes[5]);
    let sec = i32::from(bytes[6]);
    chrono::NaiveDate::from_ymd_opt(
        i32::from(year),
        month.clamp(1, 12).cast_unsigned(),
        day.clamp(1, 31).cast_unsigned(),
    )
    .and_then(|d| {
        d.and_hms_opt(
            hour.clamp(0, 23).cast_unsigned(),
            min.clamp(0, 59).cast_unsigned(),
            sec.clamp(0, 59).cast_unsigned(),
        )
    })
    .map_or(0, |dt| Utc.from_utc_datetime(&dt).timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start_response(len: u32, start_epoch: i64) -> Vec<u8> {
        use chrono::{Datelike, TimeZone, Timelike, Utc};
        let dt = Utc.timestamp_opt(start_epoch, 0).single().unwrap();
        let mut p = vec![0x10, 0x01, 0x01];
        p.extend_from_slice(&len.to_le_bytes());
        p.extend_from_slice(&u16::try_from(dt.year()).unwrap().to_le_bytes());
        p.push(u8::try_from(dt.month()).unwrap());
        p.push(u8::try_from(dt.day()).unwrap());
        p.push(u8::try_from(dt.hour()).unwrap());
        p.push(u8::try_from(dt.minute()).unwrap());
        p.push(u8::try_from(dt.second()).unwrap());
        p.push(4);
        p
    }

    #[test]
    fn request_payload_layout() {
        // 2023-11-14 08:30:00 UTC
        let p = FetchTracker::build_request(FetchType::Activity, 1_699_950_600, 4);
        assert_eq!(p.len(), 10);
        assert_eq!(p[0], 0x01);
        assert_eq!(p[1], 0x01);
        assert_eq!(u16::from_le_bytes([p[2], p[3]]), 2023);
        assert_eq!(p[4], 11);
        assert_eq!(p[5], 14);
        assert_eq!(p[6], 8);
        assert_eq!(p[7], 30);
        assert_eq!(p[8], 0); // minute-truncated
        assert_eq!(p[9], 4);
    }

    #[test]
    fn no_data_flow() {
        let mut t = FetchTracker::new(FetchType::Hrv);
        assert_eq!(
            t.on_control(&[0x10, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            Some(FetchEvent::NoData)
        );
    }

    #[test]
    fn full_transfer_flow_with_crc() {
        let payload = [0xAAu8; 20];
        let mut t = FetchTracker::new(FetchType::RestingHr);

        match t.on_control(&start_response(20, 1_700_000_000)) {
            Some(FetchEvent::Response {
                expected_len,
                start_epoch,
            }) => {
                assert_eq!(expected_len, 20);
                assert_eq!(start_epoch, 1_700_000_000);
            }
            other => panic!("expected response, got {other:?}"),
        }

        // data packets on 0x0005, counters 1..2, payload without the counter byte
        let mut p1 = vec![1u8];
        p1.extend_from_slice(&payload[..12]);
        let mut p2 = vec![2u8];
        p2.extend_from_slice(&payload[12..]);
        t.on_data(&p1).unwrap();
        t.on_data(&p2).unwrap();
    }

    #[test]
    fn counter_must_increment() {
        let mut t = FetchTracker::new(FetchType::Activity);
        let _ = t.on_control(&start_response(8, 1_700_000_000));
        t.on_data(&[7, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
        assert!(t.on_data(&[7, 0]).is_err()); // repeat
        t.on_data(&[8, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
    }

    #[test]
    fn complete_with_crc_validation() {
        let payload = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let crc = crc32fast::hash(&payload);
        let mut t = FetchTracker::new(FetchType::Activity);
        let _ = t.on_control(&start_response(8, 1_700_000_000));
        t.on_data(&std::iter::once(1u8).chain(payload).collect::<Vec<_>>())
            .unwrap();
        let mut end = vec![0x10, 0x02, 0x01];
        end.extend_from_slice(&crc.to_le_bytes());
        match t.on_control(&end) {
            Some(FetchEvent::Complete {
                payload: p,
                crc_ok: Some(true),
            }) => assert_eq!(p, payload),
            other => panic!("expected complete, got {other:?}"),
        }
        // ack reply closes
        assert_eq!(t.on_control(&[0x10, 0x03, 0x01]), Some(FetchEvent::Acked));
    }

    #[test]
    fn watch_ts_conversion() {
        // 2023-11-14 08:30:00
        let bytes = [0xe7, 0x07, 11, 14, 8, 30, 0, 4];
        assert_eq!(watch_ts_to_epoch(&bytes), 1_699_950_600);
    }
}
