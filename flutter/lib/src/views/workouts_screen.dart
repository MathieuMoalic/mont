import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'active_workout_screen.dart';
import 'exercise_history_screen.dart';
import 'run_heatmap_screen.dart';
import 'run_stats_screen.dart';
import 'runs_screen.dart';

enum _WorkoutsMenuAction {
  exerciseHistory,
  runList,
  runHeatmap,
  runStats,
  runSync,
  runResetAndResync,
}

class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});

  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  List<WorkoutSummary>? _workouts;
  List<RunSummary> _runs = [];
  Set<DateTime> _hyroxDays = <DateTime>{};
  Map<DateTime, double> _runDistanceMByDay = <DateTime, double>{};
  String? _error;
  final ScrollController _calendarScrollController = ScrollController();
  DateTime? _calendarFirstWeek;
  bool _isExtendingPast = false;
  bool _didInitialCalendarJump = false;

  static const double _calendarCellHeight = 62.0;
  static const double _calendarSpacing = 4.0;
  static const int _weeksToPrependPerBatch = 24;

  @override
  void initState() {
    super.initState();
    _calendarScrollController.addListener(_onCalendarScroll);
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        api.listWorkouts(),
        api.listHyroxDays(),
        api.listRuns(),
      ]);
      final workouts = results[0] as List<WorkoutSummary>;
      final hyroxDays = results[1] as List<HyroxDay>;
      final runs = results[2] as List<RunSummary>;
      final hyroxDayKeys = hyroxDays
          .map((entry) => _dayFromIso(entry.day))
          .toSet();
      final runDistanceByDay = <DateTime, double>{};
      for (final run in runs) {
        final day = _dayKey(run.startedAt);
        runDistanceByDay[day] = (runDistanceByDay[day] ?? 0) + run.distanceM;
      }
      final runDayKeys = runDistanceByDay.keys;

      final allDays = <DateTime>[
        ...workouts.map((w) => _dayKey(w.startedAt)),
        ...hyroxDayKeys,
        ...runDayKeys,
      ];
      final oldestWeek = allDays.isEmpty
          ? _weekStart(DateTime.now())
          : _weekStart(allDays.reduce((a, b) => a.isBefore(b) ? a : b));
      if (mounted) {
        setState(() {
          _workouts = workouts;
          _runs = runs;
          _hyroxDays = hyroxDayKeys;
          _runDistanceMByDay = runDistanceByDay;
          if (_calendarFirstWeek == null ||
              _calendarFirstWeek!.isAfter(oldestWeek)) {
            _calendarFirstWeek = oldestWeek;
          }
          _error = null;
        });
        if (!_didInitialCalendarJump) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_calendarScrollController.hasClients) return;
            _calendarScrollController.jumpTo(
              _calendarScrollController.position.maxScrollExtent,
            );
            _didInitialCalendarJump = true;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  DateTime _weekStart(DateTime d) {
    final day = _dayKey(d);
    return day.subtract(Duration(days: day.weekday - 1)); // Monday
  }

  void _onCalendarScroll() {
    if (!_calendarScrollController.hasClients || _isExtendingPast) return;
    if (_calendarScrollController.position.pixels > 180) return;
    _extendCalendarPast();
  }

  void _extendCalendarPast() {
    final firstWeek = _calendarFirstWeek;
    if (firstWeek == null) return;
    _isExtendingPast = true;

    final previousOffset = _calendarScrollController.offset;
    setState(() {
      _calendarFirstWeek = firstWeek.subtract(
        const Duration(days: _weeksToPrependPerBatch * 7),
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _calendarScrollController.hasClients) {
        final addedExtent =
            _weeksToPrependPerBatch * (_calendarCellHeight + _calendarSpacing);
        _calendarScrollController.jumpTo(previousOffset + addedExtent);
      }
      _isExtendingPast = false;
    });
  }

  @override
  void dispose() {
    _calendarScrollController.removeListener(_onCalendarScroll);
    _calendarScrollController.dispose();
    super.dispose();
  }

  Future<void> _startWorkoutFromDay(DateTime day) async {
    final today = _dayKey(DateTime.now());
    if (day != today) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You can only start a workout for today'),
          ),
        );
      }
      return;
    }

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

  Future<void> _deleteWorkoutFromDay(int workoutId) async {
    if (!mounted) return;
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Delete workout?'),
              content: const Text(
                'This workout and all its sets will be permanently removed.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!shouldDelete) return;

    try {
      await api.deleteWorkout(workoutId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _syncGadgetbridge() async {
    try {
      final result = await api.syncGadgetbridge();
      await _load();
      if (!mounted) return;
      final imported = result['imported'] as int? ?? 0;
      final errs = (result['errors'] as List?)?.length ?? 0;
      final msg = errs > 0
          ? 'Synced: $imported runs, $errs errors'
          : 'Synced: $imported runs updated';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
    }
  }

  Future<void> _resetAndResyncRuns() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all runs?'),
        content: const Text(
          'This will delete every run and reimport them from Gadgetbridge. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset & Reimport'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteAllRuns();
      await _syncGadgetbridge();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reset failed: $e')));
    }
  }

  Future<void> _onMenuAction(_WorkoutsMenuAction action) async {
    switch (action) {
      case _WorkoutsMenuAction.exerciseHistory:
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const ExerciseHistoryScreen()),
        );
        break;
      case _WorkoutsMenuAction.runList:
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const RunsScreen()),
        );
        await _load();
        break;
      case _WorkoutsMenuAction.runHeatmap:
        if (_runs.isEmpty || !mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const RunHeatmapScreen()),
        );
        break;
      case _WorkoutsMenuAction.runStats:
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const RunStatsScreen()),
        );
        break;
      case _WorkoutsMenuAction.runSync:
        await _syncGadgetbridge();
        break;
      case _WorkoutsMenuAction.runResetAndResync:
        await _resetAndResyncRuns();
        break;
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

  DateTime _dayFromIso(String day) {
    final parsed = DateTime.parse(day);
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  String _dayToIso(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
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

  String _clock(DateTime utc) {
    final d = utc.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _toggleHyroxDay(DateTime day) async {
    final today = _dayKey(DateTime.now());
    if (day.isAfter(today)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hyrox can only be added for today or past days'),
          ),
        );
      }
      return;
    }

    try {
      final isHyrox = _hyroxDays.contains(day);
      if (isHyrox) {
        await api.deleteHyroxDay(_dayToIso(day));
      } else {
        await api.upsertHyroxDay(_dayToIso(day));
      }
      if (mounted) {
        setState(() {
          if (isHyrox) {
            _hyroxDays.remove(day);
          } else {
            _hyroxDays.add(day);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openWorkout(int workoutId) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActiveWorkoutScreen(workoutId: workoutId),
      ),
    );
    _load();
  }

  Future<void> _openDayActions(
    DateTime day,
    List<WorkoutSummary> sessions,
    bool hasRun,
  ) async {
    if (!mounted) return;
    final hasHyrox = _hyroxDays.contains(day);
    final today = _dayKey(DateTime.now());
    final canToggleHyrox = !day.isAfter(today);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text('${day.day}/${day.month}/${day.year}'),
                subtitle: Text(
                  sessions.isEmpty
                      ? [
                          if (hasHyrox) 'Hyrox',
                          if (hasRun) 'Run',
                          if (!hasHyrox && !hasRun) 'No sessions',
                        ].join(' · ')
                      : '${sessions.length} workout ${sessions.length == 1 ? 'session' : 'sessions'}',
                ),
              ),
              if (sessions.isNotEmpty)
                const ListTile(
                  dense: true,
                  title: Text('Workouts'),
                  visualDensity: VisualDensity(vertical: -4),
                ),
              if (day == today)
                ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: const Text('Start workout now'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _startWorkoutFromDay(day);
                  },
                ),
              ...sessions.map((w) {
                final duration = _durationText(_sessionDuration(w));
                return ListTile(
                  title: Text(
                    '${w.setCount} set${w.setCount == 1 ? '' : 's'} · $duration',
                  ),
                  subtitle: Text(_clock(w.startedAt)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete workout',
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _deleteWorkoutFromDay(w.id);
                    },
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _openWorkout(w.id);
                  },
                );
              }),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  hasHyrox ? Icons.check_box : Icons.check_box_outline_blank,
                ),
                title: Text(hasHyrox ? 'Remove Hyrox' : 'Mark as Hyrox'),
                subtitle: canToggleHyrox
                    ? null
                    : const Text(
                        'Hyrox is only allowed for today or past days',
                      ),
                enabled: canToggleHyrox,
                onTap: canToggleHyrox
                    ? () async {
                        Navigator.pop(ctx);
                        await _toggleHyroxDay(day);
                      }
                    : null,
              ),
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
          PopupMenuButton<_WorkoutsMenuAction>(
            tooltip: 'Menu',
            onSelected: (action) async => _onMenuAction(action),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _WorkoutsMenuAction.exerciseHistory,
                child: ListTile(
                  leading: Icon(Icons.bar_chart),
                  title: Text('Exercise history'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _WorkoutsMenuAction.runList,
                child: ListTile(
                  leading: Icon(Icons.list),
                  title: Text('Runs list'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _WorkoutsMenuAction.runHeatmap,
                enabled: _runs.isNotEmpty,
                child: const ListTile(
                  leading: Icon(Icons.map_outlined),
                  title: Text('Run heatmap'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _WorkoutsMenuAction.runStats,
                child: ListTile(
                  leading: Icon(Icons.insights_outlined),
                  title: Text('Run stats'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _WorkoutsMenuAction.runSync,
                child: ListTile(
                  leading: Icon(Icons.sync),
                  title: Text('Sync runs'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _WorkoutsMenuAction.runResetAndResync,
                child: ListTile(
                  leading: Icon(Icons.delete_sweep_outlined),
                  title: Text('Reset & reimport runs'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
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
    if (_workouts!.isEmpty &&
        _hyroxDays.isEmpty &&
        _runDistanceMByDay.isEmpty) {
      return const Center(
        child: Text(
          'No training yet.\nTap a day to add Hyrox or start a workout.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(onRefresh: _load, child: _buildCalendar());
  }

  Widget _buildCalendar() {
    final byDay = _workoutsByDay();
    final today = _dayKey(DateTime.now());
    final currentWeek = _weekStart(DateTime.now());
    final firstWeek = _calendarFirstWeek ?? currentWeek;
    final totalWeeks = currentWeek.difference(firstWeek).inDays ~/ 7 + 1;

    const weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    const monthLabelWidth = 18.0;
    const monthLabelGap = 6.0;

    Color monthRangeColor(ColorScheme colors, int monthKey) {
      final palette = <Color>[
        colors.primary.withValues(alpha: 0.22),
        colors.tertiary.withValues(alpha: 0.22),
        colors.secondary.withValues(alpha: 0.22),
      ];
      return palette[monthKey % palette.length];
    }

    String monthLabel(DateTime date, {required bool includeYear}) {
      final month = monthNames[date.month - 1];
      if (!includeYear) return month;
      final year = (date.year % 100).toString().padLeft(2, '0');
      return "$month '$year";
    }

    return ListView(
      controller: _calendarScrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
      children: [
        Row(
          children: [
            const SizedBox(width: monthLabelWidth + monthLabelGap),
            Expanded(
              child: Row(
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
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, _) {
            final colors = Theme.of(context).colorScheme;

            return Column(
              children: [
                for (
                  var weekIndex = 0;
                  weekIndex < totalWeeks;
                  weekIndex++
                ) ...[
                  Builder(
                    builder: (context) {
                      final start = firstWeek.add(
                        Duration(days: weekIndex * 7),
                      );
                      final anchor = start.add(const Duration(days: 3));
                      final key = anchor.year * 12 + anchor.month;
                      final previousAnchor = weekIndex == 0
                          ? null
                          : firstWeek.add(
                              Duration(days: (weekIndex - 1) * 7 + 3),
                            );
                      final previousKey = previousAnchor == null
                          ? null
                          : previousAnchor.year * 12 + previousAnchor.month;
                      final showMonthLabel =
                          weekIndex == 0 || key != previousKey;
                      final includeYear =
                          weekIndex == 0 || previousAnchor!.year != anchor.year;
                      final rangeColor = monthRangeColor(colors, key);

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: monthLabelWidth,
                            height: _calendarCellHeight,
                            child: Container(
                              decoration: BoxDecoration(
                                color: rangeColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: showMonthLabel
                                  ? Center(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: Text(
                                          monthLabel(
                                            anchor,
                                            includeYear: includeYear,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                          const SizedBox(width: monthLabelGap),
                          Expanded(
                            child: Row(
                              children: [
                                for (var d = 0; d < 7; d++) ...[
                                  if (d > 0)
                                    const SizedBox(width: _calendarSpacing),
                                  Expanded(
                                    child: _buildDayCell(
                                      day: start.add(Duration(days: d)),
                                      byDay: byDay,
                                      today: today,
                                      hasHyrox: _hyroxDays.contains(
                                        start.add(Duration(days: d)),
                                      ),
                                      runDistanceM:
                                          _runDistanceMByDay[start.add(
                                            Duration(days: d),
                                          )] ??
                                          0,
                                      minHeight: _calendarCellHeight,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (weekIndex < totalWeeks - 1)
                    const SizedBox(height: _calendarSpacing),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildDayCell({
    required DateTime day,
    required Map<DateTime, List<WorkoutSummary>> byDay,
    required DateTime today,
    required bool hasHyrox,
    required double runDistanceM,
    required double minHeight,
  }) {
    final sessions = byDay[day] ?? [];
    final hasSession = sessions.isNotEmpty;
    final hasRun = runDistanceM > 0;
    final isToday = day == today;
    final colors = Theme.of(context).colorScheme;
    const hyroxOn = Color(0xFFF1B439);
    const workoutOn = Color(0xFFE35A5A);
    const runOn = Color(0xFF67B956);
    final hyroxFill = hasHyrox ? hyroxOn : hyroxOn.withValues(alpha: 0.2);
    final workoutFill = hasSession
        ? workoutOn
        : workoutOn.withValues(alpha: 0.2);
    final runFill = hasRun ? runOn : runOn.withValues(alpha: 0.2);
    final runKmRounded = (runDistanceM / 1000).round();
    final runLabel = hasRun ? '${runKmRounded < 1 ? 1 : runKmRounded}k' : null;

    return SizedBox(
      height: minHeight,
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openDayActions(day, sessions, hasRun),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: isToday
                  ? Border.all(color: colors.tertiary, width: 1.8)
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  const SizedBox.expand(),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ThreeBandDayPainter(
                        topColor: hyroxFill,
                        middleColor: workoutFill,
                        bottomColor: runFill,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: isToday
                            ? colors.tertiary
                            : colors.surface.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isToday ? colors.onTertiary : colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                  if (runLabel != null)
                    Positioned(
                      right: 4,
                      bottom: 3,
                      child: Text(
                        runLabel,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurface.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreeBandDayPainter extends CustomPainter {
  final Color topColor;
  final Color middleColor;
  final Color bottomColor;

  _ThreeBandDayPainter({
    required this.topColor,
    required this.middleColor,
    required this.bottomColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;

    final topLeftCut = height * 0.34;
    final topRightCut = height * 0.18;
    final middleLeftCut = height * 0.72;
    final middleRightCut = height * 0.56;

    final topPath = Path()
      ..moveTo(0, 0)
      ..lineTo(width, 0)
      ..lineTo(width, topRightCut)
      ..lineTo(0, topLeftCut)
      ..close();

    final middlePath = Path()
      ..moveTo(0, topLeftCut)
      ..lineTo(width, topRightCut)
      ..lineTo(width, middleRightCut)
      ..lineTo(0, middleLeftCut)
      ..close();

    final bottomPath = Path()
      ..moveTo(0, middleLeftCut)
      ..lineTo(width, middleRightCut)
      ..lineTo(width, height)
      ..lineTo(0, height)
      ..close();

    canvas.drawPath(topPath, Paint()..color = topColor);
    canvas.drawPath(middlePath, Paint()..color = middleColor);
    canvas.drawPath(bottomPath, Paint()..color = bottomColor);
  }

  @override
  bool shouldRepaint(covariant _ThreeBandDayPainter oldDelegate) {
    return topColor != oldDelegate.topColor ||
        middleColor != oldDelegate.middleColor ||
        bottomColor != oldDelegate.bottomColor;
  }
}
