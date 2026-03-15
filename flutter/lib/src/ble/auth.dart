// Amazfit/ZeppOS AES-128-ECB auth handshake (auth characteristic 0x0009).
//
// Protocol:
//  1. Write buildAuthRequest() to auth characteristic to start
//  2. Watch notifies auth characteristic with 16-byte random nonce
//  3. Phone encrypts nonce with AES-128-ECB using the device secret key
//  4. Phone writes buildAuthResponsePayload(...) to auth characteristic
//  5. Watch notifies [0x10, 0x01, ...] on auth characteristic for success

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

/// Build the auth response payload from [nonce] and [deviceKey].
///
/// Write this directly to the auth characteristic (not via chunked channel).
Uint8List buildAuthResponsePayload(Uint8List nonce, Uint8List deviceKey) {
  final Uint8List encrypted = aesEcbEncrypt(deviceKey, nonce);
  final Uint8List payload = Uint8List(18);
  payload[0] = 0x03;
  payload[1] = 0x00;
  payload.setRange(2, 18, encrypted);
  return payload;
}

/// Returns true if [notification] is a successful auth acknowledgment.
bool isAuthSuccess(Uint8List notification) {
  return notification.length >= 2 &&
      notification[0] == 0x10 &&
      notification[1] == 0x01;
}

/// Parse a 16-byte nonce from an auth characteristic notification.
///
/// The watch sends [0x02, 0x00, ...16 bytes nonce] after the initial request.
Uint8List? parseAuthNonce(Uint8List notification) {
  if (notification.length < 18) return null;
  if (notification[0] != 0x02 || notification[1] != 0x00) return null;
  return notification.sublist(2, 18);
}
