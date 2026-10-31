import 'package:flutter_test/flutter_test.dart';

import 'package:mont/src/day_math.dart';

void main() {
  group('dayOffset', () {
    // Europe/Paris transitions: spring-forward 2026-03-29, fall-back
    // 2026-10-25. Duration arithmetic drifts an hour across both; civil
    // stepping must land exactly on local midnight.
    test('stays at midnight across a fall-back', () {
      expect(dayOffset(DateTime(2026, 10, 20), 12), DateTime(2026, 11, 1));
      expect(dayOffset(DateTime(2026, 11, 1), -12), DateTime(2026, 10, 20));
    });

    test('stays at midnight across a spring-forward', () {
      expect(dayOffset(DateTime(2026, 3, 20), 12), DateTime(2026, 4, 1));
      expect(dayOffset(DateTime(2026, 4, 1), -12), DateTime(2026, 3, 20));
    });

    test('normalizes month and year overflow', () {
      expect(dayOffset(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 1));
      expect(dayOffset(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(dayOffset(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });

    test('preserves the day for a zero offset', () {
      expect(dayOffset(DateTime(2026, 10, 31), 0), DateTime(2026, 10, 31));
    });
  });

  group('civilDaysBetween', () {
    test('counts civil days across DST transitions', () {
      expect(civilDaysBetween(DateTime(2026, 3, 20), DateTime(2026, 4, 1)), 12);
      expect(
        civilDaysBetween(DateTime(2026, 10, 20), DateTime(2026, 11, 1)),
        12,
      );
    });

    test('is negative going backwards', () {
      expect(
        civilDaysBetween(DateTime(2026, 10, 31), DateTime(2026, 10, 26)),
        -5,
      );
    });

    test('handles week spans', () {
      expect(
        civilDaysBetween(DateTime(2026, 10, 26), DateTime(2026, 10, 31)),
        5,
      );
      expect(
        civilDaysBetween(DateTime(2026, 10, 26), DateTime(2026, 11, 1)),
        6,
      );
    });
  });
}
