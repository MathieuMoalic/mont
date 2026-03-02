import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'active_workout_screen.dart';

class WorkoutHeatmapScreen extends StatefulWidget {
  const WorkoutHeatmapScreen({super.key});

  @override
  State<WorkoutHeatmapScreen> createState() => _WorkoutHeatmapScreenState();
}

class _WorkoutHeatmapScreenState extends State<WorkoutHeatmapScreen> {
  List<WorkoutSummary>? _workouts;
  List<Exercise>? _exercises;
  String? _error;

  // Cached: date (midnight local) → list of workouts that day
  Map<DateTime, List<WorkoutSummary>> _byDay = {};
  // workoutId → detail (loaded lazily on tap)
  final Map<int, WorkoutDetail> _detailCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        api.listWorkouts(),
        api.listExercises(),
      ]);
      final workouts = results[0] as List<WorkoutSummary>;
      final exercises = results[1] as List<Exercise>;
      final byDay = <DateTime, List<WorkoutSummary>>{};
      for (final w in workouts) {
        if (w.finishedAt == null) continue; // skip in-progress
        final d = w.startedAt.toLocal();
        final key = DateTime(d.year, d.month, d.day);
        (byDay[key] ??= []).add(w);
      }
      if (mounted) {
        setState(() {
          _workouts = workouts;
          _exercises = exercises;
          _byDay = byDay;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Map<int, String?> get _exerciseMuscleMap {
    final map = <int, String?>{};
    for (final e in _exercises ?? []) {
      map[e.id] = e.muscleGroup;
    }
    return map;
  }

  int _maxSets() {
    if (_byDay.isEmpty) return 1;
    return _byDay.values
        .map((ws) => ws.fold(0, (s, w) => s + w.setCount))
        .reduce((a, b) => a > b ? a : b);
  }

  Color _cellColor(BuildContext context, int sets) {
    if (sets == 0) return Theme.of(context).colorScheme.surfaceContainerHighest;
    final max = _maxSets();
    final intensity = (sets / max).clamp(0.1, 1.0);
    return Theme.of(context).colorScheme.primary.withValues(alpha: intensity);
  }

  Future<void> _onDayTap(DateTime day) async {
    final workouts = _byDay[day] ?? [];
    if (workouts.isEmpty) return;

    // Load details for all workouts that day
    final muscleMap = _exerciseMuscleMap;
    final detailsFutures = workouts
        .where((w) => !_detailCache.containsKey(w.id))
        .map((w) => api.getWorkout(w.id).then((d) {
              _detailCache[w.id] = d;
            }));
    await Future.wait(detailsFutures);

    if (!mounted) return;

    // Aggregate muscle groups
    final muscleVolume = <String, double>{};
    int totalSets = 0;
    for (final w in workouts) {
      final detail = _detailCache[w.id];
      if (detail == null) continue;
      for (final s in detail.sets) {
        totalSets++;
        final mg = muscleMap[s.exerciseId] ?? 'Other';
        muscleVolume[mg] = (muscleVolume[mg] ?? 0) +
            s.weightKg * s.reps;
      }
    }

    final dateStr =
        '${day.day}/${day.month}/${day.year}';

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dateStr,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              Text(
                '$totalSets sets across ${workouts.length} workout${workouts.length > 1 ? 's' : ''}',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              if (muscleVolume.isEmpty)
                const Text('No muscle group data available.')
              else
                ...(muscleVolume.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .map((e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                  flex: 2, child: Text(e.key)),
                              Expanded(
                                flex: 3,
                                child: LinearProgressIndicator(
                                  value: e.value /
                                      muscleVolume.values.reduce(
                                          (a, b) => a > b ? a : b),
                                  minHeight: 8,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text('${e.value.toStringAsFixed(0)} kg·r',
                                  style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        )),
              const SizedBox(height: 8),
              ...workouts.map((w) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.fitness_center, size: 18),
                    title: Text('${w.setCount} sets'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ActiveWorkoutScreen(workoutId: w.id),
                        ),
                      );
                    },
                  )),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workout Heatmap')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error: $_error'),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_workouts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _buildHeatmap();
  }

  Widget _buildHeatmap() {
    // Build an 8-week grid ending today
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Start on Monday 8 weeks ago
    final daysBack = 7 * 8 + today.weekday - 1;
    final gridStart = today.subtract(Duration(days: daysBack));

    const weeks = 8;
    const days = 7;
    const cellSize = 36.0;
    const gap = 4.0;

    final weekLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const monthNames = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Day-of-week labels
          Row(
            children: [
              const SizedBox(width: 30), // month label space
              ...List.generate(
                days,
                (d) => SizedBox(
                  width: cellSize + gap,
                  child: Text(
                    weekLabels[d],
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(weeks, (weekIdx) {
            final weekStart =
                gridStart.add(Duration(days: weekIdx * 7));
            final monthStr = weekStart.day <= 7
                ? monthNames[weekStart.month]
                : '';
            return Padding(
              padding: const EdgeInsets.only(bottom: gap),
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    child: Text(
                      monthStr,
                      style:
                          const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ),
                  ...List.generate(days, (dayIdx) {
                    final date =
                        weekStart.add(Duration(days: dayIdx));
                    if (date.isAfter(today)) {
                      return SizedBox(width: cellSize + gap);
                    }
                    final workouts = _byDay[date] ?? [];
                    final sets =
                        workouts.fold(0, (s, w) => s + w.setCount);
                    return GestureDetector(
                      onTap: () => _onDayTap(date),
                      child: Padding(
                        padding: const EdgeInsets.only(right: gap),
                        child: Tooltip(
                          message: sets > 0
                              ? '${date.day}/${date.month}: $sets sets'
                              : '${date.day}/${date.month}: rest',
                          child: Container(
                            width: cellSize,
                            height: cellSize,
                            decoration: BoxDecoration(
                              color: _cellColor(context, sets),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: sets > 0
                                ? Center(
                                    child: Text(
                                      '$sets',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: sets > 0
                                            ? Colors.white
                                            : Colors.transparent,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          // Legend
          Row(
            children: [
              const Text('Less', style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(width: 6),
              ...List.generate(
                5,
                (i) => Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: i == 0
                          ? Theme.of(context).colorScheme.surfaceContainerHighest
                          : Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.2 + i * 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text('More', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 24),
          // Weekly volume summary
          _buildWeeklySummary(gridStart, today),
        ],
      ),
    );
  }

  Widget _buildWeeklySummary(DateTime gridStart, DateTime today) {
    final rows = <Widget>[];
    for (int w = 7; w >= 0; w--) {
      final weekStart = gridStart.add(Duration(days: w * 7));
      final weekEnd = weekStart.add(const Duration(days: 6));
      int totalSets = 0;
      int workoutDays = 0;
      for (int d = 0; d < 7; d++) {
        final day = weekStart.add(Duration(days: d));
        if (day.isAfter(today)) break;
        final ws = _byDay[day] ?? [];
        if (ws.isNotEmpty) workoutDays++;
        totalSets += ws.fold(0, (s, wk) => s + wk.setCount);
      }
      if (totalSets == 0) continue;
      final label = w == 0
          ? 'This week'
          : w == 1
              ? 'Last week'
              : '${weekEnd.day}/${weekEnd.month}';
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
                width: 90,
                child: Text(label,
                    style: const TextStyle(fontSize: 13))),
            Text('$workoutDays day${workoutDays > 1 ? 's' : ''}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const Spacer(),
            Text('$totalSets sets',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Weekly summary',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...rows,
      ],
    );
  }
}
