// Amazfit/ZeppOS AES-128-ECB auth handshake (auth characteristic 0x0001).
//
// Protocol (Huami 2021 / ZeppOS 3.x):
//  1. Write buildAuthRequest() → [0x01, 0x00, 0x02, 0x00]
//  2. Watch responds [0x10, 0x01, 0x03, 0x05] = "send me the encrypted key"
//  3. Phone sends [0x03, 0x00, AES-ECB(deviceKey, zeros16)] (encrypt 16 zero bytes)
//  4. Watch responds [0x10, 0x03, 0x05] = success (ZeppOS 3.x) or [0x10, 0x01, 0x01, 0x00] (legacy)

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Encrypt [data] with AES-128-ECB using [key].
Uint8List aesEcbEncrypt(Uint8List key, Uint8List data) {
  final ECBBlockCipher cipher = ECBBlockCipher(AESEngine());
  cipher.init(true, KeyParameter(key));
  final Uint8List out = Uint8List(data.length);
  for (int i = 0; i < data.length; i += 16) {
    cipher.processBlock(data, i, out, i);
  }
  return out;
}

/// Build the initial auth request written to the auth characteristic.
Uint8List buildAuthRequest() => Uint8List.fromList([0x01, 0x00, 0x02, 0x00]);

/// Build the auth response payload.
///
/// If the watch provided a [nonce], encrypt it. Otherwise encrypt 16 zero bytes
/// with [deviceKey] (ZeppOS 3.x "no nonce" path).
Uint8List buildAuthResponsePayload(Uint8List? nonce, Uint8List deviceKey) {
  final Uint8List plaintext = nonce ?? Uint8List(16);
  final Uint8List encrypted = aesEcbEncrypt(deviceKey, plaintext);
  final Uint8List payload = Uint8List(18);
  payload[0] = 0x03;
  payload[1] = 0x00;
  payload.setRange(2, 18, encrypted);
  return payload;
}

/// Returns true if [notification] is the final successful auth acknowledgment.
/// Accepts both legacy [10 01 01 00] and ZeppOS 3.x [10 03 05].
bool isAuthSuccess(Uint8List notification) {
  if (notification.length < 3) return false;
  if (notification[0] != 0x10) return false;
  // Legacy: [10 01 01 00]
  if (notification[1] == 0x01 && notification[2] == 0x01) return true;
  // ZeppOS 3.x: [10 03 05] — response to our 03 00 key send
  if (notification[1] == 0x03 && notification[2] == 0x05) return true;
  return false;
}

/// Returns true if the watch is requesting we send the encrypted key.
bool isAuthSendKeyRequest(Uint8List notification) {
  return notification.length >= 3 &&
      notification[0] == 0x10 &&
      notification[1] == 0x01 &&
      notification[2] == 0x03;
}

/// Parse a 16-byte nonce from an auth characteristic notification.
///
/// The watch sends [0x10, 0x00, 0x01, 0x00, ...16 bytes nonce] on older firmware.
Uint8List? parseAuthNonce(Uint8List notification) {
  if (notification.length < 20) return null;
  if (notification[0] != 0x10 || notification[1] != 0x00) return null;
  return notification.sublist(4, 20);
}
