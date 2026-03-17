import 'package:flutter_test/flutter_test.dart';

import 'package:mont/src/ble/health_parser.dart';

// Helper: build a chunk with 1-byte seq prefix.
List<int> _chunk(int seq, List<int> payload) => [seq, ...payload];

void main() {
  group('parseActivitySamples', () {
    test('aggregates steps and HR into daily data', () {
      // 2-byte BLE header + two 8-byte samples at 2026-03-15 00:00 UTC.
      // Sample format: [kind, intensity, steps, hr, unk1, sleep, deepSleep, remSleep]
      final header = [0x00, 0x00]; // BLE framing header
      final sample1 = [0x00, 10, 50, 72, 0, 0, 0, 0]; // 50 steps, 72 bpm
      final sample2 = [0x00, 5, 30, 68, 0, 0, 0, 0]; // 30 steps, 68 bpm
      final chunks = [_chunk(0, [...header, ...sample1, ...sample2])];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      expect(result[0].date, '2026-03-15');
      expect(result[0].steps, 80); // 50 + 30
      expect(result[0].avgHr, 70); // (72 + 68) / 2
      expect(result[0].minHr, 68);
      expect(result[0].maxHr, 72);
    });

    test('filters NOT_WORN and CHARGING HR', () {
      final header = [0x00, 0x00];
      final worn = [0x00, 5, 10, 80, 0, 0, 0, 0]; // kind=0, valid
      final notWorn = [115, 5, 5, 55, 0, 0, 0, 0]; // kind=115 NOT_WORN
      final charging = [118, 5, 3, 50, 0, 0, 0, 0]; // kind=118 CHARGING
      final chunks = [_chunk(0, [...header, ...worn, ...notWorn, ...charging])];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      // Steps from all minutes (including not-worn/charging).
      expect(result[0].steps, 18); // 10 + 5 + 3
      // HR only from worn minute.
      expect(result[0].avgHr, 80);
      expect(result[0].minHr, 80);
      expect(result[0].maxHr, 80);
    });

    test('excludes HR sentinel and artifact values', () {
      final header = [0x00, 0x00];
      final sentinel = [0x00, 5, 10, 1, 0, 0, 0, 0]; // hr=1 (sentinel)
      final artifact = [0x00, 5, 10, 30, 0, 0, 0, 0]; // hr=30 (< 40, artifact)
      final valid = [0x00, 5, 10, 65, 0, 0, 0, 0]; // hr=65, valid
      final max = [0x00, 5, 10, 255, 0, 0, 0, 0]; // hr=255, invalid
      final chunks = [_chunk(0, [...header, ...sentinel, ...artifact, ...valid, ...max])];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      expect(result[0].steps, 40); // 10 * 4
      expect(result[0].avgHr, 65); // only the valid reading
      expect(result[0].minHr, 65);
      expect(result[0].maxHr, 65);
    });

    test('groups by UTC date across midnight', () {
      final header = [0x00, 0x00];
      // Start at 2026-03-14 23:59 UTC → minute 0 is 2026-03-14, minute 1 is 2026-03-15.
      final sample1 = [0x00, 0, 10, 60, 0, 0, 0, 0];
      final sample2 = [0x00, 0, 20, 70, 0, 0, 0, 0];
      final chunks = [_chunk(0, [...header, ...sample1, ...sample2])];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 14, 23, 59),
      );

      expect(result, hasLength(2));
      expect(result[0].date, '2026-03-14');
      expect(result[0].steps, 10);
      expect(result[0].avgHr, 60);
      expect(result[1].date, '2026-03-15');
      expect(result[1].steps, 20);
      expect(result[1].avgHr, 70);
    });

    test('returns empty for insufficient data', () {
      expect(parseActivitySamples([], DateTime.utc(2026)), isEmpty);
      // Only header, no samples.
      expect(
        parseActivitySamples([_chunk(0, [0x00, 0x00])], DateTime.utc(2026)),
        isEmpty,
      );
    });

    test('handles no valid HR (all filtered)', () {
      final header = [0x00, 0x00];
      final sample = [115, 5, 10, 1, 0, 0, 0, 0]; // NOT_WORN, sentinel HR
      final chunks = [_chunk(0, [...header, ...sample])];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      expect(result[0].steps, 10);
      expect(result[0].avgHr, isNull);
      expect(result[0].minHr, isNull);
      expect(result[0].maxHr, isNull);
    });

    test('handles multiple chunks with seq counters', () {
      final header = [0x00, 0x00];
      final sample1 = [0x00, 0, 10, 60, 0, 0, 0, 0];
      final sample2 = [0x00, 0, 20, 70, 0, 0, 0, 0];
      // Two chunks, seq=0 has header + sample1, seq=1 has sample2.
      final chunks = [
        _chunk(0, [...header, ...sample1]),
        _chunk(1, sample2),
      ];

      final result = parseActivitySamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      expect(result[0].steps, 30);
      expect(result[0].avgHr, 65);
    });
  });

  group('parseDailyHrSamples', () {
    test('parses 6-byte daily HR records', () {
      // 2026-03-15 00:00 UTC = 1773532800 seconds since epoch
      final ts = 1773532800;
      final tsBytes = [
        ts & 0xff,
        (ts >> 8) & 0xff,
        (ts >> 16) & 0xff,
        (ts >> 24) & 0xff,
      ];
      final header = [0x00, 0x00];
      final record = [...tsBytes, 0, 46]; // UTC offset=0, HR=46

      final chunks = [_chunk(0, [...header, ...record])];
      final result = parseDailyHrSamples(chunks);

      expect(result, hasLength(1));
      expect(result['2026-03-15'], 46);
    });

    test('filters invalid HR values', () {
      final ts = 1773532800;
      final tsBytes = [
        ts & 0xff,
        (ts >> 8) & 0xff,
        (ts >> 16) & 0xff,
        (ts >> 24) & 0xff,
      ];
      final header = [0x00, 0x00];
      final tooLow = [...tsBytes, 0, 10]; // HR=10 (< 20)
      final tooHigh = [...tsBytes, 0, 255]; // HR=255 (> 250)

      final chunks = [_chunk(0, [...header, ...tooLow, ...tooHigh])];
      final result = parseDailyHrSamples(chunks);

      expect(result, isEmpty);
    });

    test('parses multiple days', () {
      final ts1 = 1773532800; // 2026-03-15
      final ts2 = ts1 + 86400; // 2026-03-16
      List<int> leTs(int t) => [t & 0xff, (t >> 8) & 0xff, (t >> 16) & 0xff, (t >> 24) & 0xff];

      final header = [0x00, 0x00];
      final record1 = [...leTs(ts1), 0, 46]; // HR=46
      final record2 = [...leTs(ts2), 0, 48]; // HR=48

      final chunks = [_chunk(0, [...header, ...record1, ...record2])];
      final result = parseDailyHrSamples(chunks);

      expect(result, hasLength(2));
      expect(result['2026-03-15'], 46);
      expect(result['2026-03-16'], 48);
    });

    test('returns empty for insufficient data', () {
      expect(parseDailyHrSamples([]), isEmpty);
      expect(parseDailyHrSamples([_chunk(0, [0x00, 0x00])]), isEmpty);
    });
  });

  group('parseStressSamples', () {
    test('computes daily average stress', () {
      final header = [0x00, 0x00];
      // 3 minutes of stress data: 40, 60, 0xFF (invalid)
      final data = [40, 60, 0xFF];
      final chunks = [_chunk(0, [...header, ...data])];

      final result = parseStressSamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, hasLength(1));
      expect(result['2026-03-15'], 50); // (40 + 60) / 2
    });

    test('skips all-invalid minutes', () {
      final header = [0x00, 0x00];
      final data = [0xFF, 0xFF, 0xFF];
      final chunks = [_chunk(0, [...header, ...data])];

      final result = parseStressSamples(
        chunks,
        DateTime.utc(2026, 3, 15),
      );

      expect(result, isEmpty);
    });

    test('groups by date across midnight', () {
      final header = [0x00, 0x00];
      // Start at 23:59 on 2026-03-14, two minutes → spans midnight.
      final data = [30, 50];
      final chunks = [_chunk(0, [...header, ...data])];

      final result = parseStressSamples(
        chunks,
        DateTime.utc(2026, 3, 14, 23, 59),
      );

      expect(result, hasLength(2));
      expect(result['2026-03-14'], 30);
      expect(result['2026-03-15'], 50);
    });

    test('returns empty for no data', () {
      expect(parseStressSamples([], DateTime.utc(2026)), isEmpty);
    });
  });
}
