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
//     field 3 (varint) : sport_type (8 = outdoor run on Cheetah Pro)
//     field 13(varint) : duration_minutes (rounded, use field7 for accuracy)
//   field 7  (message) : accurate duration
//     field 1 (varint) : moving_duration_seconds
//     field 2 (varint) : total_duration_seconds
//   field 11 (message) : speed / distance
//     field 1 (float)  : avg_speed (m/s)
//     field 2 (float)  : max_speed (m/s)
//     field 4 (varint) : total_distance (meters)
//   field 19 (message) : heart-rate stats
//     field 1 (varint) : avg_hr
//     field 2 (varint) : max_hr
//   field 40 (message) : totals (used as fallback for non-GPS runs)
//     field 3 (varint) : total_distance in 0.1 m units (non-GPS only)
//
// GPS detail protobuf layout (data type 0x06):
//   The GPS track data comes in the sports-detail response.
//   The exact field layout is device/firmware-specific.
//   All received data is logged as hex for debugging.
//   GPS points are extracted from sub-messages and validated by lat/lon range.
//   Lat/lon are stored as int32 × 1e-7 degrees (zigzag-encoded varints).

import 'dart:typed_data';

const int _sportTypeOutdoorRunning = 8;

class GpsPoint {
  const GpsPoint({
    required this.lat,
    required this.lon,
    this.ele,
    this.hr,
    this.t,
  });

  final double lat;   // degrees
  final double lon;   // degrees
  final double? ele;  // meters
  final int? hr;      // bpm
  final int? t;       // seconds since run start

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    if (ele != null) 'ele': ele,
    if (hr != null) 'hr': hr,
    if (t != null) 't': t,
  };
}

class SportsSummary {
  const SportsSummary({
    required this.startTime,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.sportType,
    this.avgHr,
    this.maxHr,
  });

  final DateTime startTime;       // UTC
  final int durationSeconds;
  final double distanceMeters;
  final int sportType;
  final int? avgHr;
  final int? maxHr;

  bool get isOutdoorRun => sportType == _sportTypeOutdoorRunning;
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

  // sport_type — always present, caller decides whether to keep
  final sportType = startInfo[3]?.firstOrNull ?? 0;

  // start timestamp
  final tsRaw = startInfo[1]?.firstOrNull;
  if (tsRaw == null) return null;
  final startTime = DateTime.fromMillisecondsSinceEpoch(tsRaw * 1000, isUtc: true);

  // duration in minutes (f13) — used as fallback if field7 absent
  final durationMin = startInfo[13]?.firstOrNull ?? 0;

  // field 7: accurate duration in seconds (f1=moving, f2=total)
  // Falls back to f13*60 if not present (treadmill / older firmware).
  final field7Bytes = top[7]?.firstOrNull;
  int durationSeconds;
  if (field7Bytes != null) {
    final f7 = _decodeMessage(Uint8List.fromList(field7Bytes), 0, field7Bytes.length);
    final secs = f7[1]?.firstOrNull;
    durationSeconds = (secs != null && secs > 0) ? secs : durationMin * 60;
  } else {
    durationSeconds = durationMin * 60;
  }

  // field 11: speed/distance sub-message
  //   f1 = avg speed (float32, m/s), f2 = max speed (float32, m/s)
  //   f3 = training score, f4 = total distance (int, meters)
  double distanceMeters = 0;
  final field11Bytes = top[11]?.firstOrNull;
  if (field11Bytes != null) {
    final f11 = _decodeMessage(Uint8List.fromList(field11Bytes), 0, field11Bytes.length);
    final distRaw = f11[4]?.firstOrNull;
    if (distRaw != null && distRaw > 0) distanceMeters = distRaw.toDouble();
  }

  // Fall back to field 40 for non-GPS runs (treadmill, indoor).
  if (distanceMeters == 0) {
    final field40Bytes = top[40]?.firstOrNull;
    if (field40Bytes != null) {
      final totals = _decodeMessage(Uint8List.fromList(field40Bytes), 0, field40Bytes.length);
      final distRaw = totals[3]?.firstOrNull ?? 0;
      distanceMeters = distRaw * 0.1;
    }
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
    sportType: sportType,
    avgHr: avgHr,
    maxHr: maxHr,
  );
}

// ── GPS detail parser ─────────────────────────────────────────────────────────

