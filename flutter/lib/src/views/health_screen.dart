import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

enum _Range {
  twoWeeks('2W', 14),
  oneMonth('1M', 30),
  threeMonths('3M', 90),
  all('All', 0);

  const _Range(this.label, this.days);
  final String label;
  final int days; // 0 = unlimited
}

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  List<DailyHealth>? _days;
  List<WeightEntry>? _weights;
  String? _error;
  bool _syncing = false;
  _Range _range = _Range.twoWeeks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([api.listDailyHealth(), api.listWeight()]);
      if (mounted) {
        setState(() {
          _days = results[0] as List<DailyHealth>;
          _weights = results[1] as List<WeightEntry>;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final result = await api.syncGadgetbridge();
      final healthDays = result['health_days'] as int? ?? 0;
      final imported = result['imported'] as int? ?? 0;
      final errors = (result['errors'] as List?)?.cast<String>() ?? [];
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Synced: $imported runs, $healthDays health days'
              '${errors.isNotEmpty ? ', ${errors.length} errors' : ''}'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _addWeight() async {
    double? entered;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log body mass'),
        content: TextFormField(
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Body mass (kg)', suffixText: 'kg'),
          onChanged: (v) => entered = double.tryParse(v),
          onFieldSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirmed != true || entered == null || entered! <= 0 || !mounted) return;
    try {
      await api.createWeightEntry(weightKg: entered!);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _deleteWeight(WeightEntry entry) async {
    try {
      await api.deleteWeightEntry(entry.id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _editWeight(WeightEntry entry) async {
    final d = entry.measuredAt.toLocal();
    final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    double? newKg = entry.weightKg;
    String? newDate = dateStr;
    final kgCtrl = TextEditingController(text: entry.weightKg.toStringAsFixed(1));
    final dateCtrl = TextEditingController(text: dateStr);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: kgCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Body mass (kg)', suffixText: 'kg'),
              onChanged: (v) => newKg = double.tryParse(v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: dateCtrl,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(labelText: 'Date (YYYY-MM-DD)'),
              onChanged: (v) => newDate = v.trim(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    kgCtrl.dispose();
    dateCtrl.dispose();
    if (confirmed != true || !mounted) return;
    try {
      final measuredAt = newDate != null && newDate!.isNotEmpty ? '${newDate!}T12:00:00Z' : null;
      await api.updateWeightEntry(entry.id, weightKg: newKg, measuredAt: measuredAt);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  List<DailyHealth> get _filteredDays {
    final all = _days ?? [];
    if (_range.days == 0 || all.isEmpty) return all;
    final cutoff = DateTime.now().subtract(Duration(days: _range.days));
    final cutStr = '${cutoff.year}-${cutoff.month.toString().padLeft(2,'0')}-${cutoff.day.toString().padLeft(2,'0')}';
    return all.where((d) => d.date.compareTo(cutStr) >= 0).toList();
  }

  List<WeightEntry> get _filteredWeights {
    final all = _weights ?? [];
    if (_range.days == 0 || all.isEmpty) return all;
    final cutoff = DateTime.now().subtract(Duration(days: _range.days));
    return all.where((w) => w.measuredAt.isAfter(cutoff)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _addWeight,
        tooltip: 'Log body mass',
        child: const Icon(Icons.monitor_weight_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _error != null
            ? Center(child: Text(_error!))
            : (_days == null || _weights == null)
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final days = _filteredDays;
    final weights = _filteredWeights;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('Health'),
          floating: true,
          actions: [
            if (_syncing)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Sync from Gadgetbridge',
                onPressed: _sync,
              ),
          ],
        ),
        SliverToBoxAdapter(child: _buildRangeChips()),
        SliverToBoxAdapter(child: _buildHrChart(days)),
        SliverToBoxAdapter(child: _buildHrvChart(days)),
        SliverToBoxAdapter(child: _buildStepsChart(days)),
        SliverToBoxAdapter(child: _buildWeightChart(weights)),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              final entry = (_weights!)[_weights!.length - 1 - i];
              final d = entry.measuredAt.toLocal();
              return Dismissible(
                key: ValueKey(entry.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => _deleteWeight(entry),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.monitor_weight_outlined),
                  title: Text('${entry.weightKg} kg'),
                  subtitle: Text('${d.day}/${d.month}/${d.year}'),
                  onTap: () => _editWeight(entry),
                  trailing: const Icon(Icons.edit_outlined, size: 16),
                ),
              );
            },
            childCount: _weights!.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Widget _buildRangeChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: _Range.values.map((r) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilterChip(
            label: Text(r.label),
            selected: _range == r,
            onSelected: (_) => setState(() => _range = r),
            visualDensity: VisualDensity.compact,
          ),
        )).toList(),
      ),
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────

  FlTitlesData _axisTitles({required double yReserved}) => FlTitlesData(
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: yReserved,
        getTitlesWidget: (v, meta) {
          if (v == meta.min || v == meta.max) return const SizedBox.shrink();
          return Text(meta.formattedValue, style: const TextStyle(fontSize: 10));
        },
      ),
    ),
    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
  );

  LineTouchData _intTooltip(List<DailyHealth> days, {int decimals = 0}) => LineTouchData(
    touchTooltipData: LineTouchTooltipData(
      getTooltipItems: (spots) => spots.map((s) {
        final idx = s.x.toInt();
        final date = idx >= 0 && idx < days.length ? days[idx].date : '';
        return LineTooltipItem(
          '${s.y.toStringAsFixed(decimals)}\n$date',
          const TextStyle(fontSize: 11),
        );
      }).toList(),
    ),
  );

  Widget _chartSection({required String label, required double height, required Widget child, Widget? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            if (action != null) ...[const Spacer(), action],
          ]),
          const SizedBox(height: 8),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }

  // ── Charts ────────────────────────────────────────────────────────────────

  Widget _buildHrChart(List<DailyHealth> days) {
    final hrDays = days.where((d) => d.avgHr != null).toList();
    if (hrDays.isEmpty) {
      return _chartSection(label: 'Heart Rate (bpm)', height: 48,
          child: const Center(child: Text('No HR data in range', style: TextStyle(fontSize: 12))));
    }
    final indexed = hrDays.asMap().entries.toList();
    final avgSpots = indexed.map((e) => FlSpot(e.key.toDouble(), e.value.avgHr!.toDouble())).toList();
    final minSpots = indexed.map((e) => FlSpot(e.key.toDouble(), (e.value.minHr ?? e.value.avgHr!).toDouble())).toList();
    final maxSpots = indexed.map((e) => FlSpot(e.key.toDouble(), (e.value.maxHr ?? e.value.avgHr!).toDouble())).toList();
    final allHr = hrDays.expand((d) => [d.minHr ?? d.avgHr!, d.maxHr ?? d.avgHr!]).map((v) => v.toDouble());
    final minY = (allHr.reduce((a, b) => a < b ? a : b) - 5).clamp(0, 300).toDouble();
    final maxY = allHr.reduce((a, b) => a > b ? a : b) + 5;
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'Heart Rate (bpm)',
      height: 160,
      child: LineChart(LineChartData(
        minY: minY, maxY: maxY,
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: _axisTitles(yReserved: 44),
        lineTouchData: _intTooltip(hrDays),
        lineBarsData: [
          LineChartBarData(spots: minSpots, isCurved: true, color: scheme.primary.withValues(alpha: 0.45), dotData: FlDotData(show: false), barWidth: 1.5, dashArray: [4, 4]),
          LineChartBarData(spots: avgSpots, isCurved: true, color: scheme.primary, dotData: FlDotData(show: false), barWidth: 2),
          LineChartBarData(spots: maxSpots, isCurved: true, color: scheme.primary.withValues(alpha: 0.45), dotData: FlDotData(show: false), barWidth: 1.5, dashArray: [4, 4]),
        ],
      )),
    );
  }

  Widget _buildHrvChart(List<DailyHealth> days) {
    final hrvDays = days.where((d) => d.hrvRmssd != null).toList();
    if (hrvDays.isEmpty) {
      return _chartSection(label: 'HRV (ms)', height: 48,
          child: const Center(child: Text('No HRV data in range', style: TextStyle(fontSize: 12))));
    }
    final indexed = hrvDays.asMap().entries.toList();
    final spots = indexed.map((e) => FlSpot(e.key.toDouble(), e.value.hrvRmssd!)).toList();
    final values = hrvDays.map((d) => d.hrvRmssd!);
    final minY = (values.reduce((a, b) => a < b ? a : b) - 2).clamp(0, 9999).toDouble();
    final maxY = values.reduce((a, b) => a > b ? a : b) + 2;
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'HRV (ms)',
      height: 120,
      child: LineChart(LineChartData(
        minY: minY, maxY: maxY,
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: _axisTitles(yReserved: 44),
        lineTouchData: _intTooltip(hrvDays),
        lineBarsData: [
          LineChartBarData(
            spots: spots, isCurved: true, color: scheme.tertiary,
            dotData: FlDotData(show: false), barWidth: 2,
            belowBarData: BarAreaData(show: true, color: scheme.tertiary.withValues(alpha: 0.10)),
          ),
        ],
      )),
    );
  }

  Widget _buildStepsChart(List<DailyHealth> days) {
    final stepDays = days.where((d) => d.steps != null && d.steps! > 0).toList();
    if (stepDays.isEmpty) {
      return _chartSection(label: 'Steps per day', height: 48,
          child: const Center(child: Text('No steps data in range', style: TextStyle(fontSize: 12))));
    }
    final scheme = Theme.of(context).colorScheme;
    final bars = stepDays.asMap().entries.map((e) => BarChartGroupData(
      x: e.key,
      barRods: [BarChartRodData(
        toY: e.value.steps!.toDouble(), color: scheme.secondary,
        width: stepDays.length > 60 ? 2 : 5,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
      )],
    )).toList();
    final maxY = stepDays.map((d) => d.steps!.toDouble()).reduce((a, b) => a > b ? a : b) * 1.1;
    return _chartSection(
      label: 'Steps per day',
      height: 120,
      child: BarChart(BarChartData(
        maxY: maxY,
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: _axisTitles(yReserved: 52),
        barGroups: bars,
        barTouchData: BarTouchData(enabled: false),
      )),
    );
  }

  Widget _buildWeightChart(List<WeightEntry> weights) {
    if (weights.length < 2) {
      return _chartSection(
        label: 'Body Mass (kg)',
        height: 48,
        child: Center(child: Text(
          weights.isEmpty ? 'No body mass entries in range' : 'Need at least 2 entries to show chart',
          style: const TextStyle(fontSize: 12),
        )),
      );
    }
    final spots = weights.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value.weightKg)).toList();
    final ws = weights.map((w) => w.weightKg);
    final minW = ws.reduce((a, b) => a < b ? a : b);
    final maxW = ws.reduce((a, b) => a > b ? a : b);
    final pad = (maxW - minW) < 1 ? 1.0 : (maxW - minW) * 0.15;
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'Body Mass (kg)',
      height: 160,
      child: LineChart(LineChartData(
        minY: (minW - pad).floorToDouble(),
        maxY: (maxW + pad).ceilToDouble(),
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true, reservedSize: 44,
            getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 10)),
          )),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              final idx = s.x.toInt();
              final d = idx >= 0 && idx < weights.length ? weights[idx].measuredAt.toLocal() : null;
              final date = d != null ? '${d.day}/${d.month}/${d.year}' : '';
              return LineTooltipItem('${s.y.toStringAsFixed(1)} kg\n$date', const TextStyle(fontSize: 11));
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots, isCurved: true, curveSmoothness: 0.3,
            color: scheme.primary, barWidth: 2.5,
            dotData: FlDotData(show: spots.length <= 30),
            belowBarData: BarAreaData(show: true, color: scheme.primary.withValues(alpha: 0.10)),
          ),
        ],
      )),
    );
  }
}
