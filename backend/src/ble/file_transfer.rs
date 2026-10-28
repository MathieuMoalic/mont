//! `ZeppOS` file-transfer session (endpoint `0x000d`): send a file to the
//! watch. Port of Gadgetbridge's `ZeppOsFileTransferService` +
//! `ZeppOsFileTransferV2`/`V3`.
//!
//! Flow: capabilities request (`01`) → response (`02 ‖ version ‖ chunkSize
//! ‖ …`) → transfer request (`03 ‖ session ‖ url\0 ‖ filename\0 ‖ rawLen u32
//! ‖ crc32 u32 ‖ [v3: compressed u8 ‖ compressedChunkSize u32] ‖ 0x00`) →
//! response (`04 ‖ session ‖ status ‖ existingProgress u32`) → data chunks
//! (`10`/`12` with first/last flags + chunk index) each acked (`11`/`13`).
//! Done once the last chunk is acked — the watch sends no final message.
//!
//! V3 firmware moves the data chunks off the chunked endpoint onto the
//! dedicated characteristics (`0x23` notify/`0x24` write), unchunked raw
//! payload splits; acks arrive as `13 ‖ status ‖ index ‖ unk` notifications.

pub const FILE_TRANSFER_ENDPOINT: u16 = 0x000d;
/// The watch's sport app consumes route files sent to this URL.
pub const ROUTE_SEND_URL: &str = "sport://file_transfer?appId=7073283073&params={}";

const CMD_CAPABILITIES_REQUEST: u8 = 0x01;
const CMD_CAPABILITIES_RESPONSE: u8 = 0x02;
const CMD_TRANSFER_REQUEST: u8 = 0x03;
const CMD_TRANSFER_RESPONSE: u8 = 0x04;
const CMD_DATA_SEND: u8 = 0x10;
const CMD_DATA_ACK: u8 = 0x11;
const CMD_DATA_V3_SEND: u8 = 0x12;
const CMD_DATA_V3_ACK: u8 = 0x13;

const FLAG_FIRST_CHUNK: u8 = 0x01;
const FLAG_LAST_CHUNK: u8 = 0x02;

/// Version selected from the capabilities response.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferVersion {
    V2,
    V3,
}

/// What a step of the transfer wants the driver to do next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileSendStep {
    /// Send these payloads: (endpoint, frames). Empty payload lists advance
    /// internal state only.
    Write {
        endpoint: u16,
        frames: Vec<Vec<u8>>,
        /// For V3 data: write parts raw to this characteristic instead.
        char_0x23: bool,
    },
    /// The file transferred successfully.
    Done,
}

/// One upload session over an established (authenticated + encrypted) BLE
/// connection. `data` is the already-encoded file content.
#[derive(Debug)]
pub struct FileTransfer {
    pub url: String,
    pub filename: String,
    pub data: Vec<u8>,
    pub version: Option<FileTransferVersion>,
    pub chunk_size: usize,
    session: u8,
    offset: usize,
    chunk_index: u8,
}

impl FileTransfer {
    /// Starts a new upload session: returns the capabilities-request payload
    /// for endpoint `0x000d`.
    #[must_use]
    pub const fn new(url: String, filename: String, data: Vec<u8>) -> Self {
        Self {
            url,
            filename,
            data,
            version: None,
            chunk_size: 0,
            session: 0,
            offset: 0,
            chunk_index: 0,
        }
    }

