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
  // Expected: [0x10, 0x01, status, count, ???, ???, ???, year_lo, year_hi, month, day, hour, min, sec, 0x04, 0x00]
  if (payload.length < 4) return null;
  if (payload[0] != 0x10 || payload[1] != 0x01) return null;
  final count = payload[3];
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
