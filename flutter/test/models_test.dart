import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/models.dart';

void main() {
  group('Exercise', () {
    test('fromJson parses all fields', () {
      final e = Exercise.fromJson({'id': 1, 'name': 'Bench Press', 'notes': 'Use a spotter'});
      expect(e.id, 1);
      expect(e.name, 'Bench Press');
      expect(e.notes, 'Use a spotter');
    });

    test('fromJson handles null notes', () {
      final e = Exercise.fromJson({'id': 2, 'name': 'Squat', 'notes': null});
      expect(e.notes, isNull);
    });

    test('fromJson parses muscle_group', () {
      final e = Exercise.fromJson({
        'id': 3,
        'name': 'Bench Press',
        'notes': null,
        'muscle_group': 'Chest',
      });
      expect(e.muscleGroup, 'Chest');
    });

    test('fromJson handles null muscle_group', () {
      final e = Exercise.fromJson({'id': 4, 'name': 'Unknown', 'notes': null});
      expect(e.muscleGroup, isNull);
    });
  });

  group('PersonalRecord', () {
    Map<String, dynamic> _prJson({
      String label = '5k',
      int runId = 42,
      String runDate = '2024-03-15T09:00:00Z',
      double estimatedSeconds = 1200.0,
    }) =>
        {
          'distance_label': label,
          'run_id': runId,
          'run_date': runDate,
          'estimated_seconds': estimatedSeconds,
        };

    test('fromJson parses all fields', () {
      final pr = PersonalRecord.fromJson(_prJson());
      expect(pr.distanceLabel, '5k');
      expect(pr.runId, 42);
      expect(pr.estimatedSeconds, 1200.0);
    });

    test('formattedTime formats minutes:seconds under 1 hour', () {
      // 1200s = 20:00
      final pr = PersonalRecord.fromJson(_prJson(estimatedSeconds: 1200.0));
      expect(pr.formattedTime, '20:00');
    });

    test('formattedTime formats h:mm:ss over 1 hour', () {
      // 3661s = 1:01:01
      final pr = PersonalRecord.fromJson(_prJson(estimatedSeconds: 3661.0));
      expect(pr.formattedTime, '1:01:01');
    });

    test('formattedTime pads seconds', () {
      // 605s = 10:05
      final pr = PersonalRecord.fromJson(_prJson(estimatedSeconds: 605.0));
      expect(pr.formattedTime, '10:05');
    });

    test('formattedTime handles marathon-length time', () {
      // 14400s = 4:00:00
      final pr = PersonalRecord.fromJson(_prJson(estimatedSeconds: 14400.0));
      expect(pr.formattedTime, '4:00:00');
    });
  });

  group('RunSummary', () {
    Map<String, dynamic> _runJson({bool? isInvalid}) => {
          'id': 1,
          'started_at': '2024-03-15T09:00:00Z',
          'duration_s': 1800,
          'distance_m': 5000.0,
          'elevation_gain_m': null,
          'avg_hr': null,
          'max_hr': null,
          'notes': null,
          if (isInvalid != null) 'is_invalid': isInvalid,
        };

    test('isInvalid defaults to false when field missing', () {
      final r = RunSummary.fromJson(_runJson());
      expect(r.isInvalid, false);
    });

    test('isInvalid is true when field is true', () {
      final r = RunSummary.fromJson(_runJson(isInvalid: true));
      expect(r.isInvalid, true);
    });

    test('isInvalid is false when field is false', () {
      final r = RunSummary.fromJson(_runJson(isInvalid: false));
      expect(r.isInvalid, false);
    });
  });

  group('WorkoutSummary', () {
    test('fromJson parses active workout', () {
      final w = WorkoutSummary.fromJson({
        'id': 10,
        'started_at': '2026-03-01T10:00:00Z',
        'finished_at': null,
        'notes': null,
        'set_count': 0,
      });
      expect(w.id, 10);
      expect(w.finishedAt, isNull);
      expect(w.setCount, 0);
      expect(w.isActive, isTrue);
    });

    test('fromJson parses finished workout', () {
      final w = WorkoutSummary.fromJson({
        'id': 11,
        'started_at': '2026-03-01T10:00:00Z',
        'finished_at': '2026-03-01T11:30:00Z',
        'notes': null,
        'set_count': 9,
      });
      expect(w.finishedAt, isNotNull);
      expect(w.setCount, 9);
      expect(w.isActive, isFalse);
    });

    test('isActive is true when finishedAt is null', () {
      final w = WorkoutSummary.fromJson({
        'id': 1, 'started_at': '2026-01-01T00:00:00Z',
        'finished_at': null, 'notes': null, 'set_count': 3,
      });
      expect(w.isActive, isTrue);
    });
  });

  group('WorkoutSet', () {
    test('fromJson parses integer weight', () {
      final s = WorkoutSet.fromJson({
        'id': 1, 'exercise_id': 2, 'exercise_name': 'Deadlift',
        'set_number': 1, 'reps': 5, 'weight_kg': 140,
      });
      expect(s.weightKg, 140.0);
      expect(s.reps, 5);
      expect(s.exerciseName, 'Deadlift');
    });

    test('fromJson parses fractional weight', () {
      final s = WorkoutSet.fromJson({
        'id': 2, 'exercise_id': 3, 'exercise_name': 'Lateral Raise',
        'set_number': 2, 'reps': 15, 'weight_kg': 7.5,
      });
      expect(s.weightKg, 7.5);
    });
  });

  group('WorkoutDetail', () {
    test('fromJson parses detail with sets', () {
      final d = WorkoutDetail.fromJson({
        'id': 5,
        'started_at': '2026-03-01T09:00:00Z',
        'finished_at': null,
        'notes': null,
        'sets': [
          {
            'id': 1, 'exercise_id': 1, 'exercise_name': 'Squat',
            'set_number': 1, 'reps': 8, 'weight_kg': 100.0,
          },
          {
            'id': 2, 'exercise_id': 1, 'exercise_name': 'Squat',
            'set_number': 2, 'reps': 8, 'weight_kg': 100.0,
          },
        ],
      });
      expect(d.id, 5);
      expect(d.sets.length, 2);
      expect(d.sets[0].exerciseName, 'Squat');
      expect(d.isActive, isTrue);
    });

    test('fromJson parses detail with empty sets', () {
      final d = WorkoutDetail.fromJson({
        'id': 6, 'started_at': '2026-03-01T09:00:00Z',
        'finished_at': null, 'notes': null, 'sets': [],
      });
      expect(d.sets, isEmpty);
    });

    test('isActive false when finished', () {
      final d = WorkoutDetail.fromJson({
        'id': 7,
        'started_at': '2026-03-01T09:00:00Z',
        'finished_at': '2026-03-01T10:30:00Z',
        'notes': null,
        'sets': [],
      });
      expect(d.isActive, isFalse);
    });
  });

  group('TemplateSummary', () {
    test('fromJson parses all fields', () {
      final t = TemplateSummary.fromJson(
          {'id': 1, 'name': 'Push Day', 'notes': 'chest + shoulders', 'set_count': 6});
      expect(t.id, 1);
      expect(t.name, 'Push Day');
      expect(t.notes, 'chest + shoulders');
      expect(t.setCount, 6);
    });

    test('fromJson handles null notes', () {
      final t = TemplateSummary.fromJson(
          {'id': 2, 'name': 'Leg Day', 'notes': null, 'set_count': 0});
      expect(t.notes, isNull);
      expect(t.setCount, 0);
    });
  });

  group('TemplateSet', () {
    test('fromJson parses integer weight', () {
      final s = TemplateSet.fromJson({
        'id': 1, 'exercise_id': 5, 'exercise_name': 'Squat',
        'set_number': 1, 'target_reps': 5, 'target_weight_kg': 100,
      });
      expect(s.targetWeightKg, 100.0);
      expect(s.targetReps, 5);
      expect(s.exerciseName, 'Squat');
    });

    test('fromJson parses fractional weight', () {
      final s = TemplateSet.fromJson({
        'id': 1, 'exercise_id': 1, 'exercise_name': 'OHP',
        'set_number': 1, 'target_reps': 8, 'target_weight_kg': 52.5,
      });
      expect(s.targetWeightKg, 52.5);
    });
  });

  group('TemplateDetail', () {
    test('fromJson parses detail with sets', () {
      final d = TemplateDetail.fromJson({
        'id': 3, 'name': 'Full Body', 'notes': null,
        'sets': [
          {'id': 1, 'exercise_id': 1, 'exercise_name': 'Squat', 'set_number': 1, 'target_reps': 5, 'target_weight_kg': 100.0},
          {'id': 2, 'exercise_id': 2, 'exercise_name': 'Bench', 'set_number': 1, 'target_reps': 8, 'target_weight_kg': 80.0},
        ],
      });
      expect(d.id, 3);
      expect(d.sets.length, 2);
      expect(d.sets[0].exerciseName, 'Squat');
      expect(d.sets[1].targetWeightKg, 80.0);
    });

    test('fromJson parses empty sets', () {
      final d = TemplateDetail.fromJson({'id': 1, 'name': 'Empty', 'notes': null, 'sets': []});
      expect(d.sets, isEmpty);
    });
  });

  group('ExerciseHistoryPoint', () {
    Map<String, dynamic> _json({
      String date = '2025-01-01T10:00:00Z',
      double maxWeight = 100.0,
      int repsAtMax = 5,
      int totalSets = 3,
      int totalReps = 15,
      double totalVolume = 1500.0,
    }) =>
        {
          'workout_date': date,
          'max_weight_kg': maxWeight,
          'reps_at_max': repsAtMax,
          'total_sets': totalSets,
          'total_reps': totalReps,
          'total_volume': totalVolume,
        };

    test('fromJson parses all fields', () {
      final p = ExerciseHistoryPoint.fromJson(_json());
      expect(p.maxWeightKg, 100.0);
      expect(p.repsAtMax, 5);
      expect(p.totalSets, 3);
      expect(p.totalReps, 15);
      expect(p.totalVolume, 1500.0);
    });

    test('estimated1RM uses Epley formula: weight * (1 + reps/30)', () {
      final p = ExerciseHistoryPoint.fromJson(_json(maxWeight: 100.0, repsAtMax: 10));
      // 100 * (1 + 10/30) = 100 * 1.333... ≈ 133.33
      expect(p.estimated1RM, closeTo(133.33, 0.01));
    });

    test('estimated1RM with 1 rep returns raw weight', () {
      final p = ExerciseHistoryPoint.fromJson(_json(maxWeight: 120.0, repsAtMax: 1));
      expect(p.estimated1RM, 120.0);
    });

    test('estimated1RM with 5 reps', () {
      final p = ExerciseHistoryPoint.fromJson(_json(maxWeight: 100.0, repsAtMax: 5));
      // 100 * (1 + 5/30) = 100 * 1.1666... ≈ 116.67
      expect(p.estimated1RM, closeTo(116.67, 0.01));
    });

    test('estimated1RM with 30 reps doubles the weight', () {
      final p = ExerciseHistoryPoint.fromJson(_json(maxWeight: 50.0, repsAtMax: 30));
      // 50 * (1 + 30/30) = 50 * 2 = 100
      expect(p.estimated1RM, closeTo(100.0, 0.01));
    });
  });
}
