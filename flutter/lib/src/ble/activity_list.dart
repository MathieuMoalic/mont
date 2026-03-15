// Amazfit/ZeppOS activity list endpoint (0x0019).
//
// Used to retrieve the list of workout summaries (not full FIT data).
// Full FIT files are downloaded via file_transfer.dart (endpoint 0x000d).
//
// Request:  [0x01, 0x00, count_lo, count_hi]  – request up to `count` entries
// Response: [0x01, 0x00, total_lo, total_hi, ...ActivityEntry × total]
//
// ActivityEntry (28 bytes each):
//   [type(1), unknown(1), start_ts(4), end_ts(4), file_id(4), ...14 bytes padding]

import 'dart:typed_data';

import 'chunked_protocol.dart';

/// Build a request for up to [count] recent activity summaries.
List<Uint8List> buildActivityListRequest(int count, int seq) {
  final ByteData bd = ByteData(4);
  bd.setUint16(0, 0x0001, Endian.little);
  bd.setUint16(2, count, Endian.little);
  return encodeChunked(BleEndpoints.activityList, seq, bd.buffer.asUint8List());
}

/// Summary of a single workout from the activity list.
class ActivitySummary {
  const ActivitySummary({
    required this.type,
    required this.startTimestamp,
    required this.endTimestamp,
    required this.fileId,
  });

  final int type; // e.g. 0x01 = running
  final int startTimestamp; // unix seconds
  final int endTimestamp;
  final int fileId; // use with file_transfer to download FIT

  @override
  String toString() =>
      'ActivitySummary(type=$type, start=$startTimestamp, fileId=$fileId)';
}

/// Parse an activity-list response payload.
List<ActivitySummary> parseActivityListResponse(Uint8List payload) {
  if (payload.length < 4) return [];
  final ByteData bd = ByteData.sublistView(payload);
  final int cmd = bd.getUint16(0, Endian.little);
  if (cmd != 0x0001) return [];
  final int count = bd.getUint16(2, Endian.little);
  final List<ActivitySummary> result = [];
  int offset = 4;
  for (int i = 0; i < count; i++) {
    if (offset + 28 > payload.length) break;
    final int type = bd.getUint8(offset);
    final int startTs = bd.getUint32(offset + 2, Endian.little);
    final int endTs = bd.getUint32(offset + 6, Endian.little);
    final int fileId = bd.getUint32(offset + 10, Endian.little);
    result.add(ActivitySummary(
      type: type,
      startTimestamp: startTs,
      endTimestamp: endTs,
      fileId: fileId,
    ));
    offset += 28;
  }
  return result;
}
