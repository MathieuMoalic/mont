import './api.dart' as api;
import './platform/kv_store.dart' as kv;

const _kAuthTokenKey = 'auth_token';
const _kRefreshTokenKey = 'refresh_token';

class Auth {
  static String? _token;
  static String? _refreshToken;

  static Future<void> init() async {
    _token = await kv.getString(_kAuthTokenKey);
    _refreshToken = await kv.getString(_kRefreshTokenKey);
    api.setAuthToken(_token);
  }

  static String? get token => _token;
  static String? get refreshToken => _refreshToken;

  static Future<void> save(String token, String refreshToken) async {
    _token = token;
    _refreshToken = refreshToken;
    await kv.setString(_kAuthTokenKey, token);
    await kv.setString(_kRefreshTokenKey, refreshToken);
    api.setAuthToken(token);
  }

  static Future<void> saveAccessToken(String token) async {
    _token = token;
    await kv.setString(_kAuthTokenKey, token);
    api.setAuthToken(token);
  }

  static Future<void> logout() async {
    _token = null;
    _refreshToken = null;
    await kv.setString(_kAuthTokenKey, '');
    await kv.setString(_kRefreshTokenKey, '');
    api.setAuthToken(null);
  }

  static Future<void> login({required String password}) async {
    final result = await api.login(password: password);
    await save(result.token, result.refreshToken);
  }

  /// Attempt to refresh the access token using the stored refresh token.
  /// Returns true if successful, false otherwise.
  static Future<bool> tryRefresh() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      return false;
    }
    try {
      final newToken = await api.refreshAccessToken(_refreshToken!);
      await saveAccessToken(newToken);
      return true;
    } catch (_) {
      return false;
    }
  }
}
