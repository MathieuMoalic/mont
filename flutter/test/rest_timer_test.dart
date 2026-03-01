import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/views/settings_screen.dart';

void main() {
  group('fmtRestTime', () {
    test('formats seconds under 60', () {
      expect(fmtRestTime(30), '30s');
      expect(fmtRestTime(45), '45s');
      expect(fmtRestTime(1), '1s');
    });

    test('formats exactly 60 seconds as 1m 00s', () {
      expect(fmtRestTime(60), '1m 00s');
    });

    test('formats 90 seconds as 1m 30s', () {
      expect(fmtRestTime(90), '1m 30s');
    });

    test('formats 120 seconds as 2m 00s', () {
      expect(fmtRestTime(120), '2m 00s');
    });

    test('formats 300 seconds as 5m 00s', () {
      expect(fmtRestTime(300), '5m 00s');
    });

    test('formats 75 seconds as 1m 15s', () {
      expect(fmtRestTime(75), '1m 15s');
    });

    test('pads single-digit seconds with zero', () {
      expect(fmtRestTime(61), '1m 01s');
      expect(fmtRestTime(65), '1m 05s');
    });

    test('default rest timer value formats correctly', () {
      expect(fmtRestTime(kRestTimerDefault), '1m 30s');
    });
  });

  group('Settings constants', () {
    test('kRestTimerDefault is 90 seconds', () {
      expect(kRestTimerDefault, 90);
    });

    test('kRestTimerKey is correct', () {
      expect(kRestTimerKey, 'rest_timer_seconds');
    });

    test('kSmoothingDefault is 5', () {
      expect(kSmoothingDefault, 5);
    });
  });
}
