// Amazfit/ZeppOS data-fetch protocol (endpoint 0x004B).
//
// A single endpoint handles all bulk data types. The type byte in the payload
// selects what to fetch:
//   0x01 = ACTIVITY      (step/HR actigraphy)
//   0x05 = SPORTS_SUMMARIES  (workout summaries)
//   0x13 = STRESS_AUTO
//
// Request payload (10 bytes):
//   [0x01, data_type, year_lo, year_hi, month, day, hour, min, sec, 0x04]
//
// Response payload (from 0x0017):
//   [0x10, 0x01, status(1), count(1), ???(3), year_lo, year_hi, month, day, hour, min, sec, 0x04, 0x00]
//   count > 0  → data available; send START_TRANSFER, then data streams on 0x0005
//   count == 0 → nothing new
//
// Start-transfer command (send to 0x0016 after count > 0):
//   payload = [0x02]
//
// ACK command (send to 0x0016 after all data received):
//   payload = [0x03, 0x01]  (0x01 = delete from watch)
//   payload = [0x03, 0x09]  (0x09 = keep on watch)
//
// Transfer-complete response (from 0x0017, after data stream ends):
//   [0x10, 0x02, ...]  = checksum/summary
//
// ACK response (from 0x0017, after our ACK):
//   [0x10, 0x03, 0x01]

import 'dart:typed_data';

import 'chunked_protocol.dart';

/// Data types for the fetch request.
class HuamiDataType {
  HuamiDataType._();

  static const int activity = 0x01;
  static const int sportsSummaries = 0x05;
  static const int sportsDetails = 0x06; // GPS track + per-sample HR for one workout
  static const int stressAuto = 0x13;
}

/// Build a SPORTS_SUMMARIES fetch request since [sinceYear]-[sinceMonth]-[sinceDay].
///
/// To get all available workouts, pass an early date such as 2000-01-01.
Uint8List buildSportsFetchRequest(
  int seq, {
  int sinceYear = 2000,
  int sinceMonth = 1,
  int sinceDay = 1,
  int sinceHour = 0,
  int sinceMin = 0,
  int sinceSec = 0,
}) {
  final payload = Uint8List(10);
  payload[0] = 0x01; // fetch command
  payload[1] = HuamiDataType.sportsSummaries;
  ByteData.sublistView(payload).setUint16(2, sinceYear, Endian.little);
  payload[4] = sinceMonth;
  payload[5] = sinceDay;
  payload[6] = sinceHour;
  payload[7] = sinceMin;
  payload[8] = sinceSec;
  payload[9] = 0x04; // unknown constant present in all requests
  return encodeHuami2021(BleEndpoints.huamiData, seq, payload);
}

/// Build a SPORTS_DETAILS fetch request for the workout that started at the given time.
///
/// Use the exact start timestamp from the parsed SportsSummary.
Uint8List buildSportsDetailRequest(
  int seq,
  DateTime startTime,
) {
  final payload = Uint8List(10);
  payload[0] = 0x01; // fetch command
  payload[1] = HuamiDataType.sportsDetails;
  ByteData.sublistView(payload).setUint16(2, startTime.year, Endian.little);
  payload[4] = startTime.month;
  payload[5] = startTime.day;
  payload[6] = startTime.hour;
  payload[7] = startTime.minute;
  payload[8] = startTime.second;
  payload[9] = 0x04;
  return encodeHuami2021(BleEndpoints.huamiData, seq, payload);
}

/// Build an ACTIVITY fetch request since [since].
///
/// ACTIVITY data (type 0x01) streams 8-byte per-minute samples:
/// [kind, intensity, steps, hr, unknown1, sleep, deepSleep, remSleep]
Uint8List buildActivityFetchRequest(int seq, DateTime since) {
  final payload = Uint8List(10);
  payload[0] = 0x01; // fetch command
  payload[1] = HuamiDataType.activity;
  ByteData.sublistView(payload).setUint16(2, since.year, Endian.little);
  payload[4] = since.month;
  payload[5] = since.day;
  payload[6] = since.hour;
  payload[7] = since.minute;
  payload[8] = since.second;
  payload[9] = 0x04;
  return encodeHuami2021(BleEndpoints.huamiData, seq, payload);
}

/// Build a START_TRANSFER command (send to 0x0016 after watch says count > 0).
Uint8List buildStartTransfer(int seq) {
  return encodeHuami2021(BleEndpoints.huamiData, seq, Uint8List.fromList([0x02]));
}

/// Build an ACK command to finish the transfer.
///
/// [deleteFromWatch] = true: tell watch to delete the transferred data.
Uint8List buildAckTransfer(int seq, {bool deleteFromWatch = false}) {
  final keepFlag = deleteFromWatch ? 0x01 : 0x09;
  return encodeHuami2021(
    BleEndpoints.huamiData,
    seq,
    Uint8List.fromList([0x03, keepFlag]),
  );
}

/// Result of parsing a fetch-response payload from 0x0017.
class FetchResponse {
  const FetchResponse({required this.count, required this.sinceTimestamp});

  final int count; // 0 = no new data
  final DateTime? sinceTimestamp; // timestamp the watch reports

  bool get hasData => count > 0;
}

/// Parse a fetch-response payload (bytes after the Huami2021 header).
///
/// Returns null on unrecognised payload.
FetchResponse? parseFetchResponse(Uint8List payload) {
  if (payload.length < 5) return null;
  if (payload[0] != 0x10 || payload[1] != 0x01) return null;
  // bytes 3-4: LE uint16 = byte count of incoming data (0 = nothing to send)
  final count = ByteData.sublistView(payload).getUint16(3, Endian.little);
  DateTime? ts;
  if (payload.length >= 14) {
    final bd = ByteData.sublistView(payload);
    final year = bd.getUint16(7, Endian.little);
    final month = payload[9];
    final day = payload[10];
    final hour = payload[11];
    final min = payload[12];
    final sec = payload[13];
    try {
      ts = DateTime(year, month, day, hour, min, sec);
    } catch (_) {
      ts = null;
    }
  }
  return FetchResponse(count: count, sinceTimestamp: ts);
}
