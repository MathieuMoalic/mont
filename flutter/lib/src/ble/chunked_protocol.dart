// Amazfit / ZeppOS (Huami 2021) BLE protocol constants and codec.
//
// Verified from Gadgetbridge logcat while syncing Amazfit Cheetah Pro (ZeppOS 3.x).
//
// BLE service:       0000fee0-0000-1000-8000-00805f9b34fb
// Command write:     00000016-0000-3512-2118-0009af100700  (writeWithoutResponse)
// Command notify:    00000017-0000-3512-2118-0009af100700  (notify — command responses)
// Data stream:       00000005-0000-3512-2118-0009af100700  (notify — raw activity bytes)
// Auth char:         00000001-0000-3512-2118-0009af100700
//
// Packet format on 0x0016/0x0017 (11-byte header, mixed endian):
//   byte  0    : 0x03 (type, always)
//   byte  1    : 0x07 (flags for request) / 0x03 (for response)
//   byte  2    : 0x00 (encryption = none)
//   byte  3    : seq  (uint8, per-connection counter, wraps at 0xff)
//   bytes 4–5  : payload_len (uint16 BIG-ENDIAN)
//   bytes 6–7  : 0x00 0x00 (reserved)
//   byte  8    : 0x00 (reserved)
//   bytes 9–10 : endpoint (uint16 LE)
//   bytes 11+  : payload

import 'dart:typed_data';

class BleUuids {
  BleUuids._();

  static const String service = '0000fee0-0000-1000-8000-00805f9b34fb';
  // Chunked command channel — verified from Gadgetbridge logcat (0x0016/0x0017).
  static const String chunkedWrite = '00000016-0000-3512-2118-0009af100700';
  static const String chunkedNotify = '00000017-0000-3512-2118-0009af100700';
  // Raw actigraphy / workout data stream.
  static const String dataStream = '00000005-0000-3512-2118-0009af100700';
  static const String auth = '00000001-0000-3512-2118-0009af100700';
}

class BleEndpoints {
  BleEndpoints._();

  // Endpoint 0x004B handles all data fetch operations (ACTIVITY, SPORTS_SUMMARIES,
  // STRESS, etc.). The data type is specified in the payload, not the endpoint.
  static const int huamiData = 0x004B;
}

/// Encode a single Huami2021 command packet for [endpoint] with [seq] counter.
///
/// All our requests fit in a single BLE packet (small payloads), so no
/// multi-packet fragmentation is needed.
Uint8List encodeHuami2021(int endpoint, int seq, Uint8List payload) {
  // 11-byte header (verified from Gadgetbridge logcat):
  //   [0x03, 0x07, 0x00, seq, len_hi, len_lo, 0x00, 0x00, 0x00, ep_lo, ep_hi, payload…]
  // Note: payload length is big-endian at bytes 4-5; endpoint is LE at bytes 9-10.
  final header = ByteData(11);
  header.setUint8(0, 0x03);
  header.setUint8(1, 0x07); // request flag
  header.setUint8(2, 0x00); // no encryption
  header.setUint8(3, seq & 0xff);
  header.setUint16(4, payload.length, Endian.big); // big-endian length
  header.setUint16(6, 0, Endian.little);
  header.setUint8(8, 0x00); // extra reserved byte
  header.setUint16(9, endpoint, Endian.little);
  final result = Uint8List(11 + payload.length);
  result.setRange(0, 11, header.buffer.asUint8List());
  result.setRange(11, result.length, payload);
  return result;
}

/// Decode a Huami2021 response packet from characteristic 0x0017.
///
/// Returns `(endpoint, payload)`.
(int, Uint8List) decodeHuami2021(Uint8List packet) {
  if (packet.length < 11) {
    throw FormatException('Huami2021 packet too short: ${packet.length} bytes');
  }
  final bd = ByteData.sublistView(packet);
  final payloadLen = bd.getUint16(4, Endian.big); // big-endian length
  final endpoint = bd.getUint16(9, Endian.little); // LE endpoint
  final end = 11 + payloadLen;
  if (end > packet.length) {
    throw FormatException('Huami2021 payload length $payloadLen exceeds packet size ${packet.length}');
  }
  return (endpoint, packet.sublist(11, end));
}
