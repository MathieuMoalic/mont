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
// GPS detail format (data type 0x06):
//   The GPS track data uses the "psmh" binary format (not protobuf).
//   Header: 18 bytes (4-byte "psmh" magic + 14 bytes of flags/timestamp).
//   TLV records: [type:1B][length:1B][data:length B]
//   - Type 1 (TIMESTAMP, len=12): [int32 skip][int64 LE unix_ms] — sets time anchor
//   - Type 2 (GPS_COORDS, len=20): [6B skip][int32 LE lon][int32 LE lat][6B skip]
//   - Type 3 (GPS_DELTA, len=8):  [int16 LE time_offset_ms][int16 LE lon_delta][int16 LE lat_delta][int16 const=2]
//   - Type 5 (SPEED,    len=8):   [int16 LE time_offset_ms][int16 LE cadence_spm][int16 LE stride_cm][int16 LE pace_s_per_km]
//   - Type 7 (ALTITUDE, len=6):   [int16 LE time_offset_ms][int32 LE alt_cm]
//   - Type 8 (HEARTRATE, len=3):  [int16 LE time_offset_ms][uint8 hr_bpm]
//   Coordinates: decimal_degrees = int32_value / 3_000_000.0

import 'dart:typed_data';

const int _sportTypeOutdoorRunning = 8;

class GpsPoint {
  const GpsPoint({
    required this.lat,
    required this.lon,
    this.ele,
    this.hr,
    this.cad,
    this.t,
  });

  final double lat;   // degrees
  final double lon;   // degrees
  final double? ele;  // meters
  final int? hr;      // bpm
  final int? cad;     // steps per minute
  final int? t;       // seconds since run start

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    if (ele != null) 'ele': ele,
    if (hr != null) 'hr': hr,
    if (cad != null) 'cad': cad,
    if (t != null) 't': t,
  };
}

/// Result of parsing a GPS detail transfer.
class GpsDetailResult {
  const GpsDetailResult({
    required this.points,
    this.avgCadenceSpm,
    this.avgStrideM,
  });

