// Amazfit / ZeppOS (Huami 2021) chunked BLE protocol constants and codec.
//
// BLE service:       0000fee0-0000-1000-8000-00805f9b34fb
// Chunked write:     00000005-0000-3512-2118-0009af100700  (write without response)
// Chunked notify:    00000004-0000-3512-2118-0009af100700  (notify)
// Auth char:         00000009-0000-3512-2118-0009af100700
//
// Packet format (little-endian):
//   [endpoint_lo, endpoint_hi, seq_lo, seq_hi, flags, len_lo, len_hi, payload…]
//
// flags: 0x00 = continuation, 0x06 = first (with full length), 0x04 = last

import 'dart:typed_data';

class BleUuids {
  BleUuids._();

  static const String service = '0000fee0-0000-1000-8000-00805f9b34fb';
  static const String chunkedWrite = '00000005-0000-3512-2118-0009af100700';
  static const String chunkedNotify = '00000004-0000-3512-2118-0009af100700';
  static const String auth = '00000009-0000-3512-2118-0009af100700';
}

class BleEndpoints {
  BleEndpoints._();

  static const int authEndpoint = 0x0082;
  static const int fileTransfer = 0x000d;
  static const int activityList = 0x0019;
}

/// Maximum payload bytes that fit in one BLE MTU packet (MTU 23 → 20 usable,
/// minus 7 header bytes = 13, but in practice the watch negotiates MTU 512).
/// We cap chunks at 509 bytes (512 – 3 ATT overhead) to be safe.
const int kMaxChunkPayload = 509;

const int _flagFirst = 0x06;
const int _flagMiddle = 0x00;
const int _flagLast = 0x04;

/// Split [payload] into chunked BLE packets for [endpoint] starting at [seq].
///
/// Returns a list of raw byte arrays ready to write to [BleUuids.chunkedWrite].
List<Uint8List> encodeChunked(int endpoint, int seq, Uint8List payload) {
  final List<Uint8List> packets = [];
  final int total = payload.length;
  int offset = 0;
  bool first = true;

  while (offset < total || first) {
    final int remaining = total - offset;
    final int chunkLen = remaining > kMaxChunkPayload ? kMaxChunkPayload : remaining;
    final bool isLast = (offset + chunkLen) >= total;

    int flag;
    if (first && isLast) {
      flag = _flagFirst | _flagLast; // 0x07 – only packet
    } else if (first) {
      flag = _flagFirst; // 0x06
    } else if (isLast) {
      flag = _flagLast; // 0x04
    } else {
      flag = _flagMiddle; // 0x00
    }

    final ByteData header = ByteData(7);
    header.setUint16(0, endpoint, Endian.little);
    header.setUint16(2, seq & 0xffff, Endian.little);
    header.setUint8(4, flag);
    header.setUint16(5, first ? total : chunkLen, Endian.little);

    final Uint8List chunk = payload.sublist(offset, offset + chunkLen);
    final Uint8List packet = Uint8List(7 + chunkLen);
    packet.setRange(0, 7, header.buffer.asUint8List());
    packet.setRange(7, 7 + chunkLen, chunk);
    packets.add(packet);

    offset += chunkLen;
    first = false;
  }

  return packets;
}

/// Reassemble chunked BLE notification packets into the original payload.
///
/// Accumulate raw notification bytes with [ChunkedReader.feed]; call
/// [ChunkedReader.take] when [ChunkedReader.isComplete] is true.
class ChunkedReader {
  int? _endpoint;
  int _expectedLen = 0;
  final List<int> _buf = [];

  bool get isComplete => _buf.length >= _expectedLen && _expectedLen > 0;

  int? get endpoint => _endpoint;

  /// Feed a raw notification packet. Returns true when a complete message
  /// has been assembled.
  bool feed(Uint8List packet) {
    if (packet.length < 7) return false;
    final ByteData bd = ByteData.sublistView(packet);
    final int ep = bd.getUint16(0, Endian.little);
    final int flag = bd.getUint8(4);
    final int lenField = bd.getUint16(5, Endian.little);
    final Uint8List payload = packet.sublist(7);

    final bool isFirst = (flag & 0x02) != 0; // bit 1 set → first
    if (isFirst) {
      _endpoint = ep;
      _expectedLen = lenField;
      _buf.clear();
    }

    _buf.addAll(payload);
    return isComplete;
  }

  /// Return the assembled payload and reset the reader.
  Uint8List take() {
    final Uint8List result = Uint8List.fromList(_buf.sublist(0, _expectedLen));
    _buf.clear();
    _expectedLen = 0;
    _endpoint = null;
    return result;
  }
}
