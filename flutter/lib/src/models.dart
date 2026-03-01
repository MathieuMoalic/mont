class RunPoint {
  final double lat;
  final double lon;
  final double? ele;
  final int? hr;
  final int? t; // seconds since run start

  RunPoint({required this.lat, required this.lon, this.ele, this.hr, this.t});

  factory RunPoint.fromJson(Map<String, dynamic> j) => RunPoint(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        ele: (j['ele'] as num?)?.toDouble(),
        hr: j['hr'] as int?,
        t: j['t'] as int?,
      );
}

class RunSummary {
  final int id;
  final DateTime startedAt;
  final int durationS;
  final double distanceM;
  final double? elevationGainM;
  final int? avgHr;
  final int? maxHr;
  final String? notes;

  RunSummary({
    required this.id,
    required this.startedAt,
    required this.durationS,
    required this.distanceM,
    this.elevationGainM,
    this.avgHr,
    this.maxHr,
    this.notes,
  });

  factory RunSummary.fromJson(Map<String, dynamic> j) => RunSummary(
        id: j['id'] as int,
        startedAt: DateTime.parse(j['started_at'] as String),
        durationS: j['duration_s'] as int,
        distanceM: (j['distance_m'] as num).toDouble(),
        elevationGainM: (j['elevation_gain_m'] as num?)?.toDouble(),
        avgHr: j['avg_hr'] as int?,
        maxHr: j['max_hr'] as int?,
        notes: j['notes'] as String?,
      );
}

class RunDetail extends RunSummary {
  final List<RunPoint> route;

  RunDetail({
    required super.id,
    required super.startedAt,
    required super.durationS,
    required super.distanceM,
    super.elevationGainM,
    super.avgHr,
    super.maxHr,
    super.notes,
    required this.route,
  });

  factory RunDetail.fromJson(Map<String, dynamic> j) => RunDetail(
        id: j['id'] as int,
        startedAt: DateTime.parse(j['started_at'] as String),
        durationS: j['duration_s'] as int,
        distanceM: (j['distance_m'] as num).toDouble(),
        elevationGainM: (j['elevation_gain_m'] as num?)?.toDouble(),
        avgHr: j['avg_hr'] as int?,
        maxHr: j['max_hr'] as int?,
        notes: j['notes'] as String?,
        route: (j['route'] as List)
            .map((e) => RunPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class WeightEntry {
  final int id;
  final DateTime measuredAt;
  final double weightKg;

  WeightEntry({required this.id, required this.measuredAt, required this.weightKg});

  factory WeightEntry.fromJson(Map<String, dynamic> j) => WeightEntry(
        id: j['id'] as int,
        measuredAt: DateTime.parse(j['measured_at'] as String),
        weightKg: (j['weight_kg'] as num).toDouble(),
      );
}

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
