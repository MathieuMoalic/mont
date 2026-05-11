class RunPoint {
  final double lat;
  final double lon;
  final double? ele;
  final int? hr;
  final int? t; // seconds since run start
  final int? cad; // steps per minute

  RunPoint({
    required this.lat,
    required this.lon,
    this.ele,
    this.hr,
    this.t,
    this.cad,
  });

  factory RunPoint.fromJson(Map<String, dynamic> j) => RunPoint(
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    ele: (j['ele'] as num?)?.toDouble(),
    hr: j['hr'] as int?,
    t: j['t'] as int?,
    cad: (j['cad'] as num?)?.toInt(),
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
  final bool isInvalid;
  final int? avgCadence;
  final double? avgStrideM;
  final double? weatherTempC;
  final double? weatherWindKph;
  final double? weatherPrecipMm;
  final int? weatherCode;
  final int? calories;

  RunSummary({
    required this.id,
    required this.startedAt,
    required this.durationS,
    required this.distanceM,
    this.elevationGainM,
    this.avgHr,
    this.maxHr,
    this.notes,
    this.isInvalid = false,
    this.avgCadence,
    this.avgStrideM,
    this.weatherTempC,
    this.weatherWindKph,
    this.weatherPrecipMm,
    this.weatherCode,
    this.calories,
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
    isInvalid: (j['is_invalid'] as bool?) ?? false,
    avgCadence: (j['avg_cadence'] as num?)?.toInt(),
    avgStrideM: (j['avg_stride_m'] as num?)?.toDouble(),
    weatherTempC: (j['weather_temp_c'] as num?)?.toDouble(),
    weatherWindKph: (j['weather_wind_kph'] as num?)?.toDouble(),
    weatherPrecipMm: (j['weather_precip_mm'] as num?)?.toDouble(),
    weatherCode: (j['weather_code'] as num?)?.toInt(),
    calories: (j['calories'] as num?)?.toInt(),
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
    super.isInvalid,
    super.avgCadence,
    super.avgStrideM,
    super.weatherTempC,
    super.weatherWindKph,
    super.weatherPrecipMm,
    super.weatherCode,
    super.calories,
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
    isInvalid: (j['is_invalid'] as bool?) ?? false,
    avgCadence: (j['avg_cadence'] as num?)?.toInt(),
    avgStrideM: (j['avg_stride_m'] as num?)?.toDouble(),
    weatherTempC: (j['weather_temp_c'] as num?)?.toDouble(),
    weatherWindKph: (j['weather_wind_kph'] as num?)?.toDouble(),
    weatherPrecipMm: (j['weather_precip_mm'] as num?)?.toDouble(),
    weatherCode: (j['weather_code'] as num?)?.toInt(),
    calories: (j['calories'] as num?)?.toInt(),
    route: (j['route'] as List)
        .map((e) => RunPoint.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class PersonalRecord {
  final String distanceLabel;
  final int runId;
  final DateTime runDate;
  final double estimatedSeconds;

  PersonalRecord({
    required this.distanceLabel,
    required this.runId,
    required this.runDate,
    required this.estimatedSeconds,
  });

  factory PersonalRecord.fromJson(Map<String, dynamic> j) => PersonalRecord(
    distanceLabel: j['distance_label'] as String,
    runId: j['run_id'] as int,
    runDate: DateTime.parse(j['run_date'] as String),
    estimatedSeconds: (j['estimated_seconds'] as num).toDouble(),
  );

  String get formattedTime {
    final total = estimatedSeconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class WeightEntry {
  final int id;
  final DateTime measuredAt;
  final double weightKg;

  WeightEntry({
    required this.id,
    required this.measuredAt,
    required this.weightKg,
  });

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
  final String? muscleGroup;
  final String? equipment;

  Exercise({
    required this.id,
    required this.name,
    this.notes,
    this.muscleGroup,
    this.equipment,
  });

  factory Exercise.fromJson(Map<String, dynamic> j) => Exercise(
    id: j['id'] as int,
    name: j['name'] as String,
    notes: j['notes'] as String?,
    muscleGroup: j['muscle_group'] as String?,
    equipment: j['equipment'] as String?,
  );

  String get displayName {
    if (equipment != null && equipment!.isNotEmpty) {
      return '$name ($equipment)';
    }
    return name;
  }
}

class MuscleGroupCategory {
  final String name;
  final String? colorHex;

  MuscleGroupCategory({required this.name, this.colorHex});

  factory MuscleGroupCategory.fromJson(Map<String, dynamic> j) =>
      MuscleGroupCategory(
        name: j['name'] as String,
        colorHex: j['color_hex'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (colorHex != null) 'color_hex': colorHex,
  };
}

class ExerciseCategories {
  final List<MuscleGroupCategory> muscleGroups;
  final List<String> equipment;

  ExerciseCategories({required this.muscleGroups, required this.equipment});

  factory ExerciseCategories.fromJson(Map<String, dynamic> j) =>
      ExerciseCategories(
        muscleGroups: ((j['muscle_groups'] as List?) ?? const [])
            .map((e) => MuscleGroupCategory.fromJson(e as Map<String, dynamic>))
            .toList(),
        equipment: ((j['equipment'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'muscle_groups': muscleGroups.map((e) => e.toJson()).toList(),
    'equipment': equipment,
  };
}

class CalorieEntry {
  final int id;
  final String day; // YYYY-MM-DD
  final String mealPeriod; // morning|afternoon|evening
  final String name;
  final double proteinPer100G;
  final double carbsPer100G;
  final double fatsPer100G;
  final double weightG;
  final double proteinG;
  final double carbsG;
  final double fatsG;
  final int kcal;

  CalorieEntry({
    required this.id,
    required this.day,
    required this.mealPeriod,
    required this.name,
    required this.proteinPer100G,
    required this.carbsPer100G,
    required this.fatsPer100G,
    required this.weightG,
    required this.proteinG,
    required this.carbsG,
    required this.fatsG,
    required this.kcal,
  });

  factory CalorieEntry.fromJson(Map<String, dynamic> j) => CalorieEntry(
    id: j['id'] as int,
    day: j['day'] as String,
    mealPeriod: j['meal_period'] as String,
    name: j['name'] as String,
    proteinPer100G: (j['protein_per_100g'] as num).toDouble(),
    carbsPer100G: (j['carbs_per_100g'] as num).toDouble(),
    fatsPer100G: (j['fats_per_100g'] as num).toDouble(),
    weightG: (j['weight_g'] as num).toDouble(),
    proteinG: (j['protein_g'] as num).toDouble(),
    carbsG: (j['carbs_g'] as num).toDouble(),
    fatsG: (j['fats_g'] as num).toDouble(),
    kcal: j['kcal'] as int,
  );
}

class CalorieExerciseEntry {
  final int id;
  final String day;
  final String name;
  final int kcal;

  CalorieExerciseEntry({
    required this.id,
    required this.day,
    required this.name,
    required this.kcal,
  });

  factory CalorieExerciseEntry.fromJson(Map<String, dynamic> j) =>
      CalorieExerciseEntry(
        id: j['id'] as int,
        day: j['day'] as String,
        name: j['name'] as String,
        kcal: j['kcal'] as int,
      );
}

class NutritionTargets {
  final double proteinG;
  final double carbsG;
  final double fatsG;

  NutritionTargets({
    required this.proteinG,
    required this.carbsG,
    required this.fatsG,
  });

  factory NutritionTargets.fromJson(Map<String, dynamic> j) => NutritionTargets(
    proteinG: (j['protein_g'] as num).toDouble(),
    carbsG: (j['carbs_g'] as num).toDouble(),
    fatsG: (j['fats_g'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fats_g': fatsG,
  };
}

class SavedFood {
  final int id;
  final String name;
  final double proteinPer100G;
  final double carbsPer100G;
  final double fatsPer100G;
  final double lastWeightG;

  SavedFood({
    required this.id,
    required this.name,
    required this.proteinPer100G,
    required this.carbsPer100G,
    required this.fatsPer100G,
    required this.lastWeightG,
  });

  factory SavedFood.fromJson(Map<String, dynamic> j) => SavedFood(
    id: j['id'] as int,
    name: j['name'] as String,
    proteinPer100G: (j['protein_per_100g'] as num).toDouble(),
    carbsPer100G: (j['carbs_per_100g'] as num).toDouble(),
    fatsPer100G: (j['fats_per_100g'] as num).toDouble(),
    lastWeightG: (j['last_weight_g'] as num).toDouble(),
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

  factory WorkoutSummary.fromJson(Map<String, dynamic> j) {
    final startedAtStr = j['started_at'] as String;
    final finishedAtStr = j['finished_at'] as String?;
    return WorkoutSummary(
      id: j['id'] as int,
      startedAt: DateTime.parse(
        startedAtStr.endsWith('Z') ? startedAtStr : '${startedAtStr}Z',
      ),
      finishedAt: finishedAtStr != null
          ? DateTime.parse(
              finishedAtStr.endsWith('Z') ? finishedAtStr : '${finishedAtStr}Z',
            )
          : null,
      notes: j['notes'] as String?,
      setCount: j['set_count'] as int,
    );
  }
}

class WorkoutSet {
  final int id;
  final int exerciseId;
  final String exerciseName;
  final String? muscleGroup;
  final int setNumber;
  final int reps;
  final double weightKg;
  final DateTime loggedAt;

  WorkoutSet({
    required this.id,
    required this.exerciseId,
    required this.exerciseName,
    this.muscleGroup,
    required this.setNumber,
    required this.reps,
    required this.weightKg,
    required this.loggedAt,
  });

  factory WorkoutSet.fromJson(Map<String, dynamic> j) {
    final loggedAtStr = j['logged_at'] as String;
    return WorkoutSet(
      id: j['id'] as int,
      exerciseId: j['exercise_id'] as int,
      exerciseName: j['exercise_name'] as String,
      muscleGroup: j['muscle_group'] as String?,
      setNumber: j['set_number'] as int,
      reps: j['reps'] as int,
      weightKg: (j['weight_kg'] as num).toDouble(),
      loggedAt: DateTime.parse(
        loggedAtStr.endsWith('Z') ? loggedAtStr : '${loggedAtStr}Z',
      ),
    );
  }
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

  factory WorkoutDetail.fromJson(Map<String, dynamic> j) {
    final startedAtStr = j['started_at'] as String;
    final finishedAtStr = j['finished_at'] as String?;
    return WorkoutDetail(
      id: j['id'] as int,
      startedAt: DateTime.parse(
        startedAtStr.endsWith('Z') ? startedAtStr : '${startedAtStr}Z',
      ),
      finishedAt: finishedAtStr != null
          ? DateTime.parse(
              finishedAtStr.endsWith('Z') ? finishedAtStr : '${finishedAtStr}Z',
            )
          : null,
      notes: j['notes'] as String?,
      sets: (j['sets'] as List)
          .map((s) => WorkoutSet.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}

class DailyHealth {
  final String date;
  final int? avgHr;
  final int? minHr;
  final int? maxHr;
  final double? hrvRmssd;
  final int? steps;

  DailyHealth({
    required this.date,
    this.avgHr,
    this.minHr,
    this.maxHr,
    this.hrvRmssd,
    this.steps,
  });

  factory DailyHealth.fromJson(Map<String, dynamic> j) => DailyHealth(
    date: j['date'] as String,
    avgHr: j['avg_hr'] as int?,
    minHr: j['min_hr'] as int?,
    maxHr: j['max_hr'] as int?,
    hrvRmssd: (j['hrv_rmssd'] as num?)?.toDouble(),
    steps: j['steps'] as int?,
  );
}

class ExerciseHistoryPoint {
  final DateTime workoutDate;
  final double maxWeightKg;
  final int repsAtMax;
  final int totalSets;
  final int totalReps;
  final double totalVolume;

  ExerciseHistoryPoint({
    required this.workoutDate,
    required this.maxWeightKg,
    required this.repsAtMax,
    required this.totalSets,
    required this.totalReps,
    required this.totalVolume,
  });

  factory ExerciseHistoryPoint.fromJson(Map<String, dynamic> j) =>
      ExerciseHistoryPoint(
        workoutDate: DateTime.parse(j['workout_date'] as String),
        maxWeightKg: (j['max_weight_kg'] as num).toDouble(),
        repsAtMax: j['reps_at_max'] as int,
        totalSets: j['total_sets'] as int,
        totalReps: j['total_reps'] as int,
        totalVolume: (j['total_volume'] as num).toDouble(),
      );

  /// Epley estimated 1-rep max: weight × (1 + reps / 30).
  double get estimated1RM =>
      repsAtMax <= 1 ? maxWeightKg : maxWeightKg * (1 + repsAtMax / 30.0);
}

class ExercisePersonalRecord {
  final double maxWeightKg;
  final DateTime maxWeightDate;
  final int maxWeightReps;
  final int maxReps;
  final DateTime maxRepsDate;
  final double maxRepsWeightKg;
  final double maxVolumeWorkout;
  final DateTime maxVolumeDate;
  final double bestSetScore;
  final DateTime bestSetDate;
  final double bestSetWeightKg;
  final int bestSetReps;

  ExercisePersonalRecord({
    required this.maxWeightKg,
    required this.maxWeightDate,
    required this.maxWeightReps,
    required this.maxReps,
    required this.maxRepsDate,
    required this.maxRepsWeightKg,
    required this.maxVolumeWorkout,
    required this.maxVolumeDate,
    required this.bestSetScore,
    required this.bestSetDate,
    required this.bestSetWeightKg,
    required this.bestSetReps,
  });

  factory ExercisePersonalRecord.fromJson(Map<String, dynamic> j) =>
      ExercisePersonalRecord(
        maxWeightKg: (j['max_weight_kg'] as num).toDouble(),
        maxWeightDate: DateTime.parse(j['max_weight_date'] as String),
        maxWeightReps: j['max_weight_reps'] as int,
        maxReps: j['max_reps'] as int,
        maxRepsDate: DateTime.parse(j['max_reps_date'] as String),
        maxRepsWeightKg: (j['max_reps_weight_kg'] as num).toDouble(),
        maxVolumeWorkout: (j['max_volume_workout'] as num).toDouble(),
        maxVolumeDate: DateTime.parse(j['max_volume_date'] as String),
        bestSetScore: (j['best_set_score'] as num).toDouble(),
        bestSetDate: DateTime.parse(j['best_set_date'] as String),
        bestSetWeightKg: (j['best_set_weight_kg'] as num).toDouble(),
        bestSetReps: j['best_set_reps'] as int,
      );
}
