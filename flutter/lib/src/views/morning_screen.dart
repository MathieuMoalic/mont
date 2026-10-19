import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../api.dart' as api;
import '../platform/ble_relay.dart' as ble;

/// Morning glance: last night's sleep, HRV, the day's heart rate and steps —
/// the stats previously checked in Gadgetbridge every morning.
class MorningScreen extends StatefulWidget {
  const MorningScreen({super.key});

  @override
  State<MorningScreen> createState() => _MorningScreenState();
}

class _MorningScreenState extends State<MorningScreen> {
  DateTime _date = DateTime.now().subtract(const Duration(hours: 12));
  Map<String, dynamic>? _data;
  bool _syncing = false;
  String? _error;

  /// Auto step-backs while hunting for the most recent night with a sleep
  /// session (the watch finalizes the current night's session later in the
  /// day); stops as soon as the user navigates manually.
  int _autoSteps = 0;
  bool _navigated = false;

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  String get _dateStr {
    final d = _date;
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  bool get _isToday => _dateStr == _fmtDate(DateTime.now());

  /// "Today", "Yesterday", or the weekday name for older days.
  String get _dayTitle {
    if (_isToday) return 'Today';
    final now = DateTime.now();
    if (_dateStr == _fmtDate(now.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    }
    return _weekdays[_date.weekday - 1];
  }

  /// "Monday 19.10.2026"
  String get _fullDate =>
      '${_weekdays[_date.weekday - 1]} '
      '${_date.day.toString().padLeft(2, '0')}.'
      '${_date.month.toString().padLeft(2, '0')}.${_date.year}';

  static String _fmtDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await api.getMorning(_dateStr);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
      final sleep = data['sleep'] as Map<String, dynamic>?;
      final hasSleep = (sleep?['total_min'] as num? ?? 0) > 0;
      if (!hasSleep && !_navigated && _autoSteps < 3) {
        _autoSteps += 1;
        _shiftDay(-1, manual: false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _shiftDay(int days, {bool manual = true}) {
    if (manual) _navigated = true;
    if (manual && days > 0 && _isToday) return; // never into the future
    setState(() {
      _date = _date.add(Duration(days: days));
      _data = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(_dayTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftDay(-1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _isToday ? null : () => _shiftDay(1),
          ),
          // Same as the old "Sync now": runs a watch sync, then reloads.
          IconButton(icon: const Icon(Icons.refresh), onPressed: _syncNow),
        ],
      ),
      body: _syncing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Syncing watch…'),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _syncNow,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Center(
                    child: Text(
                      _fullDate,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Error: $_error',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  if (data == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _section('Sleep'),
                    _sleepCard(data['sleep'] as Map<String, dynamic>?),
                    _section('Steps'),
                    _stepsCard(data),
                    _section('HRV'),
                    _hrvCard(data),
                    _section('Heart rate'),
                    _hrCard(data['hr'] as Map<String, dynamic>?),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await ble.startManualSync();
    } catch (_) {}
    await _load();
    if (mounted) setState(() => _syncing = false);
  }

  String _hm(int? ts) {
    if (ts == null) return '--:--';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _dur(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}min' : '${m}min';
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _card({required Widget child}) => Card(
    child: Padding(padding: const EdgeInsets.all(12), child: child),
  );

  Widget _stat(String value, String label, {Color? color}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color),
      ),
      const SizedBox(height: 2),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  // ── sleep ─────────────────────────────────────────────────────────────────

  Widget _sleepCard(Map<String, dynamic>? sleep) {
    if (sleep == null || sleep['total_min'] == null) {
      return const Card(child: ListTile(title: Text('No sleep data')));
    }
    final total = (sleep['total_min'] as num).toInt();
    final deep = (sleep['deep_min'] as num? ?? 0).toInt();
    final rem = (sleep['rem_min'] as num? ?? 0).toInt();
    final light = (sleep['light_min'] as num? ?? 0).toInt();
    final awake = (sleep['awake_min'] as num? ?? 0).toInt();
    final timeline = (sleep['timeline'] as List? ?? [])
        .map((e) => List.from(e as List))
        .toList();

    return _card(
      child: Column(
        children: [
          Text(_dur(total), style: Theme.of(context).textTheme.headlineMedium),
          Text(
            '${_hm(sleep['window_start'] as int?)} – ${_hm(sleep['window_end'] as int?)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 10,
            child: timeline.isEmpty
                ? null
                : Row(
                    children: timeline
                        .map(
                          (m) => Expanded(
                            child: Container(
                              color: _stageColor((m[1] as num).toInt()),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stageCol(Colors.indigo.shade700, _dur(deep), 'Deep'),
              _stageCol(Colors.lightBlue, _dur(light), 'Light'),
              _stageCol(Colors.purple, _dur(rem), 'REM'),
              _stageCol(Colors.orange.shade300, _dur(awake), 'Awake'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageCol(Color color, String value, String label) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(height: 4, width: 60, color: color),
      const SizedBox(height: 8),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Color _stageColor(int code) => switch (code) {
    3 => Colors.indigo.shade700, // deep
    2 => Colors.purple, // REM
    1 => Colors.lightBlue, // light
    _ => Colors.orange.shade300, // awake
  };

  // ── shared chart helpers ──────────────────────────────────────────────────

  /// Clock label ("23:00") for an x value in hours relative to the day's
  /// midnight (values may be negative for the previous evening).
  String _clockLabel(double hours) {
    final h = (((hours.round() % 24) + 24) % 24);
    return '${h.toString().padLeft(2, '0')}:00';
  }

  /// Largest round step that still gives ~4 grid lines for `span`.
  double _niceInterval(double span) {
    for (final step in [
      5.0,
      10.0,
      15.0,
      20.0,
      25.0,
      30.0,
      40.0,
      50.0,
      60.0,
      80.0,
      100.0,
    ]) {
      if (step >= span / 4) return step;
    }
    return 100.0;
  }

  Widget _leftLabel(double v, String unit) => Text(
    unit.isEmpty ? v.round().toString() : '${v.round()} $unit',
    style: Theme.of(context).textTheme.bodySmall,
  );

  FlTitlesData _titles({
    required double xInterval,
    required double yInterval,
    required String unit,
    double? hideLabelAtX,
  }) => FlTitlesData(
    show: true,
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        interval: xInterval,
        getTitlesWidget: (v, _) {
          // fl_chart adds off-grid min/max edge ticks whose labels collide
          // with the interval ticks or clip at the plot border
          if (!_onGrid(v, xInterval) ||
              (hideLabelAtX != null && v >= hideLabelAtX - xInterval * 0.4)) {
            return const SizedBox.shrink();
          }
          return Text(
            _clockLabel(v),
            style: Theme.of(context).textTheme.bodySmall,
          );
        },
      ),
    ),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 52,
        interval: yInterval,
        getTitlesWidget: (v, _) => _onGrid(v, yInterval)
            ? _leftLabel(v, unit)
            : const SizedBox.shrink(),
      ),
    ),
  );

  /// Whether a tick value sits on the interval grid (edge ticks don't).
  bool _onGrid(double v, double interval) =>
      ((v / interval).roundToDouble() * interval - v).abs() < 0.01;

  /// Touch feedback for the charts: a tooltip with the clock time and value.
  LineTouchData _touch() => LineTouchData(
    enabled: true,
    touchTooltipData: LineTouchTooltipData(
      getTooltipItems: (spots) => spots
          .map(
            (s) => LineTooltipItem(
              '${_clockLabel(s.x)} · ${s.y.round()}',
              Theme.of(context).textTheme.bodySmall ?? const TextStyle(),
            ),
          )
          .toList(),
    ),
  );

  // ── HRV ───────────────────────────────────────────────────────────────────

  Widget _hrvCard(Map<String, dynamic> data) {
    final hrv = data['hrv'] as Map<String, dynamic>?;
    if (hrv == null) return const SizedBox.shrink();
    final points = (hrv['points'] as List? ?? [])
        .map((e) => List.from(e as List))
        .toList();
    final nightAvg = hrv['night_avg'] as num?;
    final spots = points
        .map(
          (p) => FlSpot(
            (p[0] as num).toDouble() / 3600.0, // hours since midnight
            (p[1] as num).toDouble(),
          ),
        )
        .toList();

    // The HRV night starts in the evening; show it against the sleep window
    // when the date has one, else against a default 00:00–08:15 night window
    // (e.g. today, whose session the watch finalizes later). Spots outside
    // the window are dropped — fl_chart won't draw a line whose first point
    // is out of bounds.
    double sleepStartHours = 0;
    double sleepEndHours = 0;
    final sleep = data['sleep'] as Map<String, dynamic>?;
    final dayStart =
        DateTime(_date.year, _date.month, _date.day).millisecondsSinceEpoch ~/
        1000;
    final ws = sleep?['window_start'] as int?;
    final we = sleep?['window_end'] as int?;
    var useSleepWindow = false;
    if (ws != null && we != null) {
      sleepStartHours = (ws - dayStart) / 3600.0;
      sleepEndHours = (we - dayStart) / 3600.0;
      useSleepWindow = sleepEndHours > sleepStartHours;
    }
    var plotted = spots.where((s) => s.x >= 0 && s.x <= 8.25).toList();
    var xMin = 0.0;
    var xMax = 8.25;
    var xInterval = 2.0;
    if (useSleepWindow) {
      final inWindow = spots
          .where((s) => s.x >= sleepStartHours && s.x <= sleepEndHours)
          .toList();
      if (inWindow.isNotEmpty) {
        plotted = inWindow;
        xMin = sleepStartHours;
        xMax = sleepEndHours;
      }
    }
    final visibleValues = plotted.map((s) => s.y).toList();
    final yMin = visibleValues.isEmpty
        ? 0.0
        : (((visibleValues.reduce((a, b) => a < b ? a : b) - 10) / 20).floor() *
                  20)
              .clamp(0.0, 200.0)
              .toDouble();
    final yMax = visibleValues.isEmpty
        ? 0.0
        : (((visibleValues.reduce((a, b) => a > b ? a : b) + 10) / 20).ceil() *
                  20)
              .toDouble();
    final yInterval = _niceInterval(yMax - yMin);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plotted.isNotEmpty)
            SizedBox(
              height: 150,
              child: LineChart(
                LineChartData(
                  minX: xMin,
                  maxX: xMax,
                  minY: yMin,
                  maxY: yMax,
                  titlesData: _titles(
                    xInterval: xInterval,
                    yInterval: yInterval,
                    unit: '',
                    hideLabelAtX: xMax,
                  ),
                  gridData: FlGridData(
                    show: true,
                    verticalInterval: xInterval,
                    horizontalInterval: yInterval,
                    getDrawingHorizontalLine: (v) =>
                        const FlLine(color: Colors.white12, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: const Border(
                      bottom: BorderSide(color: Colors.white24),
                      left: BorderSide(color: Colors.white24),
                    ),
                  ),
                  clipData: const FlClipData.all(),
                  lineTouchData: _touch(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: plotted,
                      color: Colors.redAccent,
                      dotData: const FlDotData(show: false),
                      barWidth: 2,
                    ),
                  ],
                ),
              ),
            ),
          if (plotted.isEmpty) const Text('No HRV data'),
          const SizedBox(height: 12),
          Center(
            child: _stat(
              nightAvg == null ? '--' : '${nightAvg.round()} ms',
              'Last night',
            ),
          ),
        ],
      ),
    );
  }

  // ── HR ────────────────────────────────────────────────────────────────────

  Widget _hrCard(Map<String, dynamic>? hr) {
    if (hr == null) return const SizedBox.shrink();
    final points = (hr['points'] as List? ?? [])
        .map((e) => List.from(e as List))
        .toList();
    final avg = hr['avg'] as num?;
    final spots = points
        .map(
          (p) => FlSpot(
            (p[0] as num).toDouble() / 3600.0, // hours since midnight
            (p[1] as num).toDouble(),
          ),
        )
        .toList();

    final values = spots.map((s) => s.y).toList();
    final dataMax = values.isEmpty
        ? 100.0
        : values.reduce((a, b) => a > b ? a : b);
    final dataMin = values.isEmpty
        ? 40.0
        : values.reduce((a, b) => a < b ? a : b);
    final yMin = (((dataMin - 10) / 10).floor() * 10)
        .clamp(30.0, 60.0)
        .toDouble();
    final yMax = (((dataMax + 15) / 10).ceil() * 10)
        .clamp(100.0, 220.0)
        .toDouble();
    final yInterval = _niceInterval(yMax - yMin);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spots.isNotEmpty)
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: 24,
                  minY: yMin,
                  maxY: yMax,
                  titlesData: _titles(
                    xInterval: 6,
                    yInterval: yInterval,
                    unit: '',
                    hideLabelAtX: 24,
                  ),
                  gridData: FlGridData(
                    show: true,
                    verticalInterval: 6,
                    horizontalInterval: yInterval,
                    getDrawingHorizontalLine: (v) =>
                        const FlLine(color: Colors.white12, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: const Border(
                      bottom: BorderSide(color: Colors.white24),
                      left: BorderSide(color: Colors.white24),
                    ),
                  ),
                  clipData: const FlClipData.all(),
                  lineTouchData: _touch(),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      if (avg != null)
                        HorizontalLine(
                          y: avg.toDouble(),
                          color: Colors.redAccent,
                          dashArray: [6, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            labelResolver: (_) => 'avg ${avg.round()}',
                          ),
                        ),
                    ],
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      color: Colors.red,
                      dotData: const FlDotData(show: false),
                      barWidth: 1.5,
                    ),
                  ],
                ),
              ),
            ),
          if (spots.isEmpty) const Text('No HR data'),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('${hr['min'] ?? '--'} bpm', 'Minimum'),
              _stat(avg == null ? '--' : '${avg.round()} bpm', 'Average'),
              _stat('${hr['max'] ?? '--'} bpm', 'Maximum'),
            ],
          ),
        ],
      ),
    );
  }

  // ── day ───────────────────────────────────────────────────────────────────

  Widget _stepsCard(Map<String, dynamic> data) {
    final steps = data['steps'] as num?;
    return _card(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat(steps == null ? '--' : steps.round().toString(), 'Steps'),
        ],
      ),
    );
  }
}
