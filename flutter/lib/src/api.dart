import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import 'package:http/http.dart' as http;

import './platform/kv_store.dart' as kv;
import './models.dart';

const String _envBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

const String _prodBaseUrl = 'https://mont.matmoa.eu';
const String _devBaseUrl = 'http://localhost:8080';

final String _defaultBaseUrl = _envBaseUrl.isNotEmpty
    ? _envBaseUrl
    : (kDebugMode ? _devBaseUrl : _prodBaseUrl);

const _kApiBaseUrlKey = 'api_base_url';

String _baseUrl = _defaultBaseUrl;
String? _authToken;
String? _refreshToken;

/// Callback to handle authentication failure (e.g., redirect to login)
void Function()? onAuthFailure;

void setRefreshToken(String? token) {
  _refreshToken = token;
}

String get baseUrl => _baseUrl;

Future<void> initApi() async {
  final saved = await kv.getString(_kApiBaseUrlKey);

  // In debug builds, always prefer the dev default unless explicitly set
  if (kDebugMode) {
    if (saved != null && saved.trim().isNotEmpty && saved != _prodBaseUrl) {
      // Keep custom URLs, but reset if it's the prod default
      _baseUrl = _normalizeBase(saved);
    } else {
      // Clear saved URL in debug mode and use localhost
      if (saved != null) {
        await kv.setString(_kApiBaseUrlKey, '');
      }
      _baseUrl = _defaultBaseUrl;
    }
  } else {
    // Release/prod mode: use saved URL if available
    if (saved != null && saved.trim().isNotEmpty) {
      _baseUrl = _normalizeBase(saved);
    } else if (kIsWeb && _baseUrl == _defaultBaseUrl) {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty) _baseUrl = origin;
    }
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

Future<bool>? _refreshInFlight;

/// Try to refresh the access token using the stored refresh token.
/// Returns true if successful.
Future<bool> _tryRefreshToken() async {
  if (_refreshToken == null || _refreshToken!.isEmpty) {
    if (kDebugMode) {
      print(
        'Token refresh skipped: null=${_refreshToken == null}, empty=${_refreshToken?.isEmpty}',
      );
    }
    return false;
  }

  final inFlight = _refreshInFlight;
  if (inFlight != null) {
    if (kDebugMode) print('Token refresh awaiting in-flight refresh...');
    return await inFlight;
  }

  Future<bool> doRefresh() async {
    try {
      if (kDebugMode) print('Attempting token refresh...');
      final newToken = await refreshAccessToken(_refreshToken!);
      _authToken = newToken;
      await kv.setString('auth_token', newToken);
      if (kDebugMode) print('Token refresh successful');
      return true;
    } catch (e) {
      if (kDebugMode) print('Token refresh failed: $e');
      return false;
    }
  }

  _refreshInFlight = doRefresh().whenComplete(() {
    _refreshInFlight = null;
  });
  return await _refreshInFlight!;
}

/// Handle 401 response: try to refresh token and retry, or trigger auth failure
Future<http.Response> _handleUnauthorized(
  Future<http.Response> Function() request,
) async {
  final res = await request();
  if (res.statusCode == 401) {
    final refreshed = await _tryRefreshToken();
    if (refreshed) {
      // Retry the request with new token
      final retry = await request();
      if (retry.statusCode != 401) return retry;
    }

    // Refresh failed (or retry still unauthorized), trigger auth failure callback
    onAuthFailure?.call();
    throw Exception('Session expired. Please log in again.');
  }
  return res;
}

String _normalizeBase(String url) {
  final trimmed = url.trim();
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

Future<void> _pingHealthz(
  String baseUrl, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final res = await http.get(Uri.parse('$baseUrl/healthz')).timeout(timeout);
  if (res.statusCode != 200 || !res.body.contains('ok')) {
    throw Exception('Server at $baseUrl did not respond correctly to /healthz');
  }
}

Future<void> verifyAndSaveBaseUrl(
  String url, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final candidate = _normalizeBase(url);
  await _pingHealthz(candidate, timeout: timeout);
  _baseUrl = candidate;
  await kv.setString(_kApiBaseUrlKey, _baseUrl);
}

Future<bool> pingHealthz({
  Duration timeout = const Duration(seconds: 5),
}) async {
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

class LoginResult {
  final String token;
  final String refreshToken;
  LoginResult({required this.token, required this.refreshToken});
}

Future<LoginResult> login({required String password}) async {
  final res = await http.post(
    _u('/auth/login'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'password': password}),
  );
  if (res.statusCode != 200) throw Exception('Login failed: ${res.body}');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return LoginResult(
    token: data['token'] as String,
    refreshToken: data['refresh_token'] as String,
  );
}

Future<String> refreshAccessToken(String refreshToken) async {
  final res = await http
      .post(
        _u('/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      )
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) {
    throw Exception(
      'Token refresh failed with status ${res.statusCode}: ${res.body}',
    );
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data['token'] as String;
}

// ── Exercises ────────────────────────────────────────────────────────────────

Future<List<Exercise>> listExercises() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/exercises'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => Exercise.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<Exercise> createExercise({
  required String name,
  String? notes,
  String? muscleGroup,
  String? equipment,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/exercises'),
      headers: _headers(),
      body: jsonEncode({
        'name': name,
        if (notes != null) 'notes': notes,
        if (muscleGroup != null) 'muscle_group': muscleGroup,
        if (equipment != null) 'equipment': equipment,
      }),
    ),
  );
  if (res.statusCode != 201) {
    final body = res.body;
    throw Exception(body.isNotEmpty ? body : 'Failed to create exercise');
  }
  return Exercise.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<Exercise> updateExercise(
  int id, {
  String? name,
  String? notes,
  String? muscleGroup,
  String? equipment,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/exercises/$id'),
      headers: _headers(),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (notes != null) 'notes': notes,
        if (muscleGroup != null) 'muscle_group': muscleGroup,
        if (equipment != null) 'equipment': equipment,
      }),
    ),
  );
  if (res.statusCode != 200) {
    final body = res.body;
    throw Exception(body.isNotEmpty ? body : 'Failed to update exercise');
  }
  return Exercise.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<ExerciseCategories> getExerciseCategories() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/exercise-categories'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return ExerciseCategories.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

