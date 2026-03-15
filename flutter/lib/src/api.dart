import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import './platform/kv_store.dart' as kv;
import './models.dart';

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

// ── Exercises ────────────────────────────────────────────────────────────────

Future<List<Exercise>> listExercises() async {
  final res = await http.get(_u('/exercises'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => Exercise.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<Exercise> createExercise({
  required String name,
  String? notes,
  String? muscleGroup,
}) async {
  final res = await http.post(
    _u('/exercises'),
    headers: _headers(),
    body: jsonEncode({
      'name': name,
      if (notes != null) 'notes': notes,
      if (muscleGroup != null) 'muscle_group': muscleGroup,
    }),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return Exercise.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<List<PersonalRecord>> getPersonalRecords() async {
  final res = await http.get(_u('/runs/prs'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => PersonalRecord.fromJson(e as Map<String, dynamic>))
      .toList();
}

// ── Workouts ─────────────────────────────────────────────────────────────────

Future<List<WorkoutSummary>> listWorkouts() async {
  final res = await http.get(_u('/workouts'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((w) => WorkoutSummary.fromJson(w as Map<String, dynamic>))
      .toList();
}

Future<WorkoutSummary> createWorkout() async {
  final res = await http.post(_u('/workouts'), headers: _headers());
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<WorkoutDetail> getWorkout(int id) async {
  final res = await http.get(_u('/workouts/$id'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WorkoutDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> finishWorkout(int id) async {
  final res = await http.patch(_u('/workouts/$id/finish'), headers: _headers());
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> deleteWorkout(int id) async {
  final res = await http.delete(_u('/workouts/$id'), headers: _headers());
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> restartWorkout(int id) async {
  final res = await http.patch(_u('/workouts/$id/restart'), headers: _headers());
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WorkoutSet> addSet({
  required int workoutId,
  required int exerciseId,
  required int setNumber,
  required int reps,
  required double weightKg,
}) async {
  final res = await http.post(
    _u('/workouts/$workoutId/sets'),
    headers: _headers(),
    body: jsonEncode({
      'exercise_id': exerciseId,
      'set_number': setNumber,
      'reps': reps,
      'weight_kg': weightKg,
    }),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSet.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteSet({required int workoutId, required int setId}) async {
  final res = await http.delete(
    _u('/workouts/$workoutId/sets/$setId'),
    headers: _headers(),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

// ── Weight ────────────────────────────────────────────────────────────────────

Future<List<WeightEntry>> listWeight() async {
  final res = await http.get(_u('/weight'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => WeightEntry.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<WeightEntry> createWeightEntry({required double weightKg, String? measuredAt}) async {
  final res = await http.post(
    _u('/weight'),
    headers: _headers(),
    body: jsonEncode({
      'weight_kg': weightKg,
      if (measuredAt != null) 'measured_at': measuredAt,
    }),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WeightEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteWeightEntry(int id) async {
  final res = await http.delete(_u('/weight/$id'), headers: _headers());
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WeightEntry> updateWeightEntry(int id, {double? weightKg, String? measuredAt}) async {
  final res = await http.patch(
    _u('/weight/$id'),
    headers: _headers(),
    body: jsonEncode({
      if (weightKg != null) 'weight_kg': weightKg,
      if (measuredAt != null) 'measured_at': measuredAt,
    }),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WeightEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

// ── Runs ──────────────────────────────────────────────────────────────────────

Future<List<RunSummary>> listRuns() async {
  final res = await http.get(_u('/runs'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => RunSummary.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<RunDetail> getRun(int id) async {
  final res = await http.get(_u('/runs/$id'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return RunDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<RunSummary> importFit(List<int> bytes) async {
  final token = _authToken;
  if (token == null) throw Exception('Not authenticated');
  final req = http.MultipartRequest('POST', _u('/runs/import/fit'))
    ..headers['Authorization'] = 'Bearer $token'
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'activity.fit'));
  final streamed = await req.send();
  final body = await streamed.stream.bytesToString();
  if (streamed.statusCode != 201) throw Exception('HTTP ${streamed.statusCode}');
  return RunSummary.fromJson(jsonDecode(body) as Map<String, dynamic>);
}

Future<RunSummary> importBleSummary({
  required String startedAt,
  required int durationSeconds,
  required double distanceMeters,
  int? avgHr,
  int? maxHr,
}) async {
  final res = await http.post(
    _u('/runs/ble'),
    headers: _headers(),
    body: jsonEncode({
      'started_at': startedAt,
      'duration_seconds': durationSeconds,
      'distance_meters': distanceMeters,
      if (avgHr != null) 'avg_hr': avgHr,
      if (maxHr != null) 'max_hr': maxHr,
    }),
  );
  if (res.statusCode != 201 && res.statusCode != 200) {
    throw Exception('HTTP ${res.statusCode}: ${res.body}');
  }
  return RunSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> importHealthFit(List<int> bytes) async {
  final token = _authToken;
  if (token == null) throw Exception('Not authenticated');
  final req = http.MultipartRequest('POST', _u('/health/fit'))
    ..headers['Authorization'] = 'Bearer $token'
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'health.fit'));
  final streamed = await req.send();
  if (streamed.statusCode != 201) throw Exception('HTTP ${streamed.statusCode}');
  await streamed.stream.bytesToString(); // drain
}

Future<List<List<List<double>>>> fetchHeatmap() async {
  final res = await http.get(_u('/runs/heatmap'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((route) => (route as List)
          .map((pt) => (pt as List).map((v) => (v as num).toDouble()).toList())
          .toList())
      .toList();
}


Future<void> deleteRun(int id) async {
  final res = await http.delete(_u('/runs/$id'), headers: _headers());
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> markRunInvalid(int id, {required bool isInvalid}) async {
  final res = await http.patch(
    _u('/runs/$id'),
    headers: _headers(),
    body: jsonEncode({'is_invalid': isInvalid}),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<List<ExerciseHistoryPoint>> getExerciseHistory(int exerciseId) async {
  final res = await http.get(_u('/exercises/$exerciseId/history'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => ExerciseHistoryPoint.fromJson(e as Map<String, dynamic>))
      .toList();
}


// ── Health ────────────────────────────────────────────────────────────────────

Future<List<DailyHealth>> listDailyHealth() async {
  final res = await http.get(_u('/health/daily'), headers: _headers());
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => DailyHealth.fromJson(e as Map<String, dynamic>))
      .toList();
}