    /// Parses a capabilities response (`02 ‖ version ‖ chunkSize u16 ‖ …`).
    /// Returns the negotiated version and chunk size.
    ///
    /// # Errors
    /// Unexpected payload shape or unsupported version. The `try_into` is
    /// guarded by a length check, so no panic path remains.
    pub fn on_capabilities(&mut self, payload: &[u8]) -> Result<(), String> {
        if payload.first() != Some(&CMD_CAPABILITIES_RESPONSE) {
            return Err(format!(
                "unexpected capabilities payload: {:02x?}",
                payload.first()
            ));
        }
        let Some(&version) = payload.get(1) else {
            return Err("capabilities response missing version".to_string());
        };
        let chunk_size = u16::from_le_bytes(
            payload
                .get(2..4)
                .ok_or_else(|| "capabilities response missing chunk size".to_string())?
                .try_into()
                .unwrap_or_default(),
        ) as usize;
        if chunk_size == 0 {
            return Err("watch reported a zero chunk size".to_string());
        }
        match version {
            1 | 2 => self.version = Some(FileTransferVersion::V2),
            3 => self.version = Some(FileTransferVersion::V3),
            other => return Err(format!("unsupported file transfer version {other}")),
        }
        self.chunk_size = chunk_size;
        Ok(())
    }

    /// Builds the transfer-request payload for the (already negotiated)
    /// version. The CRC-32 covers the raw file bytes.
    ///
    /// # Errors
    /// Called before the capabilities handshake completed.
    pub fn transfer_request(&mut self) -> Result<Vec<u8>, String> {
        let Some(version) = self.version else {
            return Err("transfer request before capabilities handshake".to_string());
        };
        self.session = self.session.wrapping_add(1).max(1);
        let crc32 = crc32fast::hash(&self.data);
        let raw_len = u32::try_from(self.data.len()).unwrap_or(u32::MAX);

        let mut buf = vec![CMD_TRANSFER_REQUEST, self.session];
        buf.extend_from_slice(self.url.as_bytes());
        buf.push(0);
        buf.extend_from_slice(self.filename.as_bytes());
        buf.push(0);
        buf.extend_from_slice(&raw_len.to_le_bytes());
        buf.extend_from_slice(&crc32.to_le_bytes());
        if matches!(version, FileTransferVersion::V3) {
            buf.push(0); // uncompressed
        }
        buf.push(0);
        Ok(buf)
    }

