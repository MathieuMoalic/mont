import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../auth.dart';
import '../models.dart';
import 'active_workout_screen.dart';
import 'exercise_history_screen.dart';
import 'login_page.dart';

class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});

  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  List<WorkoutSummary>? _workouts;
  String? _error;
  DateTime _visibleMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final workouts = await api.listWorkouts();
      if (mounted) {
        setState(() {
          _workouts = workouts;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _startWorkout() async {
    try {
      final summary = await api.createWorkout();
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ActiveWorkoutScreen(workoutId: summary.id),
        ),
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _logout() async {
    await Auth.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    }
  }

  Duration _sessionDuration(WorkoutSummary w) {
    final end = w.finishedAt ?? w.startedAt;
    return end.difference(w.startedAt);
  }

  String _durationText(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${d.inMinutes}m';
  }

  DateTime _dayKey(DateTime utc) {
    final local = utc.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  Map<DateTime, List<WorkoutSummary>> _workoutsByDay() {
    final byDay = <DateTime, List<WorkoutSummary>>{};
    for (final w in _workouts!) {
      final key = _dayKey(w.startedAt);
      (byDay[key] ??= []).add(w);
    }
    for (final sessions in byDay.values) {
      sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    }
    return byDay;
  }

  String _monthLabel(DateTime d) {
    const monthNames = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${monthNames[d.month - 1]} ${d.year}';
  }

  String _clock(DateTime utc) {
    final d = utc.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _openDaySessions(
    DateTime day,
    List<WorkoutSummary> sessions,
  ) async {
    if (sessions.length == 1) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ActiveWorkoutScreen(workoutId: sessions.first.id),
        ),
      );
      _load();
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text('${day.day}/${day.month}/${day.year}'),
                subtitle: Text('${sessions.length} sessions'),
              ),
              ...sessions.map((w) {
                final duration = _durationText(_sessionDuration(w));
                return ListTile(
                  title: Text(
                    '${w.setCount} set${w.setCount == 1 ? '' : 's'} · $duration',
                  ),
                  subtitle: Text(_clock(w.startedAt)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ActiveWorkoutScreen(workoutId: w.id),
                      ),
                    );
                    _load();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mont'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Exercise history',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const ExerciseHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startWorkout,
        icon: const Icon(Icons.add),
        label: const Text('Start Workout'),
      ),
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
    if (_workouts!.isEmpty) {
      return const Center(
        child: Text(
          'No workouts yet.\nTap + to start your first workout!',
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [_buildCalendar()],
      ),
    );
  }

  Widget _buildCalendar() {
    final byDay = _workoutsByDay();
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final leadingBlanks = firstOfMonth.weekday - 1; // Monday-first
    final cellCount = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;
    const weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final today = _dayKey(DateTime.now());

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() < 120) return;
          setState(() {
            _visibleMonth = DateTime(
              _visibleMonth.year,
              _visibleMonth.month + (velocity < 0 ? 1 : -1),
              1,
            );
          });
        },
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    setState(() {
                      _visibleMonth = DateTime(
                        _visibleMonth.year,
                        _visibleMonth.month - 1,
                        1,
                      );
                    });
                  },
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      _monthLabel(_visibleMonth),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _visibleMonth = DateTime(
                        DateTime.now().year,
                        DateTime.now().month,
                        1,
                      );
                    });
                  },
                  icon: const Icon(Icons.today_outlined),
                  tooltip: 'Jump to today',
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _visibleMonth = DateTime(
                        _visibleMonth.year,
                        _visibleMonth.month + 1,
                        1,
                      );
                    });
                  },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final day in weekdays)
                  Expanded(
                    child: Center(
                      child: Text(
                        day,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 4.0;
                final cellWidth = (constraints.maxWidth - (spacing * 6)) / 7;
                final cellHeight = (cellWidth * 1.05).clamp(54.0, 74.0);
                final aspectRatio = cellWidth / cellHeight;

                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: aspectRatio,
                  ),
                  itemCount: cellCount,
                  itemBuilder: (ctx, index) {
                    final day = firstOfMonth.subtract(
                      Duration(days: leadingBlanks - index),
                    );
                    final sessions = byDay[day] ?? [];
                    final hasSession = sessions.isNotEmpty;
                    final totalSets = sessions.fold<int>(
                      0,
                      (sum, w) => sum + w.setCount,
                    );
                    final totalDuration = sessions.fold<Duration>(
                      Duration.zero,
                      (sum, w) => sum + _sessionDuration(w),
                    );
                    final isToday = day == today;
                    final colors = Theme.of(context).colorScheme;
                    final cellColor = isToday
                        ? colors.tertiaryContainer
                        : hasSession
                        ? colors.primaryContainer
                        : colors.surfaceContainerLow;
                    final textColor = hasSession
                        ? colors.onPrimaryContainer
                        : colors.onSurface;

                    return Material(
                      color: cellColor,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: hasSession
                            ? () => _openDaySessions(day, sessions)
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: isToday
                                ? Border.all(color: colors.tertiary, width: 1.8)
                                : null,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 3),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isToday
                                        ? colors.tertiary
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: isToday
                                          ? colors.onTertiary
                                          : textColor,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                if (hasSession) ...[
                                  Text(
                                    '$totalSets sets',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      height: 1.05,
                                    ).copyWith(color: textColor),
                                  ),
                                  Text(
                                    _durationText(totalDuration),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      height: 1.05,
                                    ).copyWith(color: textColor),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