/// Parse GPS track points from a sports-detail BLE transfer (data type 0x06).
///
/// Same chunk format as summary: 1-byte seq prefix per chunk, 2-byte header.
/// Logs all decoded field values for debugging unknown firmware formats.
/// Returns an empty list if no valid GPS points are found.
List<GpsPoint> parseGpsDetail(List<List<int>> chunks) {
  if (chunks.isEmpty) return [];

  final assembled = <int>[];
  for (final chunk in chunks) {
    if (chunk.length < 2) continue;
    assembled.addAll(chunk.skip(1));
  }
  if (assembled.length < 3) return [];
  final proto = Uint8List.fromList(assembled.skip(2).toList());

  // Log raw hex for debugging.
  final hexStr = proto.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  print('[BLE][GPS-RAW] ${proto.length} B: $hexStr');

  final top = _decodeMessage(proto, 0, proto.length);
  print('[BLE][GPS-FIELDS] top-level fields: ${top.keys.toList()}');

  final points = <GpsPoint>[];

  // Try every length-delimited top-level field as a container for GPS points.
  for (final fieldNum in top.keys.toList()..sort()) {
    final values = top[fieldNum];
    if (values == null) continue;
    for (final v in values) {
      if (v is! List) continue; // skip varint fields
      // Try to decode as a GPS point or as a container of GPS points.
      final bytes = Uint8List.fromList(v as List<int>);
      final sub = _decodeMessage(bytes, 0, bytes.length);

      // Case A: this sub-message has lat/lon directly (fields 1,2 as large varints)
      final pt = _tryGpsPoint(sub);
      if (pt != null) {
        points.add(pt);
        continue;
      }

      // Case B: this sub-message contains repeated GPS point sub-messages.
      for (final innerFieldNum in sub.keys) {
        final innerValues = sub[innerFieldNum];
        if (innerValues == null) continue;
        for (final iv in innerValues) {
          if (iv is! List) continue;
          final innerBytes = Uint8List.fromList(iv as List<int>);
          final innerSub = _decodeMessage(innerBytes, 0, innerBytes.length);
          final ipt = _tryGpsPoint(innerSub);
          if (ipt != null) points.add(ipt);
        }
      }
    }
  }

  print('[BLE][GPS] Parsed ${points.length} GPS point(s)');
  return points;
}

/// Try to interpret a decoded sub-message as a GPS point.
///
/// Expects:
///   field 1 = latitude  as zigzag sint32 × 1e-7 degrees
///   field 2 = longitude as zigzag sint32 × 1e-7 degrees
///   field 3 = altitude  as varint (meters, optional)
///   field 5 = time_offset (seconds from run start, optional)
///   field 6 = heart rate (bpm, optional)
///
/// Returns null if lat/lon are absent or out of plausible range.
GpsPoint? _tryGpsPoint(Map<int, List<dynamic>> msg) {
  final rawLat = msg[1]?.firstOrNull;
  final rawLon = msg[2]?.firstOrNull;
  if (rawLat == null || rawLon == null) return null;
  if (rawLat is! int || rawLon is! int) return null;

  // ZeppOS stores lat/lon as zigzag-encoded signed int32 × 1e7.
  final lat = _zigzagDecode(rawLat) / 1e7;
  final lon = _zigzagDecode(rawLon) / 1e7;

  // Validate plausible GPS range.
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  // Reject (0, 0) placeholder points.
  if (lat == 0 && lon == 0) return null;

  final rawAlt = msg[3]?.firstOrNull;
  final rawT   = msg[5]?.firstOrNull;
  final rawHr  = msg[6]?.firstOrNull;

  return GpsPoint(
    lat: lat,
    lon: lon,
    ele: (rawAlt is int) ? rawAlt.toDouble() : null,
    t:   (rawT is int)   ? rawT              : null,
    hr:  (rawHr is int)  ? rawHr             : null,
  );
}

/// Decode a zigzag-encoded sint32/sint64 varint.
int _zigzagDecode(int n) => (n >> 1) ^ -(n & 1);

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
      case 5: // 32-bit (float) — record as int
        if (pos + 4 <= end) {
          final v = (data[pos]) | (data[pos+1] << 8) | (data[pos+2] << 16) | (data[pos+3] << 24);
          add(fieldNumber, v);
        }
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