    /// Parses a transfer response (`04 ‖ session ‖ status ‖ progress u32`).
    /// On success returns the frames that carry the first data chunk.
    ///
    /// # Errors
    /// Wrong session, nonzero status, or malformed payload.
    pub fn on_transfer_response(
        &mut self,
        payload: &[u8],
        mtu: u16,
    ) -> Result<FileSendStep, String> {
        if payload.first() != Some(&CMD_TRANSFER_RESPONSE) {
            return Err(format!(
                "unexpected transfer response: {:02x?}",
                payload.first()
            ));
        }
        if payload.get(1) != Some(&self.session) {
            return Err("transfer response for a different session".to_string());
        }
        match payload.get(2) {
            Some(0) => {}
            other => return Err(format!("transfer rejected by the watch: {other:02x?}")),
        }
        let progress = payload
            .get(3..7)
            .map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize);
        // GB semantics: progress is a resume offset. At/beyond the file size
        // means the watch already has the whole file — complete without
        // sending anything.
        if progress >= self.data.len() {
            self.offset = self.data.len();
            return Ok(FileSendStep::Done);
        }
        self.offset = progress;
        Ok(self.next_data_chunk(mtu))
    }

    /// Parses a data ack. V2 (`11 ‖ session ‖ status`) arrives over the
    /// chunked endpoint; V3 (`13 ‖ status ‖ chunkIndex ‖ unk`) arrives raw on
    /// char 0x23 with no session byte (GB `ZeppOsFileTransferV3`).
    /// On success returns the frames for the next chunk, or [`FileSendStep::Done`]
    /// once the whole file transferred.
    ///
    /// # Errors
    /// Wrong command, nonzero status (watch rejected the chunk), unexpected
    /// chunk index, or malformed payload.
    pub fn on_data_ack(&mut self, payload: &[u8], mtu: u16) -> Result<FileSendStep, String> {
        if matches!(self.version, Some(FileTransferVersion::V3)) {
            if payload.first() != Some(&CMD_DATA_V3_ACK) {
                return Err(format!(
                    "unexpected data ack: {:02x?} (expected {CMD_DATA_V3_ACK:02x})",
                    payload.first()
                ));
            }
            match payload.get(1) {
                Some(0) => {}
                other => return Err(format!("watch rejected a chunk: {other:02x?}")),
            }
            let index = payload.get(2).copied().unwrap_or(u8::MAX);
            if index != self.chunk_index.wrapping_sub(1) {
                return Err(format!("data ack for unexpected chunk index {index}"));
            }
        } else {
            if payload.first() != Some(&CMD_DATA_ACK) {
                return Err(format!(
                    "unexpected data ack: {:02x?} (expected {CMD_DATA_ACK:02x})",
                    payload.first()
                ));
            }
            if payload.get(1) != Some(&self.session) {
                return Err("data ack for a different session".to_string());
            }
            match payload.get(2) {
                Some(0) => {}
                other => return Err(format!("watch rejected a chunk: {other:02x?}")),
            }
        }
        Ok(self.next_data_chunk(mtu))
    }

    /// Builds the next data-chunk frames, or [`FileSendStep::Done`] when the
    /// file is fully transferred. Chunk len fits u16 (negotiated u16).
    fn next_data_chunk(&mut self, mtu: u16) -> FileSendStep {
        if self.offset >= self.data.len() {
            return FileSendStep::Done;
        }
        let remaining = self.data.len() - self.offset;
        // chunk_size came from a u16, so the min always fits.
        #[allow(clippy::cast_possible_truncation)]
        let chunk_len = self.chunk_size.min(remaining) as u16;
        let last = self.offset + chunk_len as usize >= self.data.len();
        let mut flags = 0u8;
        if self.offset == 0 {
            flags |= FLAG_FIRST_CHUNK;
        }
        if last {
            flags |= FLAG_LAST_CHUNK;
        }
        if matches!(self.version, Some(FileTransferVersion::V3)) {
            let mut payload = vec![CMD_DATA_V3_SEND, flags, self.chunk_index];
            payload.extend_from_slice(&chunk_len.to_le_bytes());
            payload.extend_from_slice(&self.data[self.offset..self.offset + chunk_len as usize]);
            self.offset += chunk_len as usize;
            self.chunk_index = self.chunk_index.wrapping_add(1);
            return FileSendStep::Write {
                endpoint: 0,
                frames: split_mtu(&payload, mtu),
                char_0x23: true,
            };
        }
        // V2: data rides the chunked endpoint inside CMD_DATA_SEND frames;
        // the outer chunked codec adds its own framing.
        let mut payload = vec![CMD_DATA_SEND];
        if self.offset == 0 {
            payload.push(FLAG_FIRST_CHUNK);
        }
        if last {
            payload.push(FLAG_LAST_CHUNK);
        }
        payload.push(self.session);
        payload.push(self.chunk_index);
        if self.offset == 0 {
            payload.extend_from_slice(&[0, 0, 0, 0]);
        }
        payload.extend_from_slice(&chunk_len.to_le_bytes());
        payload.extend_from_slice(&self.data[self.offset..self.offset + chunk_len as usize]);
        self.offset += chunk_len as usize;
        self.chunk_index = self.chunk_index.wrapping_add(1);
        FileSendStep::Write {
            endpoint: FILE_TRANSFER_ENDPOINT,
            frames: vec![payload],
            char_0x23: false,
        }
    }
}

/// Splits a payload into MTU-sized BLE write parts (no per-part header — the
/// watch reassembles V3 data streams itself).
fn split_mtu(payload: &[u8], mtu: u16) -> Vec<Vec<u8>> {
    let part = calc_max_write_chunk(mtu);
    payload.chunks(part.max(1)).map(<[u8]>::to_vec).collect()
}

/// Maximum ATT payload per write: `min(512, max(23, mtu) - 3)`.
#[must_use]
pub const fn calc_max_write_chunk(mtu: u16) -> usize {
    let m = if mtu < 23 { 23 } else { mtu };
    let payload = m - 3;
    #[allow(clippy::cast_lossless)]
    {
        let p = payload as usize;
        if p > 512 { 512 } else { p }
    }
}