  final List<GpsPoint> points;
  final int? avgCadenceSpm;   // average cadence in steps per minute
  final double? avgStrideM;   // average stride length in metres
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
/// The data uses the "psmh" binary format (Huami/ZeppOS activity detail file).
/// [runStartUtc] is used to compute per-point `t` (seconds since run start).
///
/// Returns a [GpsDetailResult] with:
/// - [GpsDetailResult.points]: GPS track with per-point ele, hr, cad, t
/// - [GpsDetailResult.avgCadenceSpm]: run-level average cadence (steps/min)
/// - [GpsDetailResult.avgStrideM]: run-level average stride length (metres)
GpsDetailResult parseGpsDetail(List<List<int>> chunks, DateTime runStartUtc) {
  const empty = GpsDetailResult(points: []);

  if (chunks.isEmpty) return empty;

  final assembled = <int>[];
  for (final chunk in chunks) {
    if (chunk.length < 2) continue;
    assembled.addAll(chunk.skip(1));
  }
  if (assembled.length < 3) return empty;
  final proto = Uint8List.fromList(assembled.skip(2).toList());

  print('[BLE][GPS-RAW] ${proto.length} B: ${proto.take(64).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}...');

  // Validate psmh magic.
  if (proto.length < 18 ||
      proto[0] != 0x70 || proto[1] != 0x73 ||
      proto[2] != 0x6d || proto[3] != 0x68) {
    print('[BLE][GPS] No psmh magic, skipping GPS parse');
    return empty;
  }

  final bd            = ByteData.sublistView(proto);
  final runStartMs    = runStartUtc.millisecondsSinceEpoch;
  final points        = <GpsPoint>[];
  var   lonRaw        = 0;
  var   latRaw        = 0;
  var   hasAnchor     = false;
  double? currentAlt;
  int?    currentHr;
  int?    currentCad;
  double? currentStrideM;
  int     timestampAnchorMs = 0; // set by TIMESTAMP records; 0 = not yet seen

  // For computing run-level averages from SPEED records.
  final cadSamples    = <int>[];
  final strideSamples = <double>[];

  var pos = 18; // skip 18-byte psmh header

  while (pos + 1 < proto.length) {
    final rtype = proto[pos];
    final rlen  = proto[pos + 1];
    final end   = pos + 2 + rlen;
    if (end > proto.length) break;
    final base = pos + 2; // offset of record data within proto
    pos = end;

    switch (rtype) {
      case 1 when rlen == 12: // TIMESTAMP — absolute time anchor
        // Layout: [int32 skip][int64 LE unix_ms]
        timestampAnchorMs = bd.getInt64(base + 4, Endian.little);

      case 2 when rlen == 20: // GPS_COORDS — absolute anchor
        // Layout: [6B skip][int32 LE lon][int32 LE lat][6B skip]
        lonRaw    = bd.getInt32(base + 6, Endian.little);
        latRaw    = bd.getInt32(base + 10, Endian.little);
        hasAnchor = lonRaw != 0 || latRaw != 0;

      case 3 when rlen == 8: // GPS_DELTA — incremental update
        // Layout: [int16 LE time_offset_ms][int16 LE lon_delta][int16 LE lat_delta][int16 const=2]
        if (!hasAnchor) break;
        final offsetMs = bd.getInt16(base, Endian.little);
        lonRaw += bd.getInt16(base + 2, Endian.little);
        latRaw += bd.getInt16(base + 4, Endian.little);
        final lon = lonRaw / 3000000.0;
        final lat = latRaw / 3000000.0;
        if (lat == 0.0 && lon == 0.0) break;

        // Compute t = seconds since run start (null if no TIMESTAMP seen yet).
        int? t;
        if (timestampAnchorMs != 0) {
          final absMs = timestampAnchorMs + offsetMs;
          final tMs = absMs - runStartMs;
          if (tMs >= 0) t = (tMs / 1000).round();
        }

        points.add(GpsPoint(
          lat: lat,
          lon: lon,
          ele: currentAlt,
          hr:  currentHr,
          cad: currentCad,
          t:   t,
        ));

      case 5 when rlen == 8: // SPEED — cadence and stride
        // Layout: [int16 LE time_offset][int16 LE cadence_spm][int16 LE stride_cm][int16 LE pace_s/km]
        final cad     = bd.getInt16(base + 2, Endian.little);
        final strideCm = bd.getInt16(base + 4, Endian.little);
        if (cad > 0) {
          currentCad = cad;
          cadSamples.add(cad);
        }
        if (strideCm > 0) {
          currentStrideM = strideCm / 100.0;
          strideSamples.add(currentStrideM);
        }

      case 7 when (rlen == 6 || rlen == 7): // ALTITUDE — GPS altitude in centimetres
        // Layout: [int16 LE time_offset][int32 LE alt_cm]
        final altRaw = bd.getInt32(base + 2, Endian.little);
        if (altRaw != -1) {
          currentAlt = altRaw / 100.0;
        }

      case 8 when rlen == 3: // HEARTRATE — heart rate in bpm
        // Layout: [int16 LE time_offset][uint8 bpm]
        final bpm = proto[base + 2];
        if (bpm > 0) currentHr = bpm;
    }
  }

  // Compute run-level averages from SPEED record samples.
  int? avgCadenceSpm;
  double? avgStrideM;
  if (cadSamples.isNotEmpty) {
    avgCadenceSpm = cadSamples.reduce((a, b) => a + b) ~/ cadSamples.length;
  }
  if (strideSamples.isNotEmpty) {
    avgStrideM = strideSamples.reduce((a, b) => a + b) / strideSamples.length;
  }

  print('[BLE][GPS] Parsed ${points.length} GPS point(s), '
      'avgCad=$avgCadenceSpm spm, avgStride=${avgStrideM?.toStringAsFixed(2)} m, '
      'hasTime=${points.any((p) => p.t != null)}, '
      'hasHr=${points.any((p) => p.hr != null)}, '
      'hasCad=${points.any((p) => p.cad != null)}');

  return GpsDetailResult(
    points: points,
    avgCadenceSpm: avgCadenceSpm,
    avgStrideM: avgStrideM,
  );
}

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
