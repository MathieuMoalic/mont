// Parser for Huami2021 sports-summary protobuf messages.
//
// The raw bytes received on characteristic 0x0005 have:
//   - 1-byte sequence prefix per BLE notification
//   - 2-byte custom header [0x00, 0x80] at the start of the assembled data
//   - protobuf message starting at byte 2
//
// Protobuf layout (version "2.1"):
//   field 1  (string)  : version, e.g. "2.1"
//   field 2  (message) : start info
//     field 1 (varint) : start_timestamp (Unix seconds, UTC)
//     field 3 (varint) : sport_type (8 = outdoor running on Cheetah Pro)
//     field 13(varint) : duration_minutes
//   field 19 (message) : heart-rate stats
//     field 1 (varint) : avg_hr
//     field 2 (varint) : max_hr
//   field 40 (message) : distance / step data
//     field 3 (varint) : total_distance in 0.1 m units

import 'dart:typed_data';

const int _sportTypeOutdoorRunning = 8;

class SportsSummary {
  const SportsSummary({
    required this.startTime,
    required this.durationSeconds,
    required this.distanceMeters,
    this.avgHr,
    this.maxHr,
  });

  final DateTime startTime;       // UTC
  final int durationSeconds;
  final double distanceMeters;
  final int? avgHr;
  final int? maxHr;
}

/// Assemble and parse a single sports-summary protobuf from BLE data chunks.
///
/// Each chunk starts with a 1-byte sequence counter that must be stripped.
/// Returns null if the data is too short, malformed, or is not an outdoor run.
SportsSummary? parseSportsSummary(List<List<int>> chunks) {
  if (chunks.isEmpty) return null;

  // Strip the 1-byte seq prefix from every chunk, then concatenate.
  final assembled = <int>[];
  for (final chunk in chunks) {
    if (chunk.length < 2) continue; // skip degenerate chunks
    assembled.addAll(chunk.skip(1)); // drop seq byte
  }

  // First 2 bytes are a custom header [0x00, 0x80] — skip them.
  if (assembled.length < 3) return null;
  final proto = Uint8List.fromList(assembled.skip(2).toList());

  // Decode the top-level protobuf.
  final top = _decodeMessage(proto, 0, proto.length);

  // field 2: start-info sub-message
  final field2Bytes = top[2]?.firstOrNull;
  if (field2Bytes == null) return null;
  final startInfo = _decodeMessage(Uint8List.fromList(field2Bytes), 0, field2Bytes.length);

  // sport_type must be outdoor running.
  final sportType = startInfo[3]?.firstOrNull;
  if (sportType == null || sportType != _sportTypeOutdoorRunning) return null;

  // start timestamp
  final tsRaw = startInfo[1]?.firstOrNull;
  if (tsRaw == null) return null;
  final startTime = DateTime.fromMillisecondsSinceEpoch(tsRaw * 1000, isUtc: true);

  // duration in minutes → seconds
  final durationMin = startInfo[13]?.firstOrNull ?? 0;
  final durationSeconds = durationMin * 60;

  // field 40: totals sub-message — field 3 = total distance in 0.1 m units
  double distanceMeters = 0;
  final field40Bytes = top[40]?.firstOrNull;
  if (field40Bytes != null) {
    final totals = _decodeMessage(Uint8List.fromList(field40Bytes), 0, field40Bytes.length);
    final distRaw = totals[3]?.firstOrNull ?? 0;
    distanceMeters = distRaw * 0.1;
  }

  // field 19: HR sub-message
  int? avgHr;
  int? maxHr;
  final field19Bytes = top[19]?.firstOrNull;
  if (field19Bytes != null) {
    final hr = _decodeMessage(Uint8List.fromList(field19Bytes), 0, field19Bytes.length);
    avgHr = hr[1]?.firstOrNull;
    maxHr = hr[2]?.firstOrNull;
  }

  return SportsSummary(
    startTime: startTime,
    durationSeconds: durationSeconds,
    distanceMeters: distanceMeters,
    avgHr: avgHr,
    maxHr: maxHr,
  );
}

// ── Minimal protobuf decoder ──────────────────────────────────────────────────

// Decodes a protobuf message from [data[start..start+len]] into a map of
// field_number → list of values.
//   - varint fields: list of int
//   - LEN fields:    list of List<int> (raw bytes)
// We unify both into Map<int, List<dynamic>> where:
//   varint → int stored in the list
//   LEN    → List<int> stored in the list
Map<int, List<dynamic>> _decodeMessage(Uint8List data, int start, int len) {
  final result = <int, List<dynamic>>{};
  var pos = start;
  final end = start + len;

  void add(int field, dynamic value) =>
      (result[field] ??= []).add(value);

  while (pos < end) {
    // Read field tag (varint).
    final (int tag, int tagLen) = _readVarint(data, pos);
    if (tagLen == 0) break;
    pos += tagLen;

    final fieldNumber = tag >> 3;
    final wireType = tag & 0x07;

    switch (wireType) {
      case 0: // varint
        final (int val, int vLen) = _readVarint(data, pos);
        pos += vLen;
        add(fieldNumber, val);
      case 2: // length-delimited
        final (int msgLen, int lLen) = _readVarint(data, pos);
        pos += lLen;
        if (pos + msgLen > end) break;
        add(fieldNumber, data.sublist(pos, pos + msgLen).toList());
        pos += msgLen;
      case 1: // 64-bit — skip
        pos += 8;
      case 5: // 32-bit — skip
        pos += 4;
      default:
        // Unknown wire type — stop parsing this message.
        pos = end;
    }
  }

  return result;
}

/// Reads a protobuf varint from [data] at [offset].
/// Returns (value, bytes_consumed). bytes_consumed == 0 signals EOF.
(int, int) _readVarint(Uint8List data, int offset) {
  int result = 0;
  int shift = 0;
  int i = offset;

  while (i < data.length) {
    final b = data[i++];
    result |= (b & 0x7F) << shift;
    if (b & 0x80 == 0) return (result, i - offset);
    shift += 7;
    if (shift >= 63) break; // guard against malformed input
  }

  return (0, 0);
}
