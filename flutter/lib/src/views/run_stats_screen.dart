import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'run_detail_screen.dart';

class RunStatsScreen extends StatefulWidget {
  const RunStatsScreen({super.key});

  @override
  State<RunStatsScreen> createState() => _RunStatsScreenState();
}

class _RunStatsScreenState extends State<RunStatsScreen> {
  List<RunSummary> _runs = [];
  List<PersonalRecord> _prs = [];
  bool _loading = true;

  // Only include valid runs in stats computations
  List<RunSummary> get _validRuns =>
      _runs.where((r) => !r.isInvalid).toList();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        api.listRuns(),
        api.getPersonalRecords(),
      ]);
      if (!mounted) return;
      final runs = results[0] as List<RunSummary>;
      final withCad = runs.where((r) => r.avgCadence != null).length;
      debugPrint('[RunStats] loaded ${runs.length} runs, $withCad with cadence');
      setState(() {
        _runs = runs;
        _prs = results[1] as List<PersonalRecord>;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('[RunStats] load error: $e\n$st');
      if (mounted) setState(() => _loading = false);
    }
  }

  // seconds/km → "M:SS /km"
  static String _fmtPace(double secPerKm) {
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  // Monday-anchored ISO week key "YYYY-Www"
  static String _weekKey(DateTime d) {
    final monday = d.subtract(Duration(days: d.weekday - 1));
    final y = monday.year;
    final jan4 = DateTime(y, 1, 4);
    final week = ((monday.difference(jan4).inDays + jan4.weekday) / 7).ceil();
    return '$y-W${week.toString().padLeft(2, '0')}';
  }

  // ── km/week bar chart ────────────────────────────────────────────────────────
  Widget _kmPerWeek(BuildContext context) {
    // Collect last 12 weeks in order
    final now = DateTime.now();
    final weeks = <String>[];
    for (int i = 11; i >= 0; i--) {
      weeks.add(_weekKey(now.subtract(Duration(days: i * 7))));
    }
    final kmMap = <String, double>{for (final w in weeks) w: 0};
    for (final run in _validRuns) {
      final k = _weekKey(run.startedAt.toLocal());
      if (kmMap.containsKey(k)) kmMap[k] = kmMap[k]! + run.distanceM / 1000;
    }
    final values = weeks.map((w) => kmMap[w]!).toList();
    final maxKm = values.fold(0.0, math.max);

    return _Card(
      title: 'km / week (last 12 weeks)',
      child: BarChart(
        BarChartData(
          maxY: (maxKm * 1.2).clamp(5, double.infinity),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                  BarTooltipItem('${rod.toY.toStringAsFixed(1)} km',
                      const TextStyle(fontSize: 11)),
            ),
          ),
          barGroups: List.generate(
            weeks.length,
            (i) => BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  color: Theme.of(context).colorScheme.primary,
                  width: 14,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, _) =>
                    Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: 1,
                getTitlesWidget: (v, _) {
                  final idx = v.toInt();
                  if (idx % 3 != 0) return const SizedBox.shrink();
                  final label = weeks[idx].substring(6); // "Www"
                  return Text(label, style: const TextStyle(fontSize: 9));
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  // ── Pace trend line ──────────────────────────────────────────────────────────
  Widget _paceTrend(BuildContext context) {
    final sorted = _validRuns
        .where((r) => r.distanceM > 100)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (sorted.length < 2) return const SizedBox.shrink();

    final spots = sorted.asMap().entries.map((e) {
      final pace = e.value.durationS / (e.value.distanceM / 1000);
      return FlSpot(e.key.toDouble(), pace);
    }).toList();

    final minY = spots.map((s) => s.y).fold(double.infinity, math.min);
    final maxY = spots.map((s) => s.y).fold(0.0, math.max);
    final pad = (maxY - minY) * 0.15;

    return _Card(
      title: 'Pace trend (min/km)',
      child: LineChart(
        LineChartData(
          minY: minY - pad,
          maxY: maxY + pad,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots
                  .map((s) => LineTooltipItem(
                        '${_fmtPace(s.y)}/km',
                        const TextStyle(fontSize: 11),
                      ))
                  .toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Theme.of(context).colorScheme.primary,
              dotData: FlDotData(show: spots.length <= 30),
              barWidth: 2,
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
              ),
            ),
          ],
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 52,
                getTitlesWidget: (v, _) =>
                    Text(_fmtPace(v), style: const TextStyle(fontSize: 9)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: math.max(1, (sorted.length / 5).ceilToDouble()),
                getTitlesWidget: (v, _) {
                  final idx = v.toInt();
                  if (idx >= sorted.length) return const SizedBox.shrink();
                  return Text(
                    sorted[idx].startedAt.toLocal().toString().substring(5, 10),
                    style: const TextStyle(fontSize: 8),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  // ── Cadence trend ────────────────────────────────────────────────────────────
  Widget _cadenceTrend(BuildContext context) {
    final sorted = _validRuns
        .where((r) => r.avgCadence != null)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (sorted.length < 2) return const SizedBox.shrink();

    final spots = sorted.asMap().entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.avgCadence!.toDouble()))
        .toList();
    final minY = spots.map((s) => s.y).fold(double.infinity, math.min);
    final maxY = spots.map((s) => s.y).fold(0.0, math.max);
    final pad = (maxY - minY) * 0.15;

    return _Card(
      title: 'Cadence trend (spm)',
      child: LineChart(LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
              '${s.y.round()} spm',
              const TextStyle(fontSize: 11),
            )).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Theme.of(context).colorScheme.tertiary,
            dotData: FlDotData(show: spots.length <= 30),
            barWidth: 2,
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.1),
            ),
          ),
        ],
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, meta) {
                if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                return Text(v.round().toString(), style: const TextStyle(fontSize: 9));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              interval: math.max(1, (sorted.length / 5).ceilToDouble()),
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx >= sorted.length) return const SizedBox.shrink();
                return Text(
                  sorted[idx].startedAt.toLocal().toString().substring(5, 10),
                  style: const TextStyle(fontSize: 8),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
      )),
    );
  }

  // ── Stride length trend ───────────────────────────────────────────────────────
  Widget _strideTrend(BuildContext context) {
    final sorted = _validRuns
        .where((r) => r.avgStrideM != null)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (sorted.length < 2) return const SizedBox.shrink();

    final spots = sorted.asMap().entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.avgStrideM!))
        .toList();
    final minY = spots.map((s) => s.y).fold(double.infinity, math.min);
    final maxY = spots.map((s) => s.y).fold(0.0, math.max);
    final pad = (maxY - minY) * 0.15;

    return _Card(
      title: 'Step length trend (m)',
      child: LineChart(LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
              '${s.y.toStringAsFixed(2)} m',
              const TextStyle(fontSize: 11),
            )).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Theme.of(context).colorScheme.secondary,
            dotData: FlDotData(show: spots.length <= 30),
            barWidth: 2,
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
            ),
          ),
        ],
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, meta) {
                if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                return Text(v.toStringAsFixed(2), style: const TextStyle(fontSize: 9));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              interval: math.max(1, (sorted.length / 5).ceilToDouble()),
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx >= sorted.length) return const SizedBox.shrink();
                return Text(
                  sorted[idx].startedAt.toLocal().toString().substring(5, 10),
                  style: const TextStyle(fontSize: 8),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
      )),
    );
  }

  // ── VO₂max helpers ──────────────────────────────────────────────────────────
  // ACSM running equation: VO₂ (ml/kg/min) = 0.2 × speed_m_per_min + 3.5 (flat)
  // Scale to max: VO₂max ≈ VO₂_at_pace / (avg_hr / hr_max)
  // Only valid for steady aerobic runs ≥ 15 min, ≥ 2 km, avg HR ≥ 100 bpm.
  static double? _vo2maxForRun(RunSummary run, int hrMax) {
    if (run.avgHr == null) return null;
    if (run.durationS < 900 || run.distanceM < 2000) return null;
    if (run.avgHr! < 100 || run.avgHr! >= hrMax) return null;
    final speedMperMin = (run.distanceM / run.durationS) * 60.0;
    final vo2AtPace = 0.2 * speedMperMin + 3.5;
    return vo2AtPace / (run.avgHr! / hrMax);
  }

  int get _hrMax {
    final vals = _validRuns.map((r) => r.maxHr ?? 0);
    return vals.isEmpty ? 0 : vals.reduce(math.max);
  }

  List<(RunSummary, double)> get _vo2maxPoints {
    final hrMax = _hrMax;
    if (hrMax == 0) return [];
    final sorted = _validRuns.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return sorted
        .map((r) => (r, _vo2maxForRun(r, hrMax)))
        .where((p) => p.$2 != null)
        .map((p) => (p.$1, p.$2!))
        .toList();
  }

  // ── VO₂max trend ────────────────────────────────────────────────────────────
  Widget _vo2maxTrend(BuildContext context) {
    final pts = _vo2maxPoints;
    if (pts.length < 2) return const SizedBox.shrink();

    final spots = pts.asMap().entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.$2))
        .toList();
    final minY = spots.map((s) => s.y).fold(double.infinity, math.min);
    final maxY = spots.map((s) => s.y).fold(0.0, math.max);
    final pad = (maxY - minY) * 0.15;

    return _Card(
      title: 'VO₂max estimate trend (ml/kg/min)',
      child: LineChart(LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
              '${s.y.toStringAsFixed(1)} ml/kg/min',
              const TextStyle(fontSize: 11),
            )).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Colors.teal,
            dotData: FlDotData(show: spots.length <= 30),
            barWidth: 2,
            belowBarData: BarAreaData(
              show: true,
              color: Colors.teal.withValues(alpha: 0.1),
            ),
          ),
        ],
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, meta) {
                if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                return Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 9));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              interval: math.max(1, (pts.length / 5).ceilToDouble()),
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx >= pts.length) return const SizedBox.shrink();
                return Text(
                  pts[idx].$1.startedAt.toLocal().toString().substring(5, 10),
                  style: const TextStyle(fontSize: 8),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
      )),
    );
  }


  Widget _hrVsPace(BuildContext context) {
    final valid = _validRuns
        .where((r) => r.avgHr != null && r.distanceM > 100)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (valid.length < 3) return const SizedBox.shrink();

    // Colour dots from old (faded) to new (vivid) to show fitness trend
    final spots = valid.asMap().entries.map((e) {
      final pace = e.value.durationS / (e.value.distanceM / 1000) / 60; // min/km
      final hr = e.value.avgHr!.toDouble();
      final frac = valid.length == 1 ? 1.0 : e.key / (valid.length - 1);
      final dotColor = Color.lerp(Colors.blue.withAlpha(80), Colors.red, frac)!;
      return ScatterSpot(
        pace, hr,
        dotPainter: FlDotCirclePainter(radius: 5, color: dotColor, strokeWidth: 0),
      );
    }).toList();

    final paces = spots.map((s) => s.x).toList();
    final hrs = spots.map((s) => s.y).toList();
    final minX = paces.fold(double.infinity, math.min);
    final maxX = paces.fold(0.0, math.max);
    final minY = hrs.fold(double.infinity, math.min);
    final maxY = hrs.fold(0.0, math.max);
    final px = (maxX - minX) * 0.1;
    final py = (maxY - minY) * 0.1;

    return _Card(
      title: 'HR vs Pace  (blue=older → red=recent)',
      child: ScatterChart(
        ScatterChartData(
          minX: minX - px,
          maxX: maxX + px,
          minY: minY - py,
          maxY: maxY + py,
          scatterSpots: spots,
          scatterTouchData: ScatterTouchData(
            touchTooltipData: ScatterTouchTooltipData(
              getTooltipItems: (spot) => ScatterTooltipItem(
                '${_fmtPace(spot.x * 60)}/km\n${spot.y.round()} bpm',
                textStyle: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              axisNameWidget: const Text('Pace (min/km)', style: TextStyle(fontSize: 10)),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, _) =>
                    Text(_fmtPace(v * 60), style: const TextStyle(fontSize: 9)),
              ),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: const Text('Avg HR', style: TextStyle(fontSize: 10)),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, _) =>
                    Text(v.round().toString(), style: const TextStyle(fontSize: 9)),
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  // ── Personal records ─────────────────────────────────────────────────────────
  Widget _personalRecords(BuildContext context) {
    if (_validRuns.isEmpty) return const SizedBox.shrink();

    final longest = _validRuns.reduce((a, b) => a.distanceM > b.distanceM ? a : b);

    final fastRuns = _validRuns.where((r) => r.distanceM > 3000).toList();
    final bestPaceRun = fastRuns.isEmpty
        ? null
        : fastRuns.reduce((a, b) =>
            (a.durationS / a.distanceM) < (b.durationS / b.distanceM) ? a : b);

    final eleRuns = _validRuns.where((r) => r.elevationGainM != null).toList();
    final mostEle = eleRuns.isEmpty
        ? null
        : eleRuns.reduce(
            (a, b) => a.elevationGainM! > b.elevationGainM! ? a : b);

    // Best week km
    final kmMap = <String, double>{};
    for (final r in _validRuns) {
      final k = _weekKey(r.startedAt.toLocal());
      kmMap[k] = (kmMap[k] ?? 0) + r.distanceM / 1000;
    }
    final bestWeekKm =
        kmMap.isEmpty ? 0.0 : kmMap.values.fold(0.0, math.max);

    String fmtDist(double m) => '${(m / 1000).toStringAsFixed(2)} km';
    String fmtDate(DateTime d) => d.toLocal().toString().substring(0, 10);

    // (icon, label, value, dateStr or null, runId or null)
    final records = <(String, String, String, String?, int?)>[
      // Distance PRs from API
      ..._prs.map((pr) => ('🏆', pr.distanceLabel, pr.formattedTime, fmtDate(pr.runDate), pr.runId)),
      // Local record stats
      ('🏅', 'Longest run', fmtDist(longest.distanceM), fmtDate(longest.startedAt), longest.id),
      if (bestPaceRun != null)
        (
          '⚡',
          'Best avg pace',
          '${_fmtPace(bestPaceRun.durationS / (bestPaceRun.distanceM / 1000))}/km',
          fmtDate(bestPaceRun.startedAt),
          bestPaceRun.id,
        ),
      if (mostEle != null)
        (
          '⛰️',
          'Most elevation',
          '+${mostEle.elevationGainM!.round()} m',
          fmtDate(mostEle.startedAt),
          mostEle.id,
        ),
      ('📅', 'Best week', '${bestWeekKm.toStringAsFixed(1)} km', null, null),
    ];

    // Best VO₂max estimate
    final vo2pts = _vo2maxPoints;
    if (vo2pts.isNotEmpty) {
      final best = vo2pts.reduce((a, b) => a.$2 > b.$2 ? a : b);
      records.add((
        '🫁',
        'Best VO₂max est.',
        '${best.$2.toStringAsFixed(1)} ml/kg/min',
        fmtDate(best.$1.startedAt),
        best.$1.id,
      ));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Personal records',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...records.map((r) => InkWell(
                    onTap: r.$5 != null
                        ? () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    RunDetailScreen(runId: r.$5!),
                              ),
                            )
                        : null,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Text(r.$1, style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(r.$2,
                                style: const TextStyle(color: Colors.grey)),
                          ),
                          Text(r.$3,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          if (r.$4 != null) ...[
                            const SizedBox(width: 8),
                            Text(r.$4!,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                          ],
                          if (r.$5 != null) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right,
                                size: 16, color: Colors.grey),
                          ],
                        ],
                      ),
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ── Summary stats row ────────────────────────────────────────────────────────
  Widget _summaryRow() {
    final totalKm = _validRuns.fold(0.0, (s, r) => s + r.distanceM) / 1000;
    final totalH = _validRuns.fold(0, (s, r) => s + r.durationS) / 3600;
    final hrsWithHr = _validRuns.where((r) => r.avgHr != null).toList();
    final avgHr = hrsWithHr.isEmpty
        ? null
        : hrsWithHr.fold(0, (s, r) => s + r.avgHr!) ~/ hrsWithHr.length;

    final vo2pts = _vo2maxPoints;
    final bestVo2 = vo2pts.isEmpty
        ? null
        : vo2pts.map((p) => p.$2).fold(0.0, math.max);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatChip(label: 'Total runs', value: '${_validRuns.length}'),
          _StatChip(label: 'Total km', value: totalKm.toStringAsFixed(1)),
          _StatChip(label: 'Total hours', value: totalH.toStringAsFixed(1)),
          if (avgHr != null) _StatChip(label: 'Avg HR', value: '$avgHr bpm'),
          if (bestVo2 != null)
            _StatChip(label: 'Best VO₂max', value: '${bestVo2.toStringAsFixed(1)} ml/kg/min'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_validRuns.isEmpty) {
      return const Scaffold(body: Center(child: Text('No run data yet')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Run stats')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _summaryRow(),
          _personalRecords(context),
          const Divider(),
          _kmPerWeek(context),
          _paceTrend(context),
          _cadenceTrend(context),
          _strideTrend(context),
          _vo2maxTrend(context),
          _hrVsPace(context),
        ],
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              SizedBox(height: 200, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
