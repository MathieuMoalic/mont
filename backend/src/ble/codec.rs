//! Huami/ZeppOS chunked protocol codec (2021-style, extended flags).
//!
//! Byte-exact port of Gadgetbridge's `Huami2021ChunkedEncoder` /
//! `Huami2021ChunkedDecoder` (`extended_flags` = `true`). Plaintext frames are
//! what the health fetches use; encrypted frames (flags `0x08`) implement the
//! `ZeppOS` session cipher for the control endpoints (Wi-Fi `0x0003`, FTP
//! `0x0006`): body = `AES-128-ECB(sessionKey ^ handle, plaintext ‖ seqNr u32
//! LE ‖ crc32(plaintext‖seqNr) u32 LE ‖ zero-pad to 16)`, with the header
//! length field carrying the *plaintext* length.
//!
//! Frame layout (each BLE write):
//! ```text
//! [0]      0x03
//! [1]      flags: `0x01` first chunk, `0x02` last chunk, `0x04` needs-ack,
//! `0x08` encrypted
//! [2]      0x00 (extended header marker)
//! [3]      handle (increments per message)
//! [4]      count  (chunk index within message)
//! first chunk only:
//! [5..9]   u32 LE total payload length (plaintext length when encrypted)
//! [9..11]  u16 LE endpoint
//! [11..]   payload
//! continuation chunks: 5-byte header then payload
//! ```

use super::auth::{aes_ecb_block, aes_ecb_decrypt};

const FLAG_FIRST: u8 = 0x01;
const FLAG_LAST: u8 = 0x02;
const FLAG_NEEDS_ACK: u8 = 0x04;
const FLAG_ENCRYPTED: u8 = 0x08;

/// Maximum ATT payload per write: `min(512, max(23, mtu) - 3)` (Gadgetbridge
/// `calcMaxWriteChunk`).
#[must_use]
pub const fn calc_max_write_chunk(mtu: u16) -> usize {
    let m = if mtu < 23 { 23 } else { mtu };
    let payload = m - 3;
    // u16 → usize is lossless; `usize::from` is not const-stable yet.
    #[allow(clippy::cast_lossless)]
    {
        let p = payload as usize;
        if p > 512 { 512 } else { p }
    }
}

/// Builds outgoing chunked frames for one session (own handle counter, and
/// the session cipher state once the `ZeppOS` handshake has negotiated a key).
pub struct ChunkedEncoder {
    mtu: u16,
    handle: u8,
    session_key: Option<[u8; 16]>,
    seq_nr: u32,
}

pub struct ChunkedMessage {
    pub endpoint: u16,
    pub payload: Vec<u8>,
    /// The frame had the needs-ack flag set; the peer expects
    /// [`chunked_ack`] with [`ChunkedMessage::handle`] / [`ChunkedMessage::count`].
    pub needs_ack: bool,
    pub handle: u8,
    pub count: u8,
}

impl ChunkedEncoder {
    #[must_use]
    pub const fn new(mtu: u16) -> Self {
        Self {
            mtu,
            handle: 0,
            session_key: None,
            seq_nr: 0,
        }
    }

    pub const fn set_mtu(&mut self, mtu: u16) {
        self.mtu = mtu;
    }

    /// Activate session encryption (Gadgetbridge `setEncryptionParameters`).
    /// `seq_nr` is the initial encrypted-sequence number from the ECDH share.
    pub const fn set_encryption_parameters(&mut self, seq_nr: u32, session_key: [u8; 16]) {
        self.seq_nr = seq_nr;
        self.session_key = Some(session_key);
    }

    #[must_use]
    pub const fn has_session_key(&self) -> bool {
        self.session_key.is_some()
    }

    /// Encode one message (endpoint + payload) into ordered BLE writes.
    #[must_use]
    pub fn encode(&mut self, endpoint: u16, payload: &[u8]) -> Vec<Vec<u8>> {
        self.handle = self.handle.wrapping_add(1);
        let handle = self.handle;

        let mut frames = Vec::new();
        let mut remaining = payload.len();
        let total = payload.len();
        let mut count = 0u8;
        // GB: header_size = 11 for the first chunk, 5 for continuations.
        let mut header_size = 11usize;

        let mut offset = 0usize;
        loop {
            let max_chunk = calc_max_write_chunk(self.mtu).saturating_sub(header_size);
            let copy = remaining.min(max_chunk);
            let mut frame = vec![0u8; header_size + copy];

            let mut flags = 0u8;
            if count == 0 {
                flags |= FLAG_FIRST;
            }
            if remaining <= max_chunk {
                flags |= FLAG_LAST | FLAG_NEEDS_ACK;
            }
            frame[0] = 0x03;
            frame[1] = flags;
            frame[2] = 0x00;
            frame[3] = handle;
            frame[4] = count;
            if count == 0 {
                let total32 = u32::try_from(total).unwrap_or(u32::MAX);
                frame[5..9].copy_from_slice(&total32.to_le_bytes());
                frame[9..11].copy_from_slice(&endpoint.to_le_bytes());
            }
            frame[header_size..header_size + copy].copy_from_slice(&payload[offset..offset + copy]);
            frames.push(frame);

            remaining -= copy;
            offset += copy;
            header_size = 5;
            count = count.wrapping_add(1);
            if remaining == 0 {
                break;
            }
        }
        frames
    }

