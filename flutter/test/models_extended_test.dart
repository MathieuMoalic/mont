import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/models.dart';

void main() {
  group('RunPoint', () {
    test('fromJson parses all fields', () {
      final p = RunPoint.fromJson({
        'lat': 51.5074,
        'lon': -0.1278,
        'ele': 10.5,
        'hr': 145,
        't': 300,
        'cad': 180,
      });
      expect(p.lat, 51.5074);
      expect(p.lon, -0.1278);
      expect(p.ele, 10.5);
      expect(p.hr, 145);
      expect(p.t, 300);
      expect(p.cad, 180);
    });

    test('fromJson handles null optional fields', () {
      final p = RunPoint.fromJson({'lat': 40.7128, 'lon': -74.0060});
      expect(p.lat, 40.7128);
      expect(p.lon, -74.0060);
      expect(p.ele, isNull);
      expect(p.hr, isNull);
      expect(p.t, isNull);
      expect(p.cad, isNull);
    });

    test('fromJson handles integer coordinates', () {
      final p = RunPoint.fromJson({'lat': 51, 'lon': -1});
      expect(p.lat, 51.0);
      expect(p.lon, -1.0);
    });
  });

  group('RunSummary', () {
    Map<String, dynamic> _runJson({
      int id = 1,
      String startedAt = '2024-03-15T09:00:00Z',
      int durationS = 1800,
      double distanceM = 5000.0,
      double? elevationGainM,
      int? avgHr,
      int? maxHr,
      String? notes,
      bool? isInvalid,
      int? avgCadence,
      double? avgStrideM,
      double? weatherTempC,
      double? weatherWindKph,
      double? weatherPrecipMm,
      int? weatherCode,
    }) => {
      'id': id,
      'started_at': startedAt,
      'duration_s': durationS,
      'distance_m': distanceM,
      if (elevationGainM != null) 'elevation_gain_m': elevationGainM,
      if (avgHr != null) 'avg_hr': avgHr,
      if (maxHr != null) 'max_hr': maxHr,
      if (notes != null) 'notes': notes,
      if (isInvalid != null) 'is_invalid': isInvalid,
      if (avgCadence != null) 'avg_cadence': avgCadence,
      if (avgStrideM != null) 'avg_stride_m': avgStrideM,
      if (weatherTempC != null) 'weather_temp_c': weatherTempC,
      if (weatherWindKph != null) 'weather_wind_kph': weatherWindKph,
      if (weatherPrecipMm != null) 'weather_precip_mm': weatherPrecipMm,
      if (weatherCode != null) 'weather_code': weatherCode,
    };

    test('fromJson parses all fields', () {
      final r = RunSummary.fromJson(
        _runJson(
          elevationGainM: 150.5,
          avgHr: 155,
          maxHr: 175,
          notes: 'Great run!',
          avgCadence: 170,
          avgStrideM: 1.1,
          weatherTempC: 15.5,
          weatherWindKph: 10.0,
          weatherPrecipMm: 0.0,
          weatherCode: 1,
        ),
      );
      expect(r.id, 1);
      expect(r.durationS, 1800);
      expect(r.distanceM, 5000.0);
      expect(r.elevationGainM, 150.5);
      expect(r.avgHr, 155);
      expect(r.maxHr, 175);
      expect(r.notes, 'Great run!');
      expect(r.avgCadence, 170);
      expect(r.avgStrideM, 1.1);
      expect(r.weatherTempC, 15.5);
      expect(r.weatherWindKph, 10.0);
      expect(r.weatherPrecipMm, 0.0);
      expect(r.weatherCode, 1);
    });

    test('fromJson parses DateTime correctly', () {
      final r = RunSummary.fromJson(
        _runJson(startedAt: '2024-06-15T14:30:00Z'),
      );
      expect(r.startedAt.year, 2024);
      expect(r.startedAt.month, 6);
      expect(r.startedAt.day, 15);
      expect(r.startedAt.hour, 14);
      expect(r.startedAt.minute, 30);
    });

    test('fromJson handles integer distance_m', () {
      final r = RunSummary.fromJson({
        'id': 1,
        'started_at': '2024-01-01T00:00:00Z',
        'duration_s': 1800,
        'distance_m': 5000,
      });
      expect(r.distanceM, 5000.0);
    });
  });

  group('RunDetail', () {
    test('fromJson parses route', () {
      final r = RunDetail.fromJson({
        'id': 1,
        'started_at': '2024-01-01T00:00:00Z',
        'duration_s': 1800,
        'distance_m': 5000.0,
        'route': [
          {'lat': 51.5, 'lon': -0.1},
          {'lat': 51.6, 'lon': -0.2, 'hr': 150},
          {'lat': 51.7, 'lon': -0.3, 'ele': 25.0},
        ],
      });
      expect(r.route.length, 3);
      expect(r.route[0].lat, 51.5);
      expect(r.route[1].hr, 150);
      expect(r.route[2].ele, 25.0);
    });

    test('fromJson handles empty route', () {
      final r = RunDetail.fromJson({
        'id': 1,
        'started_at': '2024-01-01T00:00:00Z',
        'duration_s': 1800,
        'distance_m': 5000.0,
        'route': [],
      });
      expect(r.route, isEmpty);
    });
  });

  group('WeightEntry', () {
    test('fromJson parses all fields', () {
      final w = WeightEntry.fromJson({
        'id': 1,
        'measured_at': '2024-03-15T08:00:00Z',
        'weight_kg': 75.5,
      });
      expect(w.id, 1);
      expect(w.measuredAt.year, 2024);
      expect(w.measuredAt.month, 3);
      expect(w.measuredAt.day, 15);
      expect(w.weightKg, 75.5);
    });

    test('fromJson handles integer weight', () {
      final w = WeightEntry.fromJson({
        'id': 1,
        'measured_at': '2024-01-01T00:00:00Z',
        'weight_kg': 70,
      });
      expect(w.weightKg, 70.0);
    });
  });

  group('DailyHealth', () {
    test('fromJson parses all fields', () {
      final h = DailyHealth.fromJson({
        'date': '2024-03-15',
        'avg_hr': 65,
        'min_hr': 52,
        'max_hr': 145,
        'hrv_rmssd': 45.5,
        'steps': 8500,
      });
      expect(h.date, '2024-03-15');
      expect(h.avgHr, 65);
      expect(h.minHr, 52);
      expect(h.maxHr, 145);
      expect(h.hrvRmssd, 45.5);
      expect(h.steps, 8500);
    });

    test('fromJson handles null optional fields', () {
      final h = DailyHealth.fromJson({'date': '2024-03-15'});
      expect(h.date, '2024-03-15');
      expect(h.avgHr, isNull);
      expect(h.minHr, isNull);
      expect(h.maxHr, isNull);
      expect(h.hrvRmssd, isNull);
      expect(h.steps, isNull);
    });
  });

  group('Exercise', () {
    test('displayName returns name when no equipment', () {
      final e = Exercise.fromJson({'id': 1, 'name': 'Squat', 'notes': null});
      expect(e.displayName, 'Squat');
    });

    test('displayName returns name with equipment when set', () {
      final e = Exercise.fromJson({
        'id': 1,
        'name': 'Bench Press',
        'notes': null,
        'equipment': 'Barbell',
      });
      expect(e.displayName, 'Bench Press (Barbell)');
    });

    test('displayName ignores empty equipment string', () {
      final e = Exercise.fromJson({
        'id': 1,
        'name': 'Deadlift',
        'notes': null,
        'equipment': '',
      });
      expect(e.displayName, 'Deadlift');
    });

    test('fromJson parses all optional fields', () {
      final e = Exercise.fromJson({
        'id': 1,
        'name': 'Test',
        'notes': 'Some notes',
        'muscle_group': 'Chest',
        'equipment': 'Dumbbell',
      });
      expect(e.notes, 'Some notes');
      expect(e.muscleGroup, 'Chest');
      expect(e.equipment, 'Dumbbell');
    });
  });

  group('WorkoutSet', () {
    test('fromJson parses loggedAt DateTime', () {
      final s = WorkoutSet.fromJson({
        'id': 1,
        'exercise_id': 5,
        'exercise_name': 'Squat',
        'set_number': 1,
        'reps': 10,
        'weight_kg': 100.0,
        'logged_at': '2024-03-15T10:30:00Z',
      });
      expect(s.loggedAt.year, 2024);
      expect(s.loggedAt.month, 3);
      expect(s.loggedAt.day, 15);
      expect(s.loggedAt.hour, 10);
      expect(s.loggedAt.minute, 30);
    });

    test('fromJson handles zero weight', () {
      final s = WorkoutSet.fromJson({
        'id': 1,
        'exercise_id': 5,
        'exercise_name': 'Bodyweight Squat',
        'set_number': 1,
        'reps': 20,
        'weight_kg': 0,
        'logged_at': '2024-03-15T10:30:00Z',
      });
      expect(s.weightKg, 0.0);
    });
  });

  group('PersonalRecord', () {
    test('formattedTime handles zero seconds', () {
      final pr = PersonalRecord(
        distanceLabel: '100m',
        runId: 1,
        runDate: DateTime.now(),
        estimatedSeconds: 10.0,
      );
      expect(pr.formattedTime, '00:10');
    });

    test('formattedTime handles exactly 1 hour', () {
      final pr = PersonalRecord(
        distanceLabel: '10k',
        runId: 1,
        runDate: DateTime.now(),
        estimatedSeconds: 3600.0,
      );
      expect(pr.formattedTime, '1:00:00');
    });

    test('formattedTime handles sub-minute', () {
      final pr = PersonalRecord(
        distanceLabel: '100m',
        runId: 1,
        runDate: DateTime.now(),
        estimatedSeconds: 45.0,
      );
      expect(pr.formattedTime, '00:45');
    });
  });

  group('ExerciseHistoryPoint edge cases', () {
    Map<String, dynamic> _json({
      String date = '2025-01-01T10:00:00Z',
      double maxWeight = 100.0,
      int repsAtMax = 5,
      int totalSets = 3,
      int totalReps = 15,
      double totalVolume = 1500.0,
    }) => {
      'workout_date': date,
      'max_weight_kg': maxWeight,
      'reps_at_max': repsAtMax,
      'total_sets': totalSets,
      'total_reps': totalReps,
      'total_volume': totalVolume,
    };

    test('estimated1RM with 0 reps returns weight', () {
      final p = ExerciseHistoryPoint.fromJson(
        _json(maxWeight: 100.0, repsAtMax: 0),
      );
      // 0 reps is <= 1, so returns raw weight
      expect(p.estimated1RM, 100.0);
    });

    test('estimated1RM with negative reps returns weight', () {
      // Edge case - shouldn't happen in practice
      final p = ExerciseHistoryPoint.fromJson(
        _json(maxWeight: 100.0, repsAtMax: -1),
      );
      expect(p.estimated1RM, 100.0);
    });

    test('estimated1RM with high reps', () {
      final p = ExerciseHistoryPoint.fromJson(
        _json(maxWeight: 50.0, repsAtMax: 50),
      );
      // 50 * (1 + 50/30) = 50 * 2.666... = 133.33...
      expect(p.estimated1RM, closeTo(133.33, 0.01));
    });

    test('totalVolume is preserved correctly', () {
      final p = ExerciseHistoryPoint.fromJson(_json(totalVolume: 12345.67));
      expect(p.totalVolume, closeTo(12345.67, 0.01));
    });
  });
}
