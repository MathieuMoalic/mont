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
        const SliverAppBar(
          title: Text('Health data'),
          floating: true,
        ),
        SliverToBoxAdapter(child: _buildHrChart(days)),
        SliverToBoxAdapter(child: _buildHrvChart(days)),
        SliverToBoxAdapter(child: _buildStepsChart(days)),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _buildDayTile(days[days.length - 1 - i]),
            childCount: days.length,
          ),
        ),
      ],
    );
  }

  static FlTitlesData _axisTitles({required double yReserved}) => FlTitlesData(
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: yReserved,
        getTitlesWidget: (v, meta) => Text(
          meta.formattedValue,
          style: const TextStyle(fontSize: 10),
        ),
      ),
    ),
    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
  );

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

    return _chartSection(
      label: 'Heart Rate (bpm)',
      height: 160,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(yReserved: 44),
          lineBarsData: [
            LineChartBarData(
              spots: minSpots,
              isCurved: true,
              color: scheme.primary.withValues(alpha: 0.45),
              dotData: FlDotData(show: false),
              barWidth: 1.5,
              dashArray: [4, 4],
            ),
            LineChartBarData(
              spots: avgSpots,
              isCurved: true,
              color: scheme.primary,
              dotData: FlDotData(show: false),
              barWidth: 2,
            ),
            LineChartBarData(
              spots: maxSpots,
              isCurved: true,
              color: scheme.primary.withValues(alpha: 0.45),
              dotData: FlDotData(show: false),
              barWidth: 1.5,
              dashArray: [4, 4],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHrvChart(List<DailyHealth> days) {
    final hrvDays = days.asMap().entries.where((e) => e.value.hrvRmssd != null).toList();
    if (hrvDays.isEmpty) return const SizedBox.shrink();

    final spots = hrvDays.map((e) => FlSpot(e.key.toDouble(), e.value.hrvRmssd!)).toList();
    final values = hrvDays.map((e) => e.value.hrvRmssd!);
    final minY = (values.reduce((a, b) => a < b ? a : b) - 2).clamp(0, 9999).toDouble();
    final maxY = values.reduce((a, b) => a > b ? a : b) + 2;

    final scheme = Theme.of(context).colorScheme;

    return _chartSection(
      label: 'HRV — nightly RMSSD (ms)',
      height: 120,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(yReserved: 44),
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
    );
  }

  Widget _buildStepsChart(List<DailyHealth> days) {
    final stepDays = days.asMap().entries.where((e) => e.value.steps != null && e.value.steps! > 0).toList();
    if (stepDays.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final bars = stepDays.map((e) => BarChartGroupData(
      x: e.key,
      barRods: [
        BarChartRodData(
          toY: e.value.steps!.toDouble(),
          color: scheme.secondary,
          width: stepDays.length > 60 ? 2 : 5,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
        ),
      ],
    )).toList();

    final maxY = stepDays.map((e) => e.value.steps!.toDouble()).reduce((a, b) => a > b ? a : b) * 1.1;

    return _chartSection(
      label: 'Steps per day',
      height: 120,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          gridData: FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(yReserved: 52),
          barGroups: bars,
          barTouchData: BarTouchData(enabled: false),
        ),
      ),
    );
  }

  Widget _chartSection({required String label, required double height, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(height: height, child: child),
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
            Text('HR ${d.minHr}–${d.avgHr}–${d.maxHr} bpm  ', style: const TextStyle(fontSize: 12)),
          if (d.hrvRmssd != null)
            Text('HRV ${d.hrvRmssd!.toStringAsFixed(1)} ms', style: const TextStyle(fontSize: 12)),
        ],
      ),
      trailing: d.steps != null && d.steps! > 0
          ? Text('${d.steps} steps', style: const TextStyle(fontSize: 12))
          : null,
    );
  }
}