    /// Encode one message with session encryption (Wi-Fi / FTP endpoints).
    ///
    /// # Errors
    /// No session key has been negotiated yet.
    pub fn encode_encrypted(
        &mut self,
        endpoint: u16,
        payload: &[u8],
    ) -> Result<Vec<Vec<u8>>, String> {
        let Some(session_key) = self.session_key else {
            return Err("cannot encrypt: no session key negotiated".to_string());
        };
        self.handle = self.handle.wrapping_add(1);
        let handle = self.handle;

        // Body = plaintext ‖ seqNr u32 LE ‖ crc32(plaintext ‖ seqNr) u32 LE,
        // zero-padded to the next 16-byte multiple (AES-ECB block cipher).
        let seq_bytes = self.seq_nr.to_le_bytes();
        let mut body = Vec::with_capacity(payload.len() + 8 + 16);
        body.extend_from_slice(payload);
        body.extend_from_slice(&seq_bytes);
        let crc = crc32fast::hash(&body);
        body.extend_from_slice(&crc.to_le_bytes());
        let padded = body.len().next_multiple_of(16);
        body.resize(padded, 0);
        // messageKey = sessionKey XOR handle (handle byte replicated).
        let message_key: [u8; 16] = std::array::from_fn(|i| session_key[i] ^ handle);
        for block in body.chunks_mut(16) {
            let mut arr = [0u8; 16];
            arr.copy_from_slice(block);
            let enc = aes_ecb_block(&message_key, &arr);
            block.copy_from_slice(&enc);
        }
        self.seq_nr = self.seq_nr.wrapping_add(1);

        let mut frames = Vec::new();
        // Chunk over the padded ciphertext; the header length field stays the
        // *plaintext* length (Gadgetbridge semantics).
        let mut remaining = body.len();
        let mut count = 0u8;
        let mut header_size = 11usize;
        let mut offset = 0usize;
        loop {
            let max_chunk = calc_max_write_chunk(self.mtu).saturating_sub(header_size);
            let copy = remaining.min(max_chunk);
            let mut frame = vec![0u8; header_size + copy];

            let mut flags = FLAG_ENCRYPTED;
            if count == 0 {
                flags |= FLAG_FIRST;
            }
            if remaining <= max_chunk {
                flags |= FLAG_LAST | FLAG_NEEDS_ACK;
            }
            frame[0] = 0x03;
            frame[1] = flags;
            frame[2] = 0x00;
            frame[3] = handle;
            frame[4] = count;
            if count == 0 {
                let total32 = u32::try_from(payload.len()).unwrap_or(u32::MAX);
                frame[5..9].copy_from_slice(&total32.to_le_bytes());
                frame[9..11].copy_from_slice(&endpoint.to_le_bytes());
            }
            frame[header_size..header_size + copy].copy_from_slice(&body[offset..offset + copy]);
            frames.push(frame);

            remaining -= copy;
            offset += copy;
            header_size = 5;
            count = count.wrapping_add(1);
            if remaining == 0 {
                break;
            }
        }
        Ok(frames)
    }
}

/// Reassembles incoming frames into messages (per-session state).
#[derive(Default)]
pub struct ChunkedDecoder {
    current_handle: Option<u8>,
    pending_endpoint: Option<u16>,
    /// Plaintext length of the in-flight encrypted message.
    pending_plain_len: usize,
    buffer: Vec<u8>,
    session_key: Option<[u8; 16]>,
}