Future<void> updateExerciseCategories(ExerciseCategories categories) async {
  final res = await _handleUnauthorized(
    () => http.put(
      _u('/exercise-categories'),
      headers: _headers(),
      body: jsonEncode(categories.toJson()),
    ),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<List<PersonalRecord>> getPersonalRecords() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/runs/prs'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => PersonalRecord.fromJson(e as Map<String, dynamic>))
      .toList();
}

// ── Workouts ─────────────────────────────────────────────────────────────────

Future<List<WorkoutSummary>> listWorkouts() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/workouts'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((w) => WorkoutSummary.fromJson(w as Map<String, dynamic>))
      .toList();
}

Future<List<HyroxDay>> listHyroxDays() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/hyrox-days'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => HyroxDay.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<void> upsertHyroxDay(String day) async {
  final encodedDay = Uri.encodeComponent(day);
  final res = await _handleUnauthorized(
    () => http.put(_u('/hyrox-days/$encodedDay'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> deleteHyroxDay(String day) async {
  final encodedDay = Uri.encodeComponent(day);
  final res = await _handleUnauthorized(
    () => http.delete(_u('/hyrox-days/$encodedDay'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WorkoutSummary> createWorkout() async {
  final res = await _handleUnauthorized(
    () => http.post(_u('/workouts'), headers: _headers()),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<WorkoutDetail> getWorkout(int id) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/workouts/$id'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WorkoutDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteWorkout(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/workouts/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WorkoutSet> addSet({
  required int workoutId,
  required int exerciseId,
  required int setNumber,
  required int reps,
  required double weightKg,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/workouts/$workoutId/sets'),
      headers: _headers(),
      body: jsonEncode({
        'exercise_id': exerciseId,
        'set_number': setNumber,
        'reps': reps,
        'weight_kg': weightKg,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSet.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteSet({required int workoutId, required int setId}) async {
  final res = await _handleUnauthorized(
    () => http.delete(
      _u('/workouts/$workoutId/sets/$setId'),
      headers: _headers(),
    ),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WorkoutSummary> updateWorkout(int id, {String? notes}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/workouts/$id'),
      headers: _headers(),
      body: jsonEncode({if (notes != null) 'notes': notes}),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<WorkoutSet> updateSet({
  required int workoutId,
  required int setId,
  int? reps,
  double? weightKg,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/workouts/$workoutId/sets/$setId'),
      headers: _headers(),
      body: jsonEncode({
        if (reps != null) 'reps': reps,
        if (weightKg != null) 'weight_kg': weightKg,
      }),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WorkoutSet.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

// ── Weight ────────────────────────────────────────────────────────────────────

Future<List<WeightEntry>> listWeight() async {
  const pageSize = 500;
  var offset = 0;
  final all = <WeightEntry>[];

  while (true) {
    final res = await _handleUnauthorized(
      () => http.get(
        _u('/weight?limit=$pageSize&offset=$offset'),
        headers: _headers(),
      ),
    );
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final batch = (jsonDecode(res.body) as List)
        .map((e) => WeightEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    all.addAll(batch);
    if (batch.length < pageSize) break;
    offset += pageSize;
  }

  return all;
}

Future<WeightEntry> createWeightEntry({
  required double weightKg,
  String? measuredAt,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/weight'),
      headers: _headers(),
      body: jsonEncode({
        'weight_kg': weightKg,
        if (measuredAt != null) 'measured_at': measuredAt,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return WeightEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

// ── Issue reports ────────────────────────────────────────────────────────────

Future<void> createIssueReport({
  required String message,
  String? clientVersion,
  String? serverVersion,
  String? platform,
  String? baseUrl,
  String? route,
  String? extraJson,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/issues'),
      headers: _headers(),
      body: jsonEncode({
        'message': message,
        if (clientVersion != null) 'client_version': clientVersion,
        if (serverVersion != null) 'server_version': serverVersion,
        if (platform != null) 'platform': platform,
        if (baseUrl != null) 'base_url': baseUrl,
        if (route != null) 'route': route,
        if (extraJson != null) 'extra_json': extraJson,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
}

Future<List<Map<String, dynamic>>> listIssueReports({
  int limit = 50,
  int offset = 0,
}) async {
  final res = await _handleUnauthorized(
    () => http.get(
      _u('/issues?limit=$limit&offset=$offset'),
      headers: _headers(),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
}

Future<void> deleteWeightEntry(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/weight/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<WeightEntry> updateWeightEntry(
  int id, {
  double? weightKg,
  String? measuredAt,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/weight/$id'),
      headers: _headers(),
      body: jsonEncode({
        if (weightKg != null) 'weight_kg': weightKg,
        if (measuredAt != null) 'measured_at': measuredAt,
      }),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return WeightEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

// ── Calories ──────────────────────────────────────────────────────────────────

Future<List<CalorieEntry>> listCalorieEntries({
  required String startDay,
  required String endDay,
}) async {
  final res = await _handleUnauthorized(
    () => http.get(
      _u('/calories?start=$startDay&end=$endDay'),
      headers: _headers(),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => CalorieEntry.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<CalorieEntry> createCalorieEntry({
  required String day,
  required String mealPeriod,
  required String name,
  required double proteinPer100G,
  required double carbsPer100G,
  required double fatsPer100G,
  required double weightG,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/calories'),
      headers: _headers(),
      body: jsonEncode({
        'day': day,
        'meal_period': mealPeriod,
        'name': name,
        'protein_per_100g': proteinPer100G,
        'carbs_per_100g': carbsPer100G,
        'fats_per_100g': fatsPer100G,
        'weight_g': weightG,
      }),
    ),
  );
  if (res.statusCode != 201) {
    throw Exception(
      res.body.isEmpty ? 'Failed to create calorie entry' : res.body,
    );
  }
  return CalorieEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<CalorieEntry> updateCalorieEntry(
  int id, {
  String? day,
  String? mealPeriod,
  String? name,
  double? proteinPer100G,
  double? carbsPer100G,
  double? fatsPer100G,
  double? weightG,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/calories/$id'),
      headers: _headers(),
      body: jsonEncode({
        if (day != null) 'day': day,
        if (mealPeriod != null) 'meal_period': mealPeriod,
        if (name != null) 'name': name,
        if (proteinPer100G != null) 'protein_per_100g': proteinPer100G,
        if (carbsPer100G != null) 'carbs_per_100g': carbsPer100G,
        if (fatsPer100G != null) 'fats_per_100g': fatsPer100G,
        if (weightG != null) 'weight_g': weightG,
      }),
    ),
  );
  if (res.statusCode != 200) {
    throw Exception(
      res.body.isEmpty ? 'Failed to update calorie entry' : res.body,
    );
  }
  return CalorieEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteCalorieEntry(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/calories/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<List<Food>> listFoods({String? query}) async {
  final params = <String>[];
  if (query != null && query.trim().isNotEmpty) {
    params.add('q=${Uri.encodeQueryComponent(query.trim())}');
  }
  final suffix = params.isEmpty ? '' : '?${params.join('&')}';
  final res = await _handleUnauthorized(
    () => http.get(_u('/calories/foods$suffix'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => Food.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<Food> updateFood(
  int id, {
  required String name,
  required String brand,
  required double proteinPer100G,
  required double carbsPer100G,
  required double fatsPer100G,
  required String source,
}) async {
  final body = {
    'name': name,
    'brand': brand,
    'protein_per_100g': proteinPer100G,
    'carbs_per_100g': carbsPer100G,
    'fats_per_100g': fatsPer100G,
    'source': source,
  };
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/calories/foods/$id'),
      headers: _headers(),
      body: jsonEncode(body),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return Food.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<Food> upsertFoodManual({
  required String name,
  String? brand,
  required double proteinPer100G,
  required double carbsPer100G,
  required double fatsPer100G,
  required double lastWeightG,
  String? source,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/calories/foods'),
      headers: _headers(),
      body: jsonEncode({
        'name': name,
        if (brand != null) 'brand': brand,
        'protein_per_100g': proteinPer100G,
        'carbs_per_100g': carbsPer100G,
        'fats_per_100g': fatsPer100G,
        'last_weight_g': lastWeightG,
        if (source != null) 'source': source,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return Food.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteFood(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/calories/foods/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

// ── Meals ────────────────────────────────────────────────────────────────────

Future<List<MealSummary>> listMeals({int limit = 200, int offset = 0}) async {
  final res = await _handleUnauthorized(
    () =>
        http.get(_u('/meals?limit=$limit&offset=$offset'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => MealSummary.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<MealDetail> getMeal(int id) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/meals/$id'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return MealDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<MealDetail> createMeal({
  required String name,
  required List<Map<String, dynamic>> ingredients,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/meals'),
      headers: _headers(),
      body: jsonEncode({'name': name, 'ingredients': ingredients}),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return MealDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<MealDetail> updateMeal(
  int id, {
  String? name,
  List<Map<String, dynamic>>? ingredients,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/meals/$id'),
      headers: _headers(),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (ingredients != null) 'ingredients': ingredients,
      }),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return MealDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<void> deleteMeal(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/meals/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<CalorieEntry> logMeal({
  required String day,
  required String mealPeriod,
  required int mealId,
  required double percent,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/meals/log'),
      headers: _headers(),
      body: jsonEncode({
        'day': day,
        'meal_period': mealPeriod,
        'meal_id': mealId,
        'percent': percent,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
  return CalorieEntry.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<Food> getFoodByBarcode(String barcode) async {
  final b = barcode.trim();
  final res = await _handleUnauthorized(
    () => http.get(
      _u('/calories/foods/by-barcode/${Uri.encodeComponent(b)}'),
      headers: _headers(),
    ),
  );
  if (res.statusCode == 404) throw Exception('No saved item for barcode $b.');
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return Food.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<FoodLookupResult> lookupFoodByBarcode(String barcode) async {
  final b = barcode.trim();
  final res = await _handleUnauthorized(
    () => http.get(
      _u('/calories/foods/lookup/${Uri.encodeComponent(b)}'),
      headers: _headers(),
    ),
  );
  if (res.statusCode == 404) {
    throw Exception('No product found online for barcode $b.');
  }
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return FoodLookupResult.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

/// Search for foods by name. Returns local database results first (if available),
/// then falls back to online lookup via Open Food Facts.
Future<List<FoodLookupResult>> lookupFoodsByQuery(
  String query, {
  int? limit,
}) async {
  final q = query.trim();
  if (q.isEmpty) throw Exception('Query cannot be empty');

  final params = <String>['q=${Uri.encodeQueryComponent(q)}'];
  if (limit != null && limit > 0) {
    params.add('limit=${limit.clamp(1, 20)}');
  }
  final suffix = '?${params.join('&')}';

  final res = await _handleUnauthorized(
    () => http.get(_u('/calories/foods/lookup$suffix'), headers: _headers()),
  );
  if (res.statusCode == 400) {
    throw Exception('Invalid query parameters');
  }
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

  return (jsonDecode(res.body) as List)
      .map((e) => FoodLookupResult.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Extract food macros using LLM based on food name
Future<Map<String, dynamic>> extractMacrosWithLlm(
  String query, [
  String? dataType,
]) async {
  final q = query.trim();
  if (q.isEmpty) throw Exception('Food name cannot be empty');

  final params = {'q': q};
  if (dataType != null) {
    params['data_type'] = dataType;
  }
  final suffix = '?${Uri(queryParameters: params).query}';

  final res = await _handleUnauthorized(
    () => http.get(
      _u('/calories/foods/extract-macros$suffix'),
      headers: _headers(),
    ),
  );
  if (res.statusCode == 400) {
    throw Exception('Invalid food name');
  }
  if (res.statusCode == 503 || res.statusCode == 502) {
    throw Exception('LLM service unavailable');
  }
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return {
    'name': data['name'] as String,
    'protein_per_100g': (data['protein_per_100g'] as num).toDouble(),
    'carbs_per_100g': (data['carbs_per_100g'] as num).toDouble(),
    'fats_per_100g': (data['fats_per_100g'] as num).toDouble(),
    'source': data['source'] as String,
  };
}

Future<List<Map<String, dynamic>>> searchUSDAFoods(
  String query, [
  String? dataType,
]) async {
  final q = query.trim();
  if (q.isEmpty) throw Exception('Food name cannot be empty');

  final params = {'q': q};
  if (dataType != null) {
    params['data_type'] = dataType;
  }
  final suffix = '?${Uri(queryParameters: params).query}';

  final res = await _handleUnauthorized(
    () =>
        http.get(_u('/calories/foods/search-usda$suffix'), headers: _headers()),
  );
  if (res.statusCode == 400) {
    throw Exception('Invalid food name');
  }
  if (res.statusCode == 503 || res.statusCode == 502) {
    throw Exception('USDA service unavailable');
  }
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

  final data = jsonDecode(res.body) as Map<String, dynamic>;
  final results = data['results'] as List<dynamic>?;
  if (results == null) throw Exception('Invalid response format');

  return results
      .map(
        (r) => {
          'fdc_id': r['fdc_id'] as String,
          'description': r['description'] as String,
          'data_type': r['data_type'] as String,
          'protein_per_100g': r['protein_per_100g'] as num?,
          'carbs_per_100g': r['carbs_per_100g'] as num?,
          'fats_per_100g': r['fats_per_100g'] as num?,
        },
      )
      .toList();
}

Future<Food> upsertFoodByBarcode({
  required String barcode,
  required String name,
  String? brand,
  required double proteinPer100G,
  required double carbsPer100G,
  required double fatsPer100G,
  required double lastWeightG,
  String? source,
}) async {
  final res = await _handleUnauthorized(
    () => http.put(
      _u('/calories/foods/by-barcode/${Uri.encodeComponent(barcode.trim())}'),
      headers: _headers(),
      body: jsonEncode({
        'name': name,
        if (brand != null) 'brand': brand,
        'protein_per_100g': proteinPer100G,
        'carbs_per_100g': carbsPer100G,
        'fats_per_100g': fatsPer100G,
        'last_weight_g': lastWeightG,
        if (source != null) 'source': source,
      }),
    ),
  );
  if (res.statusCode != 200) {
    throw Exception(
      res.body.isEmpty ? 'Failed to save barcode food' : res.body,
    );
  }
  return Food.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<List<CalorieExerciseEntry>> listCalorieExercises({
  required String startDay,
  required String endDay,
}) async {
  final res = await _handleUnauthorized(
    () => http.get(
      _u('/calories/exercises?start=$startDay&end=$endDay'),
      headers: _headers(),
    ),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => CalorieExerciseEntry.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<CalorieExerciseEntry> createCalorieExercise({
  required String day,
  required String name,
  required int kcal,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/calories/exercises'),
      headers: _headers(),
      body: jsonEncode({'day': day, 'name': name, 'kcal': kcal}),
    ),
  );
  if (res.statusCode != 201) {
    throw Exception(
      res.body.isEmpty ? 'Failed to create calorie exercise' : res.body,
    );
  }
  return CalorieExerciseEntry.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

Future<CalorieExerciseEntry> updateCalorieExercise(
  int id, {
  String? day,
  String? name,
  int? kcal,
}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/calories/exercises/$id'),
      headers: _headers(),
      body: jsonEncode({
        if (day != null) 'day': day,
        if (name != null) 'name': name,
        if (kcal != null) 'kcal': kcal,
      }),
    ),
  );
  if (res.statusCode != 200) {
    throw Exception(
      res.body.isEmpty ? 'Failed to update calorie exercise' : res.body,
    );
  }
  return CalorieExerciseEntry.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

Future<void> deleteCalorieExercise(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/calories/exercises/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<NutritionTargets> getNutritionTargets() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/calories/targets'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return NutritionTargets.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

Future<void> updateNutritionTargets(NutritionTargets targets) async {
  final res = await _handleUnauthorized(
    () => http.put(
      _u('/calories/targets'),
      headers: _headers(),
      body: jsonEncode(targets.toJson()),
    ),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

// ── Runs ──────────────────────────────────────────────────────────────────────

Future<List<RunSummary>> listRuns() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/runs?limit=500'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => RunSummary.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<RunDetail> getRun(int id) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/runs/$id'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return RunDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

Future<RunSummary> importGpx(List<int> bytes, String filename) async {
  final token = _authToken;
  if (token == null) throw Exception('Not authenticated');
  final req = http.MultipartRequest('POST', _u('/runs/import'))
    ..headers['Authorization'] = 'Bearer $token'
    ..files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
  final streamed = await req.send();
  final body = await streamed.stream.bytesToString();
  if (streamed.statusCode != 201) {
    throw Exception('HTTP ${streamed.statusCode}');
  }
  return RunSummary.fromJson(jsonDecode(body) as Map<String, dynamic>);
}

Future<List<List<List<double>>>> fetchHeatmap() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/runs/heatmap'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map(
        (route) => (route as List)
            .map(
              (pt) => (pt as List).map((v) => (v as num).toDouble()).toList(),
            )
            .toList(),
      )
      .toList();
}

Future<void> deleteRun(int id) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/runs/$id'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> deleteAllRuns() async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/runs'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<void> markRunInvalid(int id, {required bool isInvalid}) async {
  final res = await _handleUnauthorized(
    () => http.patch(
      _u('/runs/$id'),
      headers: _headers(),
      body: jsonEncode({'is_invalid': isInvalid}),
    ),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}

Future<Map<String, dynamic>> syncGadgetbridge() async {
  final res = await _handleUnauthorized(
    () => http.post(_u('/runs/sync'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<List<ExerciseHistoryPoint>> getExerciseHistory(int exerciseId) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/exercises/$exerciseId/history'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => ExerciseHistoryPoint.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<ExercisePersonalRecord> getExercisePersonalRecords(
  int exerciseId,
) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/exercises/$exerciseId/pr'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return ExercisePersonalRecord.fromJson(
    jsonDecode(res.body) as Map<String, dynamic>,
  );
}

// ── Health ────────────────────────────────────────────────────────────────────

Future<List<DailyHealth>> listDailyHealth() async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/health/daily?limit=500'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => DailyHealth.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<List<BodyPicture>> listBodyPictures({String? from, String? to}) async {
  String query = '/health/pictures';
  final params = <String>[];
  if (from != null) params.add('from=$from');
  if (to != null) params.add('to=$to');
  if (params.isNotEmpty) query += '?${params.join('&')}';

  final res = await _handleUnauthorized(
    () => http.get(_u(query), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  return (jsonDecode(res.body) as List)
      .map((e) => BodyPicture.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<String> getBodyPictureData(String pictureDate) async {
  final res = await _handleUnauthorized(
    () => http.get(_u('/health/pictures/$pictureDate'), headers: _headers()),
  );
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data['picture_data'] as String;
}

Future<void> uploadBodyPicture({
  required String pictureDate,
  required String base64Data,
}) async {
  final res = await _handleUnauthorized(
    () => http.post(
      _u('/health/pictures'),
      headers: _headers(),
      body: jsonEncode({
        'picture_date': pictureDate,
        'picture_data': base64Data,
      }),
    ),
  );
  if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
}

Future<void> deleteBodyPicture(String pictureDate) async {
  final res = await _handleUnauthorized(
    () => http.delete(_u('/health/pictures/$pictureDate'), headers: _headers()),
  );
  if (res.statusCode != 204) throw Exception('HTTP ${res.statusCode}');
}
