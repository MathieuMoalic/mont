class Exercise {
  final int id;
  final String name;
  final String? notes;

  Exercise({required this.id, required this.name, this.notes});

  factory Exercise.fromJson(Map<String, dynamic> j) => Exercise(
        id: j['id'] as int,
        name: j['name'] as String,
        notes: j['notes'] as String?,
      );
}

class WorkoutSummary {
  final int id;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? notes;
  final int setCount;

  WorkoutSummary({
    required this.id,
    required this.startedAt,
    this.finishedAt,
    this.notes,
    required this.setCount,
  });

  bool get isActive => finishedAt == null;

  factory WorkoutSummary.fromJson(Map<String, dynamic> j) => WorkoutSummary(
        id: j['id'] as int,
        startedAt: DateTime.parse(j['started_at'] as String),
        finishedAt: j['finished_at'] != null
            ? DateTime.parse(j['finished_at'] as String)
            : null,
        notes: j['notes'] as String?,
        setCount: j['set_count'] as int,
      );
}

class WorkoutSet {
  final int id;
  final int exerciseId;
  final String exerciseName;
  final int setNumber;
  final int reps;
  final double weightKg;

  WorkoutSet({
    required this.id,
    required this.exerciseId,
    required this.exerciseName,
    required this.setNumber,
    required this.reps,
    required this.weightKg,
  });

  factory WorkoutSet.fromJson(Map<String, dynamic> j) => WorkoutSet(
        id: j['id'] as int,
        exerciseId: j['exercise_id'] as int,
        exerciseName: j['exercise_name'] as String,
        setNumber: j['set_number'] as int,
        reps: j['reps'] as int,
        weightKg: (j['weight_kg'] as num).toDouble(),
      );
}

class WorkoutDetail {
  final int id;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? notes;
  final List<WorkoutSet> sets;

  WorkoutDetail({
    required this.id,
    required this.startedAt,
    this.finishedAt,
    this.notes,
    required this.sets,
  });

  bool get isActive => finishedAt == null;

  factory WorkoutDetail.fromJson(Map<String, dynamic> j) => WorkoutDetail(
        id: j['id'] as int,
        startedAt: DateTime.parse(j['started_at'] as String),
        finishedAt: j['finished_at'] != null
            ? DateTime.parse(j['finished_at'] as String)
            : null,
        notes: j['notes'] as String?,
        sets: (j['sets'] as List)
            .map((s) => WorkoutSet.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}
