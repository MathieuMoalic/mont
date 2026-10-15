//! One-off experiment: verify that after the legacy auth handshake the
//! watch's encrypted chunked frames decrypt with `sessionKey = authkey` and
//! per-message `messageKey[i] = sessionKey[i] ^ handle`, validated by the
//! embedded CRC32 (Gadgetbridge framing).
//!
//! Reads the newest `ble_sessions/*.ndjson` recording and `backend/.env`.
//! Skips silently when either is missing (e.g. CI).

use std::path::PathBuf;

use aes::Aes128;
use aes::cipher::{BlockDecrypt, KeyInit, generic_array::GenericArray};
use base64::Engine as _;
use serde_json::Value;

fn auth_key_from_env() -> Option<String> {
    let env = std::fs::read_to_string("../backend/.env").ok()?;
    env.lines()
        .find_map(|l| l.strip_prefix("MONT_BLE_AUTH_KEY="))
        .map(str::to_string)
}

fn newest_session() -> Option<PathBuf> {
    let mut files: Vec<_> = std::fs::read_dir("../backend/ble_sessions")
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "ndjson"))
        .collect();
    files.sort_by_key(|p| std::fs::metadata(p).ok().and_then(|m| m.modified().ok()));
    files.pop()
}

/// Reassemble one chunked message from raw frames; returns
/// (endpoint, handle, plaintext_len, ciphertext).
fn assemble(frames: &[Vec<u8>]) -> Option<(u16, u8, usize, Vec<u8>)> {
    let first = frames.first()?;
    if first[1] & 0x01 == 0 {
        return None;
    }
    let handle = first[3];
    let plaintext_len = u32::from_le_bytes([first[5], first[6], first[7], first[8]]) as usize;
    let endpoint = u16::from_le_bytes([first[9], first[10]]);
    let mut ct = first[11..].to_vec();
    for f in frames.iter().skip(1) {
        ct.extend_from_slice(&f[5..]);
    }
    Some((endpoint, handle, plaintext_len, ct))
}

#[tokio::test]
async fn legacy_session_key_decrypts_watch_frames() {
    let Some(key_hex) = auth_key_from_env() else {
        eprintln!("skipping: no backend/.env auth key");
        return;
    };
    let Some(session) = newest_session() else {
        eprintln!("skipping: no session recordings");
        return;
    };
    let key_hex = key_hex
        .trim()
        .strip_prefix("0x")
        .unwrap_or(key_hex.trim())
        .to_string();
    let mut key = [0u8; 16];
    for (i, b) in key.iter_mut().enumerate() {
        *b = u8::from_str_radix(&key_hex[i * 2..i * 2 + 2], 16).expect("hex key");
    }

    let content = std::fs::read_to_string(&session).unwrap();
    let mut encrypted = 0usize;
    let mut validated = 0usize;
    // frames grouped by handle for multi-chunk reassembly
    let mut pending: std::collections::HashMap<u8, Vec<Vec<u8>>> = Default::default();

    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v["dir"] != "c2s" {
            continue;
        }
        let Some(items) = v["data"]["items"].as_array() else {
            continue;
        };
        for item in items {
            let Some(uuid) = item["char_uuid"].as_str() else {
                continue;
            };
            if !uuid.starts_with("00000016-") && !uuid.starts_with("00000017-") {
                continue;
            }
            let Ok(raw) = base64::engine::general_purpose::STANDARD
                .decode(item["data"].as_str().unwrap_or(""))
            else {
                continue;
            };
            if raw.first() != Some(&0x03) {
                continue;
            }
            let flags = raw[1];
            if flags & 0x08 == 0 {
                continue; // plaintext frame
            }
            let handle = raw[3];
            let entry = pending.entry(handle).or_default();
            entry.push(raw);
            if flags & 0x02 == 0 {
                continue; // not last chunk yet
            }
            let frames = pending.remove(&handle).unwrap();
            let Some((_endpoint, handle, plaintext_len, ciphertext)) = assemble(&frames) else {
                continue;
            };
            encrypted += 1;

            // messageKey[i] = sessionKey[i] ^ handle; AES-128-ECB decrypt
            let mut message_key = key;
            for b in &mut message_key {
                *b ^= handle;
            }
            let cipher = Aes128::new(GenericArray::from_slice(&message_key));
            let mut buf = ciphertext.clone();
            for chunk in buf.chunks_exact_mut(16) {
                cipher.decrypt_block(GenericArray::from_mut_slice(chunk));
            }

            if buf.len() < plaintext_len + 8 {
                eprintln!("frame handle {handle:#04x}: decrypted buffer too short");
                continue;
            }
            let payload = &buf[..plaintext_len];
            let seq = &buf[plaintext_len..plaintext_len + 4];
            let crc_received = u32::from_le_bytes([
                buf[plaintext_len + 4],
                buf[plaintext_len + 5],
                buf[plaintext_len + 6],
                buf[plaintext_len + 7],
            ]);
            let mut crc_input = payload.to_vec();
            crc_input.extend_from_slice(seq);
            let crc_calc = crc32fast::hash(&crc_input);
            if crc_calc == crc_received {
                validated += 1;
                eprintln!(
                    "VALIDATED handle {handle:#04x} seq {} endpoint {:#06x} payload[0..12]={:02x?}",
                    u32::from_le_bytes([seq[0], seq[1], seq[2], seq[3]]),
                    u16::from_le_bytes([first_ep(&frames)[0], first_ep(&frames)[1]]),
                    &payload[..payload.len().min(12)]
                );
            } else {
                eprintln!(
                    "MISMATCH handle {handle:#04x}: crc calc {crc_calc:08x} != received {crc_received:08x}"
                );
            }
        }
    }

    eprintln!(
        "encrypted messages: {encrypted}, crc-validated with authkey-as-session-key: {validated}"
    );
}