/// Parses a capabilities response into `(version, chunk_size)`.
///
/// # Errors
/// Malformed payload.
pub fn parse_capabilities(payload: &[u8]) -> Result<(FileTransferVersion, usize), String> {
    if payload.first() != Some(&CMD_CAPABILITIES_RESPONSE) {
        return Err(format!(
            "unexpected capabilities payload: {:02x?}",
            payload.first()
        ));
    }
    let version = *payload
        .get(1)
        .ok_or_else(|| "capabilities missing version".to_string())?;
    let chunk_size = u16::from_le_bytes(
        payload
            .get(2..4)
            .ok_or_else(|| "capabilities missing chunk size".to_string())?
            .try_into()
            .unwrap_or([0, 0]),
    ) as usize;
    if chunk_size == 0 {
        return Err("watch reported a zero chunk size".to_string());
    }
    let v = match version {
        1 | 2 => FileTransferVersion::V2,
        3 => FileTransferVersion::V3,
        other => return Err(format!("unsupported file transfer version {other}")),
    };
    Ok((v, chunk_size))
}

/// Convenience wrapper used by the driver for the initial request payload.
#[must_use]
pub fn capabilities_request() -> Vec<u8> {
    vec![CMD_CAPABILITIES_REQUEST]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session_v3() -> FileTransfer {
        let mut ft = FileTransfer::new(
            ROUTE_SEND_URL.to_string(),
            "track_1.dat".to_string(),
            vec![0xAB; 1000],
        );
        ft.on_capabilities(&[
            CMD_CAPABILITIES_RESPONSE,
            3,
            0xFC,
            0x01, // chunk size 508
        ])
        .expect("caps");
        ft
    }

    #[test]
    fn capabilities_parsing() {
        let mut ft = FileTransfer::new("u".into(), "f".into(), vec![1]);
        ft.on_capabilities(&[0x02, 2, 0x14, 0x00]).expect("v2 caps");
        assert_eq!(ft.version, Some(FileTransferVersion::V2));
        assert_eq!(ft.chunk_size, 20);

        let mut ft3 = FileTransfer::new("u".into(), "f".into(), vec![1]);
        ft3.on_capabilities(&[0x02, 3, 0xFC, 0x01])
            .expect("v3 caps");
        assert_eq!(ft3.version, Some(FileTransferVersion::V3));

        assert!(ft3.on_capabilities(&[0x02, 9, 0x14, 0x00]).is_err());
        assert!(parse_capabilities(&[0x02, 3, 0, 0]).is_err());
    }

    #[test]
    fn transfer_request_layout_v3() {
        let mut ft = session_v3();
        let req = ft.transfer_request().expect("request");
        eprintln!(
            "REQ: {}",
            req.iter().map(|b| format!("{b:02x}")).collect::<String>()
        );
        assert_eq!(req[0], 0x03);
        assert_eq!(req[1], 1); // session
        assert!(req[2..].starts_with(b"sport://file_transfer?appId=7073283073&params={}\0"));
        assert_eq!(req[2 + 48], 0); // null terminator after the URL
        let filename_off = 2 + 48 + 1;
        assert!(req[filename_off..].starts_with(b"track_1.dat\0"));
        let tail = &req[filename_off + 12..];
        assert_eq!(&tail[0..4], &1000u32.to_le_bytes()); // raw len
        assert_eq!(&tail[4..8], &crc32fast::hash(&[0xAB; 1000]).to_le_bytes());
        assert_eq!(tail[8], 0); // uncompressed
        assert_eq!(tail[9], 0); // trailing zero
    }

    #[test]
    fn v3_upload_chunks_and_acks() {
        let mut ft = session_v3();
        let _req = ft.transfer_request().expect("request");

        // Watch accepts the transfer (no resume).
        let step = ft
            .on_transfer_response(&[0x04, ft.session, 0, 0, 0, 0, 0], 247)
            .expect("step");
        let FileSendStep::Write {
            endpoint,
            frames,
            char_0x23,
        } = &step
        else {
            panic!("expected write");
        };
        assert_eq!(*endpoint, 0);
        assert!(*char_0x23);
        // 1000 bytes at MTU 247 → part size 244; chunk size 508 → 2 frames
        // (244 + 264 payload split → 3 parts? assert exact split instead).
        assert!(frames.len() >= 2);
        assert_eq!(frames[0][0], CMD_DATA_V3_SEND);
        assert_eq!(frames[0][1] & FLAG_FIRST_CHUNK, FLAG_FIRST_CHUNK);

        // Ack chunk 0 → next chunk frames until done.
        let mut acks = 0u8;
        loop {
            let index = ft.chunk_index.wrapping_sub(1);
            let step = ft
                .on_data_ack(&[CMD_DATA_V3_ACK, 0, index, 1], 247)
                .expect("ack step");
            acks += 1;
            match step {
                FileSendStep::Write {
                    frames, char_0x23, ..
                } => {
                    // Only the first split frame carries the command byte.
                    assert!(char_0x23);
                    assert_eq!(frames[0][0], CMD_DATA_V3_SEND);
                }
                FileSendStep::Done => break,
            }
        }
        assert!(acks >= 2, "1000 bytes / 508 needs at least 2 chunks");
        assert_eq!(ft.offset, ft.data.len());
    }

    #[test]
    fn v3_rejects_bad_ack_status_and_wrong_index() {
        let mut ft = session_v3();
        let _ = ft.transfer_request().expect("request");
        ft.on_transfer_response(&[0x04, ft.session, 0, 0, 0, 0, 0], 247)
            .expect("first chunk");

        assert!(ft.on_data_ack(&[0x13, 7, 0, 1], 247).is_err());
        assert!(ft.on_data_ack(&[0x13, 0, 5, 1], 247).is_err());
    }

    #[test]
    fn v3_transfer_response_dedup_completes_without_sending() {
        let mut ft = session_v3();
        let _ = ft.transfer_request().expect("request");
        // Watch reports the whole file already present (dedup by CRC).
        let full = (ft.data.len() as u32).to_le_bytes();
        let mut resp = vec![0x04, ft.session, 0];
        resp.extend_from_slice(&full);
        assert_eq!(ft.on_transfer_response(&resp, 247), Ok(FileSendStep::Done));
    }

    #[test]
    fn transfer_response_rejection_and_resume() {
        let mut ft = session_v3();
        let _ = ft.transfer_request().expect("request");
        // status 0x25 → rejected
        assert!(
            ft.on_transfer_response(&[0x04, ft.session, 0x25, 0, 0, 0, 0], 247)
                .is_err()
        );

        // Resume: watch reports 500 bytes already transferred.
        let resume_from = 500u32.to_le_bytes();
        let mut resp = vec![0x04, ft.session, 0];
        resp.extend_from_slice(&resume_from);
        let step = ft.on_transfer_response(&resp, 247).expect("resume step");
        let FileSendStep::Write { frames, .. } = &step else {
            panic!("expected write");
        };
        // First data chunk carries no FIRST flag (resume mid-file).
        assert_eq!(frames[0][1] & FLAG_FIRST_CHUNK, 0);
        assert!(ft.offset >= 500);
    }

    #[test]
    fn v2_data_rides_the_chunked_endpoint() {
        let mut ft = FileTransfer::new("u".into(), "f".into(), vec![7; 30]);
        ft.on_capabilities(&[0x02, 2, 0x14, 0x00]).expect("caps"); // chunk 20
        let _ = ft.transfer_request().expect("request");
        let step = ft
            .on_transfer_response(&[0x04, ft.session, 0, 0, 0, 0, 0], 247)
            .expect("step");
        let FileSendStep::Write {
            endpoint,
            frames,
            char_0x23,
        } = &step
        else {
            panic!("expected write");
        };
        assert_eq!(*endpoint, FILE_TRANSFER_ENDPOINT);
        assert!(!*char_0x23);
        assert_eq!(frames[0][0], CMD_DATA_SEND);
        assert_eq!(frames[0][2], ft.session);
        assert_eq!(frames[0][1] & FLAG_FIRST_CHUNK, FLAG_FIRST_CHUNK);
    }
}
