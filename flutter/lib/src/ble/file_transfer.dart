// Amazfit/ZeppOS BLE file transfer (endpoint 0x000d).
//
// Flow to download a file:
//  1. Send "list request" with object type → watch replies with file metadata list
//  2. For each file: send "file request" → watch replies with file data chunks
//
// Object types (field in list request):
//   0x0004 = workout/activity FIT files
//   0x0006 = monitoring/health data
//
// Protocol frames (all little-endian, sent via chunked write on endpoint 0x000d):
//   List request:  [0x0b, 0x00, objType_lo, objType_hi, 0x00, 0x00, 0x00, 0x00]
//   File request:  [0x03, 0x00, id_lo, id_hi, id2_lo, id2_hi, 0x00, 0x00]
//   Delete ack:    [0x04, 0x00, id_lo, id_hi, ...]

import 'dart:typed_data';

import 'chunked_protocol.dart';

const int kObjectTypeActivity = 0x0004;
const int kObjectTypeHealth = 0x0006;

/// Build a file-list request for [objectType].
List<Uint8List> buildListRequest(int objectType, int seq) {
  final ByteData bd = ByteData(8);
  bd.setUint16(0, 0x000b, Endian.little); // list command
  bd.setUint16(2, objectType, Endian.little);
  // remaining 4 bytes = 0 (no filter)
  return encodeChunked(BleEndpoints.fileTransfer, seq, bd.buffer.asUint8List());
}

/// Build a file download request for [fileId].
List<Uint8List> buildFileRequest(int fileId, int seq) {
  final ByteData bd = ByteData(8);
  bd.setUint16(0, 0x0003, Endian.little); // fetch command
  bd.setUint32(2, fileId, Endian.little);
  return encodeChunked(BleEndpoints.fileTransfer, seq, bd.buffer.asUint8List());
}

/// Metadata entry parsed from a file-list response.
class FileEntry {
  const FileEntry({required this.id, required this.size, required this.timestamp});

  final int id;
  final int size;
  final int timestamp; // unix seconds

  @override
  String toString() => 'FileEntry(id=$id, size=$size, ts=$timestamp)';
}

/// Parse a file-list response payload into [FileEntry] items.
///
/// Response format:
///   [0x0b, 0x00, count_lo, count_hi, ...entries]
/// Each entry is 16 bytes:
///   [id(4), unknown(4), timestamp(4), size(4)]
List<FileEntry> parseListResponse(Uint8List payload) {
  if (payload.length < 4) return [];
  final ByteData bd = ByteData.sublistView(payload);
  final int cmd = bd.getUint16(0, Endian.little);
  if (cmd != 0x000b) return [];
  final int count = bd.getUint16(2, Endian.little);
  final List<FileEntry> entries = [];
  int offset = 4;
  for (int i = 0; i < count; i++) {
    if (offset + 16 > payload.length) break;
    final int id = bd.getUint32(offset, Endian.little);
    final int ts = bd.getUint32(offset + 8, Endian.little);
    final int size = bd.getUint32(offset + 12, Endian.little);
    entries.add(FileEntry(id: id, size: size, timestamp: ts));
    offset += 16;
  }
  return entries;
}

/// Returns true when a file transfer response indicates the last chunk.
bool isFileTransferComplete(Uint8List payload) {
  if (payload.length < 2) return false;
  final int cmd = ByteData.sublistView(payload).getUint16(0, Endian.little);
  return cmd == 0x0003; // file data reply uses same command id
}