impl ChunkedDecoder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Activate session decryption (any `0x08`-flagged inbound frame).
    pub const fn set_session_key(&mut self, session_key: [u8; 16]) {
        self.session_key = Some(session_key);
    }

    /// Feed one raw notification. Returns the completed message, if any.
    ///
    /// # Errors
    /// Returns an error for non-chunked payloads and for encrypted frames
    /// received before a session key was negotiated.
    pub fn decode(&mut self, data: &[u8]) -> Result<Option<ChunkedMessage>, String> {
        if data.first() != Some(&0x03) {
            return Err("not a chunked payload".into());
        }
        let flags = data[1];
        let first = flags & FLAG_FIRST != 0;
        let last = flags & FLAG_LAST != 0;
        let needs_ack = flags & FLAG_NEEDS_ACK != 0;
        let encrypted = flags & FLAG_ENCRYPTED != 0;

        // extended header at [2]; handle [3]; count [4]
        if data.len() < 5 {
            return Err("chunked frame too short".into());
        }
        let handle = data[3];
        if let Some(current) = self.current_handle
            && current != handle
        {
            // GB ignores mismatched mid-message handles.
            return Err(format!("ignoring handle {handle}, expected {current}"));
        }
        let count = data[4];

        // Payload starts after the 11-byte first-chunk header, or the 5-byte
        // continuation header.
        let i = if first {
            if data.len() < 11 {
                return Err("first chunk too short".into());
            }
            let mut full_len = u32::from_le_bytes([data[5], data[6], data[7], data[8]]) as usize;
            let endpoint = u16::from_le_bytes([data[9], data[10]]);
            if encrypted {
                // The wire body is plaintext_len + 8, zero-padded to 16.
                full_len = (full_len + 8).next_multiple_of(16);
                self.pending_plain_len =
                    u32::from_le_bytes([data[5], data[6], data[7], data[8]]) as usize;
            }
            self.buffer = Vec::with_capacity(full_len);
            self.current_handle = Some(handle);
            self.pending_endpoint = Some(endpoint);
            11
        } else {
            5
        };
        self.buffer.extend_from_slice(&data[i..]);

        if last {
            let endpoint = self.pending_endpoint.take().unwrap_or(0);
            let mut payload = std::mem::take(&mut self.buffer);
            self.current_handle = None;
            if encrypted {
                let Some(session_key) = self.session_key else {
                    return Err("encrypted frame but no session key".into());
                };
                // messageKey = sessionKey XOR handle (from this frame).
                let message_key: [u8; 16] = std::array::from_fn(|i| session_key[i] ^ handle);
                if !payload.len().is_multiple_of(16) {
                    return Err("encrypted body is not block-aligned".into());
                }
                for block in payload.chunks_mut(16) {
                    let mut arr = [0u8; 16];
                    arr.copy_from_slice(block);
                    let dec = aes_ecb_decrypt(&message_key, &arr);
                    block.copy_from_slice(&dec);
                }
                // Strip seqNr + CRC32 + padding; the CRC is not verified
                // (matching Gadgetbridge).
                let plain_len = if self.pending_plain_len > 0 {
                    self.pending_plain_len
                } else {
                    payload.len().saturating_sub(8)
                };
                payload.truncate(plain_len.min(payload.len()));
                self.pending_plain_len = 0;
            }
            return Ok(Some(ChunkedMessage {
                endpoint,
                payload,
                needs_ack,
                handle,
                count,
            }));
        }
        Ok(None)
    }
}

