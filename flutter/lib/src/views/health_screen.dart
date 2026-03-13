import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  List<DailyHealth>? _days;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final days = await api.listDailyHealth();
      if (mounted) setState(() { _days = days; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: _error != null
            ? Center(child: Text(_error!))
            : _days == null
                ? const Center(child: CircularProgressIndicator())
                : _days!.isEmpty
                    ? const Center(child: Text('No health data yet.\nSync a Gadgetbridge export to populate.', textAlign: TextAlign.center))
                    : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final days = _days!;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: Text('${days.length} days of health data'),
          floating: true,
        ),
        SliverToBoxAdapter(child: _buildHrChart(days)),
        SliverToBoxAdapter(child: _buildHrvChart(days)),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _buildDayTile(days[days.length - 1 - i]),
            childCount: days.length,
          ),
        ),
      ],
    );
  }

  Widget _buildHrChart(List<DailyHealth> days) {
    final hrDays = days.asMap().entries.where((e) => e.value.avgHr != null).toList();
    if (hrDays.isEmpty) return const SizedBox.shrink();

    final avgSpots = hrDays.map((e) => FlSpot(e.key.toDouble(), e.value.avgHr!.toDouble())).toList();
    final minSpots = hrDays.map((e) => FlSpot(e.key.toDouble(), (e.value.minHr ?? e.value.avgHr!).toDouble())).toList();
    final maxSpots = hrDays.map((e) => FlSpot(e.key.toDouble(), (e.value.maxHr ?? e.value.avgHr!).toDouble())).toList();

    final allHr = hrDays.expand((e) => [e.value.minHr ?? e.value.avgHr!, e.value.maxHr ?? e.value.avgHr!]).map((v) => v.toDouble());
    final minY = (allHr.reduce((a, b) => a < b ? a : b) - 5).clamp(0, 300).toDouble();
    final maxY = allHr.reduce((a, b) => a > b ? a : b) + 5;

    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Heart Rate (bpm)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: LineChart(
              LineChartData(
                minY: minY,
                maxY: maxY,
                gridData: FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32)),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  // shaded min-max band
                  LineChartBarData(
                    spots: maxSpots,
                    isCurved: true,
                    color: scheme.primary.withValues(alpha: 0.15),
                    belowBarData: BarAreaData(
                      show: true,
                      color: scheme.primary.withValues(alpha: 0.10),
                      cutOffY: minY,
                      applyCutOffY: true,
                    ),
                    dotData: FlDotData(show: false),
                    barWidth: 0,
                  ),
                  LineChartBarData(
                    spots: minSpots,
                    isCurved: true,
                    color: scheme.primary.withValues(alpha: 0.15),
                    dotData: FlDotData(show: false),
                    barWidth: 0,
                  ),
                  // avg line
                  LineChartBarData(
                    spots: avgSpots,
                    isCurved: true,
                    color: scheme.primary,
                    dotData: FlDotData(show: false),
                    barWidth: 2,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHrvChart(List<DailyHealth> days) {
    final hrvDays = days.asMap().entries.where((e) => e.value.hrvRmssd != null).toList();
    if (hrvDays.isEmpty) return const SizedBox.shrink();

    final spots = hrvDays.map((e) => FlSpot(e.key.toDouble(), e.value.hrvRmssd!)).toList();
    final values = hrvDays.map((e) => e.value.hrvRmssd!);
    final minY = values.reduce((a, b) => a < b ? a : b) - 2;
    final maxY = values.reduce((a, b) => a > b ? a : b) + 2;

    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HRV (ms)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: LineChart(
              LineChartData(
                minY: minY,
                maxY: maxY,
                gridData: FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36)),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: scheme.tertiary,
                    dotData: FlDotData(show: false),
                    barWidth: 2,
                    belowBarData: BarAreaData(
                      show: true,
                      color: scheme.tertiary.withValues(alpha: 0.10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDayTile(DailyHealth d) {
    return ListTile(
      dense: true,
      title: Text(d.date),
      subtitle: Row(
        children: [
          if (d.avgHr != null)
            Text('HR ${d.avgHr} bpm (${d.minHr}–${d.maxHr})  ', style: const TextStyle(fontSize: 12)),
          if (d.hrvRmssd != null)
            Text('HRV ${d.hrvRmssd!.toStringAsFixed(1)} ms', style: const TextStyle(fontSize: 12)),
        ],
      ),
      trailing: d.steps != null
          ? Text('${d.steps} steps', style: const TextStyle(fontSize: 12))
          : null,
    );
  }
}