fn first_ep(frames: &[Vec<u8>]) -> [u8; 2] {
    [frames[0][9], frames[0][10]]
}

/// Dump every relayed FEE0 frame in order (structure only) — debugging aid.
#[tokio::test]
async fn dump_frames() {
    let Some(session) = newest_session() else {
        eprintln!("skipping: no session recordings");
        return;
    };
    let content = std::fs::read_to_string(&session).unwrap();
    let mut n = 0usize;
    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let dir = v["dir"].as_str().unwrap_or("?").to_string();
        let ts = v["ts"].as_f64().unwrap_or(0.0);
        if let Some(items) = v["data"]["items"].as_array() {
            for item in items {
                let Some(uuid) = item["char_uuid"].as_str() else {
                    continue;
                };
                let Ok(raw) = base64::engine::general_purpose::STANDARD
                    .decode(item["data"].as_str().unwrap_or(""))
                else {
                    continue;
                };
                n += 1;
                if raw.first() == Some(&0x03) && raw.len() >= 11 {
                    let flags = raw[1];
                    let enc = if flags & 0x08 != 0 { "ENC" } else { "   " };
                    let first = if flags & 0x01 != 0 { "F" } else { "." };
                    let last = if flags & 0x02 != 0 { "L" } else { "." };
                    let nack = if flags & 0x04 != 0 { "A" } else { "." };
                    let len = u32::from_le_bytes([raw[5], raw[6], raw[7], raw[8]]);
                    let ep = u16::from_le_bytes([raw[9], raw[10]]);
                    eprintln!(
                        "{n:3} {ts:.2} {dir} char={} {enc} {first}{last}{nack} h={:#04x} c={} len={len} ep={ep:#06x} body={:02x?}",
                        &uuid[4..8],
                        raw[3],
                        raw[4],
                        &raw[11..raw.len().min(24)]
                    );
                } else {
                    eprintln!(
                        "{n:3} {ts:.2} {dir} char={} raw={:02x?}",
                        &uuid[4..8],
                        &raw[..raw.len().min(24)]
                    );
                }
            }
        } else if let Some(data) = v["data"]["data"].as_str() {
            // s2c write command
            let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(data) else {
                continue;
            };
            let uuid = v["data"]["char_uuid"].as_str().unwrap_or("?");
            let k = v["data"]["k"].as_str().unwrap_or("?");
            n += 1;
            eprintln!(
                "{n:3} {ts:.2} {dir} char={} {k} raw={:02x?}",
                &uuid[4..uuid.len().min(12)],
                &raw[..raw.len().min(24)]
            );
        }
    }
}
