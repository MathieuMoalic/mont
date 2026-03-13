import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/views/settings_screen.dart';

void main() {
  group('Settings constants', () {
    test('kSmoothingDefault is 5', () {
      expect(kSmoothingDefault, 5);
    });

    test('kSmoothingKey is correct', () {
      expect(kSmoothingKey, 'chart_smoothing');
    });
  });
}
