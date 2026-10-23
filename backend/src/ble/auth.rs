//! Legacy Huami authentication handshake over GATT characteristic `0x0001`.
//!
//! Uses `AES-128-ECB` with no session encryption — the variant proven to work
//! against this Amazfit Cheetah Pro by the `ble-health-import` branch.
//!
//! Handshake:
//! 1. phone → `01 00 02 00`
//! 2. watch → `10 01 03 05` (`ZeppOS 3.x`: "send the encrypted key") or
//!    `10 00 01 00 || 16-byte nonce` (legacy firmware)
//! 3. phone → `03 00 || AES-128-ECB(key, block)` where block is 16 zero bytes
//!    (`ZeppOS 3.x`) or the received nonce (legacy)
//! 4. watch → `10 03 05` (`ZeppOS 3.x`) or `10 01 01 00` (legacy) = success;
//!    status byte `0x02` (or `0x25`) at index 2 = wrong key.

use aes::Aes128;
use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit, generic_array::GenericArray};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthState {
    AwaitingChallenge,
    KeySent,
    Authenticated,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthOutcome {
    /// Handshake finished successfully.
    Authenticated,
    /// Send this payload to the auth characteristic to continue.
    Reply(Vec<u8>),
    /// Watch reported the key is wrong (or an unexpected response).
    Failure(&'static str),
}

/// Encrypt one 16-byte block with AES-128-ECB/NoPadding.
#[must_use]
pub fn aes_ecb_block(key: &[u8; 16], block: &[u8; 16]) -> [u8; 16] {
    let cipher = Aes128::new(GenericArray::from_slice(key));
    let mut out = *GenericArray::from_slice(block);
    cipher.encrypt_block(&mut out);
    out.into()
}

/// Decrypt one 16-byte block with AES-128-ECB/NoPadding.
#[must_use]
pub fn aes_ecb_decrypt(key: &[u8; 16], block: &[u8; 16]) -> [u8; 16] {
    let cipher = Aes128::new(GenericArray::from_slice(key));
    let mut out = *GenericArray::from_slice(block);
    cipher.decrypt_block(&mut out);
    out.into()
}

/// Stateless handshake driver; owns only the progress state.
#[derive(Debug)]
pub struct AuthSession {
    state: AuthState,
}

impl Default for AuthSession {
    fn default() -> Self {
        Self::new()
    }
}

impl AuthSession {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: AuthState::AwaitingChallenge,
        }
    }

    #[must_use]
    pub const fn state(&self) -> AuthState {
        self.state
    }

    /// The first payload to write to the auth characteristic.
    #[must_use]
    pub fn start_request() -> Vec<u8> {
        vec![0x01, 0x00, 0x02, 0x00]
    }

    /// Feed one notification from the auth characteristic.
    /// Returns what the driver should do next.
    pub fn on_response(&mut self, resp: &[u8], key: &[u8; 16]) -> AuthOutcome {
        if resp.len() < 3 {
            self.state = AuthState::Failed;
            return AuthOutcome::Failure("short auth response");
        }

        // Success markers (both firmware variants, in any state).
        if resp == [0x10, 0x03, 0x05] || resp == [0x10, 0x01, 0x01, 0x00] {
            self.state = AuthState::Authenticated;
            return AuthOutcome::Authenticated;
        }

        // Wrong key / rejection: status byte at index 2.
        if resp[2] == 0x02 || resp[2] == 0x25 {
            self.state = AuthState::Failed;
            return AuthOutcome::Failure("watch rejected the auth key");
        }

        if self.state != AuthState::AwaitingChallenge {
            self.state = AuthState::Failed;
            return AuthOutcome::Failure("unexpected auth response");
        }

        // `ZeppOS 3.x`: `10 01 03 05` — encrypt 16 zero bytes.
        if resp.len() >= 4 && resp[0] == 0x10 && resp[1] == 0x01 && resp[2] == 0x03 {
            let mut reply = vec![0x03, 0x00];
            reply.extend_from_slice(&aes_ecb_block(key, &[0u8; 16]));
            self.state = AuthState::KeySent;
            return AuthOutcome::Reply(reply);
        }
        // Legacy: `10 00 01 00 || nonce` — encrypt the nonce.
        if resp.len() >= 20 && resp[0] == 0x10 && resp[1] == 0x00 && resp[2] == 0x01 {
            let Ok(nonce) = <[u8; 16]>::try_from(&resp[4..20]) else {
                self.state = AuthState::Failed;
                return AuthOutcome::Failure("short auth response");
            };
            let mut reply = vec![0x03, 0x00];
            reply.extend_from_slice(&aes_ecb_block(key, &nonce));
            self.state = AuthState::KeySent;
            return AuthOutcome::Reply(reply);
        }
        self.state = AuthState::Failed;
        AuthOutcome::Failure("unexpected auth challenge")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // FIPS-197 Appendix C.1 known-answer vector.
    #[test]
    fn aes_block_fips197_vector() {
        let key = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f,
        ];
        let pt = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ];
        assert_eq!(
            aes_ecb_block(&key, &pt),
            [
                0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4,
                0xc5, 0x5a
            ]
        );
    }

    #[test]
    fn zeppos3_handshake_happy_path() {
        let key = [0x42u8; 16];
        let mut sess = AuthSession::new();
        assert_eq!(AuthSession::start_request(), vec![0x01, 0x00, 0x02, 0x00]);

        let outcome = sess.on_response(&[0x10, 0x01, 0x03, 0x05], &key);
        let AuthOutcome::Reply(reply) = outcome else {
            panic!("expected reply");
        };
        assert_eq!(reply[0], 0x03);
        assert_eq!(reply[1], 0x00);
        assert_eq!(reply.len(), 18);
        assert_eq!(&reply[2..], &aes_ecb_block(&key, &[0u8; 16])[..]);
        assert_eq!(sess.state(), AuthState::KeySent);

        assert_eq!(
            sess.on_response(&[0x10, 0x03, 0x05], &key),
            AuthOutcome::Authenticated
        );
        assert_eq!(sess.state(), AuthState::Authenticated);
    }

    #[test]
    fn legacy_nonce_handshake() {
        let key = [0x07u8; 16];
        let nonce = [0x5Au8; 16];
        let mut sess = AuthSession::new();

        let mut resp = vec![0x10, 0x00, 0x01, 0x00];
        resp.extend_from_slice(&nonce);
        let AuthOutcome::Reply(reply) = sess.on_response(&resp, &key) else {
            panic!("expected reply");
        };
        assert_eq!(&reply[2..], &aes_ecb_block(&key, &nonce)[..]);

        assert_eq!(
            sess.on_response(&[0x10, 0x01, 0x01, 0x00], &key),
            AuthOutcome::Authenticated
        );
    }

    #[test]
    fn already_authenticated_short_circuit() {
        let key = [0u8; 16];
        let mut sess = AuthSession::new();
        assert_eq!(
            sess.on_response(&[0x10, 0x01, 0x01, 0x00], &key),
            AuthOutcome::Authenticated
        );
    }

    #[test]
    fn wrong_key_is_failure() {
        let key = [0x01u8; 16];
        let mut sess = AuthSession::new();
        assert!(matches!(
            sess.on_response(&[0x10, 0x01, 0x03, 0x05], &key),
            AuthOutcome::Reply(_)
        ));
        assert_eq!(
            sess.on_response(&[0x10, 0x03, 0x02], &key),
            AuthOutcome::Failure("watch rejected the auth key")
        );
        assert_eq!(sess.state(), AuthState::Failed);

        // GB also reports 0x25 for wrong key.
        let mut sess2 = AuthSession::new();
        let mut nonce_resp = vec![0x10, 0x00, 0x01, 0x00];
        nonce_resp.extend_from_slice(&[0u8; 16]);
        let _ = sess2.on_response(&nonce_resp, &key);
        assert_eq!(
            sess2.on_response(&[0x10, 0x01, 0x25], &key),
            AuthOutcome::Failure("watch rejected the auth key")
        );
    }

    #[test]
    fn short_and_garbage_responses_fail() {
        let key = [0u8; 16];
        let mut sess = AuthSession::new();
        assert!(matches!(
            sess.on_response(&[0x10], &key),
            AuthOutcome::Failure(_)
        ));
        assert!(matches!(
            sess.on_response(&[0x99, 0x99, 0x99, 0x99], &key),
            AuthOutcome::Failure(_)
        ));
    }
}