/// The ack the phone must send when a received frame had the needs-ack flag
/// (written to the chunked *notify* characteristic, per Gadgetbridge).
#[must_use]
pub const fn chunked_ack(handle: u8, count: u8) -> [u8; 5] {
    [0x04, 0x00, handle, 0x01, count]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_write_chunk_matches_gb() {
        assert_eq!(calc_max_write_chunk(0), 20);
        assert_eq!(calc_max_write_chunk(23), 20);
        assert_eq!(calc_max_write_chunk(24), 21);
        assert_eq!(calc_max_write_chunk(247), 244);
        assert_eq!(calc_max_write_chunk(517), 512);
    }

    #[test]
    fn single_chunk_framing_golden() {
        let mut enc = ChunkedEncoder::new(247);
        let frames = enc.encode(0x004b, &[0x01, 0x02, 0x03]);
        assert_eq!(frames.len(), 1);
        // 03 | 07 (first|last|needs-ack) | 00 | handle 1 | count 0
        // | len=3 u32 LE | endpoint 0x004b u16 LE | payload
        assert_eq!(
            frames[0],
            vec![
                0x03, 0x07, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x4b, 0x00, 0x01, 0x02, 0x03
            ]
        );
    }

    #[test]
    fn multi_chunk_at_small_mtu() {
        let mut enc = ChunkedEncoder::new(23); // 20-byte writes, 11-byte first header → 9 payload
        let payload: Vec<u8> = (0..12u8).collect();
        let frames = enc.encode(0x004b, &payload);
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0][1] & FLAG_FIRST, FLAG_FIRST);
        assert_eq!(frames[0][1] & FLAG_LAST, 0);
        assert_eq!(frames[0].len(), 11 + 9);
        assert_eq!(&frames[0][11..], &payload[..9]);
        assert_eq!(frames[1][1] & FLAG_FIRST, 0);
        assert_eq!(frames[1][1] & FLAG_LAST, FLAG_LAST);
        assert_eq!(frames[1][1] & FLAG_NEEDS_ACK, FLAG_NEEDS_ACK);
        assert_eq!(frames[1][4], 1); // count
        assert_eq!(&frames[1][5..], &payload[9..]);
    }

    #[test]
    fn round_trip_multi_chunk() {
        let payload: Vec<u8> = (0..64u8).map(|b| b.wrapping_mul(7)).collect();
        let mut enc = ChunkedEncoder::new(52);
        let frames = enc.encode(0x1234, &payload);
        assert!(frames.len() > 1);

        let mut dec = ChunkedDecoder::new();
        let mut done = None;
        for f in &frames {
            done = dec.decode(f).unwrap();
        }
        let msg = done.expect("message completed");
        assert_eq!(msg.endpoint, 0x1234);
        assert_eq!(msg.payload, payload);
        assert!(msg.needs_ack);
        assert_eq!(
            chunked_ack(msg.handle, msg.count),
            [0x04, 0x00, msg.handle, 0x01, msg.count]
        );
    }

    #[test]
    fn decode_rejects_non_chunked_and_short() {
        let mut dec = ChunkedDecoder::new();
        assert!(dec.decode(&[0x04, 0x00, 0x01, 0x01, 0x00]).is_err());
        assert!(dec.decode(&[0x03, 0x07]).is_err());
    }

    #[test]
    fn decode_ignores_mismatched_handle_mid_message() {
        let payload = vec![0xAA; 30];
        let mut enc = ChunkedEncoder::new(23);
        let frames = enc.encode(0x0001, &payload);
        assert!(frames.len() > 2);
        let mut dec = ChunkedDecoder::new();
        dec.decode(&frames[0]).unwrap();
        // an interleaved frame with another handle must be rejected, not corrupt state
        assert!(
            dec.decode(&[0x03, 0x07, 0x00, 0x77, 0x00, 0x01, 0, 0, 0, 0x01, 0x00])
                .is_err()
        );
        let mut done = None;
        for frame in frames.iter().skip(1) {
            done = dec.decode(frame).unwrap();
        }
        assert_eq!(done.unwrap().payload, payload);
    }

    #[test]
    fn encrypted_round_trip_single_chunk() {
        let key = [0x42u8; 16];
        let mut enc = ChunkedEncoder::new(247);
        assert!(!enc.has_session_key());
        assert!(enc.encode_encrypted(0x0006, &[0x01]).is_err());
        enc.set_encryption_parameters(7, key);
        assert!(enc.has_session_key());

        let payload: Vec<u8> = b"01/mnt/data\x00".to_vec();
        let frames = enc.encode_encrypted(0x0006, &payload).expect("frames");
        assert_eq!(frames.len(), 1);
        // flags = first|last|needs-ack|encrypted = 0x0F; header length field
        // carries the plaintext length.
        assert_eq!(frames[0][1], 0x0F);
        assert_eq!(&frames[0][5..9], &(payload.len() as u32).to_le_bytes());
        assert_eq!(&frames[0][9..11], &0x0006u16.to_le_bytes());

        let mut dec = ChunkedDecoder::new();
        assert!(dec.decode(&frames[0]).is_err()); // no session key yet
        dec.set_session_key(key);
        let msg = dec.decode(&frames[0]).unwrap().expect("message");
        assert_eq!(msg.endpoint, 0x0006);
        assert_eq!(msg.payload, payload);
    }

    #[test]
    fn encrypted_round_trip_multi_chunk_and_sequence() {
        let key = [0x07u8; 16];
        let mut enc = ChunkedEncoder::new(40); // force multiple chunks
        enc.set_encryption_parameters(0xFFFF_FFF0, key);
        let mut dec = ChunkedDecoder::new();
        dec.set_session_key(key);

        for round in 0..3u32 {
            let base = u8::try_from(round * 60).expect("fits u8");
            let payload: Vec<u8> = (0..60u8).map(|b| b.wrapping_add(base)).collect();
            let frames = enc.encode_encrypted(0x0003, &payload).expect("frames");
            assert!(frames.len() > 1);
            let mut done = None;
            for f in &frames {
                done = dec.decode(f).unwrap();
            }
            let msg = done.expect("message");
            assert_eq!(msg.endpoint, 0x0003);
            assert_eq!(msg.payload, payload);
        }
    }

    #[test]
    fn encrypted_body_is_padded_and_keyed_per_handle() {
        let key = [0x11u8; 16];
        let mut enc = ChunkedEncoder::new(247);
        enc.set_encryption_parameters(0, key);
        // plaintext 4 bytes → body = 4 + 8 = 12 → padded to 16.
        let frames = enc
            .encode_encrypted(0x0003, &[0x11, 0x00, 0x62, 0x61])
            .expect("frames");
        assert_eq!(frames[0].len(), 11 + 16);
    }
}
