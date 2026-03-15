import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/ble/sports_parser.dart';

void main() {
  group('parseGpsDetail', () {
    // Minimal valid psmh file with 1 GPS_COORDS and 2 GPS_DELTA records.
    //
    // GPS_COORDS: lon_raw=50_850_000 (16.950000°E), lat_raw=157_314_000 (52.438000°N)
    // GPS_DELTA 1: lon_delta=+300, lat_delta=+600  → 16.950100°E, 52.438200°N
    // GPS_DELTA 2: lon_delta=+600, lat_delta=+900  → 16.950300°E, 52.438500°N
    final testChunk = [
      0, 0, 128, // seq prefix (0x00) + BLE header (0x00, 0x80)
      112, 115, 109, 104, // "psmh" magic
      0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 1, 0, 1, 0, // 14 header bytes
      2, 20, // GPS_COORDS type=2 len=20
      0, 0, 0, 0, 0, 0, // 6 skip bytes
      208, 232, 7, 3, // lon_raw = 50_850_000 LE int32
      208, 107, 96, 9, // lat_raw = 157_314_000 LE int32
      0, 0, 0, 0, 0, 0, // 6 skip bytes
      3, 8, // GPS_DELTA type=3 len=8
      232, 3, // time_offset = 1000 ms
      44, 1, // lon_delta = +300 LE int16
      88, 2, // lat_delta = +600 LE int16
      2, 0, // const = 2
      3, 8, // GPS_DELTA type=3 len=8
      208, 7, // time_offset = 2000 ms
      88, 2, // lon_delta = +600 LE int16
      132, 3, // lat_delta = +900 LE int16
      2, 0, // const = 2
    ];

    final runStart = DateTime.utc(2025, 11, 28, 7, 19, 42);

    test('returns empty points for empty input', () {
      expect(parseGpsDetail([], runStart).points, isEmpty);
    });

    test('returns empty points for non-psmh data', () {
      expect(parseGpsDetail([[0, 0, 0x00, 0x80, 0x01, 0x02, 0x03, 0x04]], runStart).points, isEmpty);
    });

    test('decodes 2 GPS points from valid psmh data', () {
      final result = parseGpsDetail([testChunk], runStart);
      expect(result.points.length, 2);

      expect(result.points[0].lon, closeTo(16.950100, 1e-5));
      expect(result.points[0].lat, closeTo(52.438200, 1e-5));

      expect(result.points[1].lon, closeTo(16.950300, 1e-5));
      expect(result.points[1].lat, closeTo(52.438500, 1e-5));
    });

    test('GPS points include altitude when type7 record is present', () {
      // Insert a type7 ALTITUDE record between GPS_COORDS (ends at index 42)
      // and the first GPS_DELTA (starts at index 43).
      // type=7 len=6: [int16 LE offset=500 → 0xF401][int32 LE alt_cm=22000 → 0xF0550000]
      // 500  LE int16 → [0xF4, 0x01]
      // 22000 LE int32 → [0xF0, 0x55, 0x00, 0x00]
      final altRecord = [7, 6, 0xF4, 0x01, 0xF0, 0x55, 0x00, 0x00];
      final chunkWithAlt = List<int>.from(testChunk)..insertAll(43, altRecord);

      final result = parseGpsDetail([chunkWithAlt], runStart);
      expect(result.points.length, 2);
      expect(result.points[0].ele, closeTo(220.0, 0.1)); // 22000 cm = 220 m
    });

    test('GPS_DELTA before GPS_COORDS is ignored', () {
      // A chunk with GPS_DELTA before any GPS_COORDS
      final noAnchorChunk = [
        0, 0, 128, // seq + BLE header
        112, 115, 109, 104, // "psmh"
        0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 1, 0, 1, 0, // header
        3, 8, 232, 3, 44, 1, 88, 2, 2, 0, // GPS_DELTA without anchor
      ];
      expect(parseGpsDetail([noAnchorChunk], runStart).points, isEmpty);
    });

    test('HR carried forward to GPS points from type8 records', () {
      // Insert type8 HEARTRATE [int16 offset=0, uint8 bpm=142] before GPS_DELTA
      final hrRecord = [8, 3, 0, 0, 142]; // bpm = 142
      final chunkWithHr = List<int>.from(testChunk)..insertAll(43, hrRecord);

      final result = parseGpsDetail([chunkWithHr], runStart);
      expect(result.points.length, 2);
      expect(result.points[0].hr, 142);
      expect(result.points[1].hr, 142); // carried forward
    });

    test('cadence carried forward to GPS points from type5 records', () {
      // Insert type5 SPEED [int16 offset=0, int16 cad=160, int16 stride=110cm, int16 pace=350]
      // 160 LE int16 → [160, 0]; 110 LE int16 → [110, 0]; 350 LE int16 → [94, 1]
      final speedRecord = [5, 8, 0, 0, 160, 0, 110, 0, 94, 1];
      final chunkWithSpeed = List<int>.from(testChunk)..insertAll(43, speedRecord);

      final result = parseGpsDetail([chunkWithSpeed], runStart);
      expect(result.points.length, 2);
      expect(result.points[0].cad, 160);
      expect(result.points[1].cad, 160); // carried forward
      expect(result.avgCadenceSpm, 160);
      expect(result.avgStrideM, closeTo(1.10, 0.01)); // 110cm = 1.10m
    });
  });
}
