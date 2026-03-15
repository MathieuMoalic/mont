// Amazfit/ZeppOS BLE file transfer helpers.
//
// NOTE: The Huami2021 protocol reverse-engineered from Gadgetbridge logcat shows
// that all data ops use endpoint 0x004B via the chunked protocol on 0x0016/0x0017.
// This file is kept as a placeholder until the full FIT-download protocol is known.
// The raw sports summary data received on 0x0005 must first be decoded to learn
// the actual file identifiers before individual FIT files can be requested.

import 'dart:typed_data';

import 'chunked_protocol.dart';

// Placeholder — not yet called. Endpoint and payload format TBD once we
// observe an actual FIT file download in a Gadgetbridge logcat capture.
Uint8List buildFileRequest(int fileId, int seq) {
  final ByteData bd = ByteData(8);
  bd.setUint16(0, 0x0003, Endian.little);
  bd.setUint32(2, fileId, Endian.little);
  return encodeHuami2021(BleEndpoints.huamiData, seq, bd.buffer.asUint8List());
}
