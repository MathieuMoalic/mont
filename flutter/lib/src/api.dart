import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import './platform/kv_store.dart' as kv;

const String _defaultBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://mont.matmoa.eu',
);

const _kApiBaseUrlKey = 'api_base_url';

String _baseUrl = _defaultBaseUrl;
String? _authToken;

String get baseUrl => _baseUrl;

Future<void> initApi() async {
  final saved = await kv.getString(_kApiBaseUrlKey);
  if (saved != null && saved.trim().isNotEmpty) {
    _baseUrl = _normalizeBase(saved);
  } else if (kIsWeb && _baseUrl == _defaultBaseUrl) {
    final origin = Uri.base.origin;
    if (origin.isNotEmpty) _baseUrl = origin;
  }
}

void setAuthToken(String? token) {
  _authToken = token;
}

Uri _u(String path) => Uri.parse('$_baseUrl$path');

Map<String, String> _headers() => {
  'Content-Type': 'application/json',
  if (_authToken != null) 'Authorization': 'Bearer $_authToken',
};

String _normalizeBase(String url) {
  final trimmed = url.trim();
  return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
}

Future<void> _pingHealthz(String baseUrl, {Duration timeout = const Duration(seconds: 5)}) async {
  final res = await http.get(Uri.parse('$baseUrl/healthz')).timeout(timeout);
  if (res.statusCode != 200 || !res.body.contains('ok')) {
    throw Exception('Server at $baseUrl did not respond correctly to /healthz');
  }
}

Future<void> verifyAndSaveBaseUrl(String url, {Duration timeout = const Duration(seconds: 5)}) async {
  final candidate = _normalizeBase(url);
  await _pingHealthz(candidate, timeout: timeout);
  _baseUrl = candidate;
  await kv.setString(_kApiBaseUrlKey, _baseUrl);
}

Future<bool> pingHealthz({Duration timeout = const Duration(seconds: 5)}) async {
  try {
    await _pingHealthz(_baseUrl, timeout: timeout);
    return true;
  } catch (_) {
    return false;
  }
}

Future<String> fetchBackendVersion() async {
  final res = await http.get(_u('/version'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data['version'] as String;
}

Future<String> login({required String password}) async {
  final res = await http.post(
    _u('/auth/login'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'password': password}),
  );
  if (res.statusCode != 200) throw Exception('Login failed: ${res.body}');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data['token'] as String;
}
