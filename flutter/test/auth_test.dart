import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mont/src/auth.dart';

void main() {
  group('Auth.init', () {
    test('treats empty stored tokens as null', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': '',
        'refresh_token': '',
      });

      await Auth.init();

      expect(Auth.token, isNull);
      expect(Auth.refreshToken, isNull);
    });

    test('loads stored tokens', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-123',
        'refresh_token': 'refresh-456',
      });

      await Auth.init();

      expect(Auth.token, 'access-123');
      expect(Auth.refreshToken, 'refresh-456');
    });
  });
}
