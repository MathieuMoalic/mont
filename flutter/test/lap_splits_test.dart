import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/lap_splits.dart';
import 'package:mont/src/models.dart';

/// Helper to create a RunPoint with optional fields.
RunPoint _pt({
  required double lat,
  required double lon,
  double? ele,
  int? hr,
  int? t,
}) =>
    RunPoint(lat: lat, lon: lon, ele: ele, hr: hr, t: t);

void main() {
  group('fmtPaceFromSeconds', () {
    test('formats 300s as 5:00', () => expect(fmtPaceFromSeconds(300), '5:00'));
    test('formats 360s as 6:00', () => expect(fmtPaceFromSeconds(360), '6:00'));
    test('formats 390s as 6:30', () => expect(fmtPaceFromSeconds(390), '6:30'));
    test('formats 61s as 1:01', () => expect(fmtPaceFromSeconds(61), '1:01'));
    test('formats 599s as 9:59', () => expect(fmtPaceFromSeconds(599), '9:59'));
  });

  group('computeLapSplits', () {
    test('returns empty for fewer than 2 points', () {
      expect(computeLapSplits([], []), isEmpty);
      expect(computeLapSplits([_pt(lat: 0, lon: 0)], [0.0]), isEmpty);
    });

    test('returns empty when total distance < 1 km', () {
      // Points very close together → sub-km cumulative distance
      final pts = [_pt(lat: 0, lon: 0), _pt(lat: 0, lon: 0.001)];
      final km = [0.0, 0.08]; // ~80 m
      expect(computeLapSplits(pts, km), isEmpty);
    });

    test('returns one split for ~1 km run', () {
      // Simulate 3 points spanning 1 km
      final pts = [
        _pt(lat: 0.0, lon: 0.0, t: 0, hr: 150, ele: 100.0),
        _pt(lat: 0.0, lon: 0.005, t: 150, hr: 155, ele: 102.0),
        _pt(lat: 0.0, lon: 0.009, t: 300, hr: 160, ele: 105.0),
      ];
      final km = [0.0, 0.5, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits.length, 1);
      expect(splits[0].lapNumber, 1);
      expect(splits[0].distanceKm, 1.0);
    });

    test('returns two splits for ~2 km run', () {
      final pts = List.generate(
        21,
        (i) => _pt(lat: 0.0, lon: i * 0.001, t: i * 30, hr: 150 + i, ele: 100.0 + i),
      );
      // Cumulative: 0, 0.1, 0.2, … 2.0 km
      final km = List.generate(21, (i) => i * 0.1);
      final splits = computeLapSplits(pts, km);
      expect(splits.length, 2);
      expect(splits[0].lapNumber, 1);
      expect(splits[1].lapNumber, 2);
    });

    test('pace is computed from t values', () {
      // 2 points: 0 km at t=0, 1 km at t=360 → pace = 6:00/km
      final pts = [
        _pt(lat: 0.0, lon: 0.0, t: 0),
        _pt(lat: 0.0, lon: 0.009, t: 360),
      ];
      final km = [0.0, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits.length, 1);
      expect(splits[0].paceSeconds, 360);
    });

    test('pace is null when t is absent', () {
      final pts = [
        _pt(lat: 0.0, lon: 0.0),
        _pt(lat: 0.0, lon: 0.009),
      ];
      final km = [0.0, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits[0].paceSeconds, isNull);
    });

    test('avg HR is computed across points in lap', () {
      final pts = [
        _pt(lat: 0.0, lon: 0.000, t: 0, hr: 150),
        _pt(lat: 0.0, lon: 0.004, t: 180, hr: 160),
        _pt(lat: 0.0, lon: 0.009, t: 360, hr: 170),
      ];
      final km = [0.0, 0.5, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits[0].avgHr, closeTo(160.0, 0.1));
    });

    test('avg HR is null when no HR data', () {
      final pts = [
        _pt(lat: 0.0, lon: 0.000),
        _pt(lat: 0.0, lon: 0.009),
      ];
      final km = [0.0, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits[0].avgHr, isNull);
    });

    test('elevation delta is last minus first in lap', () {
      final pts = [
        _pt(lat: 0.0, lon: 0.000, ele: 100.0),
        _pt(lat: 0.0, lon: 0.005, ele: 110.0),
        _pt(lat: 0.0, lon: 0.009, ele: 115.0),
      ];
      final km = [0.0, 0.5, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits[0].elevationDelta, closeTo(15.0, 0.5));
    });

    test('negative elevation delta for descent', () {
      final pts = [
        _pt(lat: 0.0, lon: 0.000, ele: 200.0),
        _pt(lat: 0.0, lon: 0.009, ele: 180.0),
      ];
      final km = [0.0, 1.0];
      final splits = computeLapSplits(pts, km);
      expect(splits[0].elevationDelta, isNegative);
    });
  });
}
