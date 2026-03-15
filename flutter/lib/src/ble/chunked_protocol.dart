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
// Packet format on 0x0016/0x0017 (10-byte header, little-endian):
//   byte  0    : 0x03 (type, always)
//   byte  1    : 0x07 (flags for request) / 0x03 (for response)
//   byte  2    : 0x00 (encryption = none)
//   byte  3    : seq  (uint8, per-connection counter, wraps at 0xff)
//   bytes 4–5  : payload_len (uint16 LE)
//   bytes 6–7  : 0x00 0x00 (reserved)
//   bytes 8–9  : endpoint (uint16 LE)
//   bytes 10+  : payload

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
  final header = ByteData(10);
  header.setUint8(0, 0x03);
  header.setUint8(1, 0x07); // request flag
  header.setUint8(2, 0x00); // no encryption
  header.setUint8(3, seq & 0xff);
  header.setUint16(4, payload.length, Endian.little);
  header.setUint16(6, 0, Endian.little);
  header.setUint16(8, endpoint, Endian.little);
  final result = Uint8List(10 + payload.length);
  result.setRange(0, 10, header.buffer.asUint8List());
  result.setRange(10, result.length, payload);
  return result;
}

/// Decode a Huami2021 response packet from characteristic 0x0017.
///
/// Returns `(endpoint, payload)`.
(int, Uint8List) decodeHuami2021(Uint8List packet) {
  if (packet.length < 10) {
    throw FormatException('Huami2021 packet too short: ${packet.length} bytes');
  }
  final bd = ByteData.sublistView(packet);
  final payloadLen = bd.getUint16(4, Endian.little);
  final endpoint = bd.getUint16(8, Endian.little);
  final end = 10 + payloadLen;
  if (end > packet.length) {
    throw FormatException('Huami2021 payload length $payloadLen exceeds packet size ${packet.length}');
  }
  return (endpoint, packet.sublist(10, end));
}
