// Amazfit/ZeppOS AES-128-ECB auth handshake (endpoint 0x0082).
//
// Protocol:
//  1. Write request  [0x01, 0x00, 0x02, 0x00] to auth characteristic to start
//  2. Watch replies with 16-byte random nonce
//  3. Phone encrypts nonce with AES-128-ECB using the device secret key
//  4. Phone sends encrypted response via chunked write on endpoint 0x0082
//  5. Watch replies with [0x10, 0x01, ...] on success

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'chunked_protocol.dart';

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

/// Build the initial auth request payload written to [BleUuids.auth].
Uint8List buildAuthRequest() => Uint8List.fromList([0x01, 0x00, 0x02, 0x00]);

/// Build the chunked auth-response packets from a nonce and device key.
///
/// [nonce] is the 16-byte challenge received from the watch.
/// [deviceKey] is the 16-byte secret obtained during pairing.
/// [seq] is the current sequence counter (usually 0 for first message).
List<Uint8List> buildAuthResponse(Uint8List nonce, Uint8List deviceKey, int seq) {
  final Uint8List encrypted = aesEcbEncrypt(deviceKey, nonce);
  // Auth response payload: [0x03, 0x00, ...16 encrypted bytes]
  final Uint8List payload = Uint8List(18);
  payload[0] = 0x03;
  payload[1] = 0x00;
  payload.setRange(2, 18, encrypted);
  return encodeChunked(BleEndpoints.authEndpoint, seq, payload);
}

/// Returns true if [response] is a successful auth acknowledgment.
bool isAuthSuccess(Uint8List response) {
  return response.length >= 2 && response[0] == 0x10 && response[1] == 0x01;
}
