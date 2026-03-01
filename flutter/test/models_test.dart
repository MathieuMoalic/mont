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
}
