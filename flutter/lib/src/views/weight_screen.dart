import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

class WeightScreen extends StatefulWidget {
  const WeightScreen({super.key});

  @override
  State<WeightScreen> createState() => _WeightScreenState();
}

class _WeightScreenState extends State<WeightScreen> {
  List<WeightEntry>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await api.listWeight();
      if (mounted) setState(() { _entries = entries; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _addEntry() async {
    double? entered;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log weight'),
        content: TextFormField(
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Weight (kg)', suffixText: 'kg'),
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _deleteEntry(WeightEntry entry) async {
    try {
      await api.deleteWeightEntry(entry.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Weight')),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: _addEntry,
        child: const Icon(Icons.add),
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
    if (_entries == null) return const Center(child: CircularProgressIndicator());
    if (_entries!.isEmpty) {
      return const Center(
        child: Text(
          'No weight entries yet.\nTap + to log your weight.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          if (_entries!.length >= 2)
            SliverToBoxAdapter(child: _buildChart()),
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 80),
            sliver: SliverList.builder(
              itemCount: _entries!.length,
              itemBuilder: (ctx, i) {
                // Show most recent first in list
                final entry = _entries![_entries!.length - 1 - i];
                return ListTile(
                  leading: const Icon(Icons.monitor_weight_outlined),
                  title: Text('${entry.weightKg} kg'),
                  subtitle: Text(_formatDate(entry.measuredAt)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteEntry(entry),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart() {
    final spots = _entries!
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.weightKg))
        .toList();

    final weights = _entries!.map((e) => e.weightKg).toList();
    final minW = weights.reduce((a, b) => a < b ? a : b);
    final maxW = weights.reduce((a, b) => a > b ? a : b);
    final padding = (maxW - minW) < 1 ? 1.0 : (maxW - minW) * 0.15;
    final minY = (minW - padding).floorToDouble();
    final maxY = (maxW + padding).ceilToDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 24, 8),
      child: SizedBox(
        height: 200,
        child: LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
            gridData: const FlGridData(show: true),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (v, _) => Text(
                    v.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  interval: _bottomInterval(spots.length),
                  getTitlesWidget: (v, _) {
                    final idx = v.toInt();
                    if (idx < 0 || idx >= _entries!.length) {
                      return const SizedBox.shrink();
                    }
                    final d = _entries![idx].measuredAt.toLocal();
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${d.day}/${d.month}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.3,
                color: Theme.of(context).colorScheme.primary,
                barWidth: 2.5,
                dotData: FlDotData(show: spots.length <= 30),
                belowBarData: BarAreaData(
                  show: true,
                  color: Theme.of(context).colorScheme.primary.withAlpha(40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _bottomInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 14) return 2;
    if (count <= 30) return 5;
    return (count / 6).roundToDouble();
  }

  String _formatDate(DateTime utc) {
    final d = utc.toLocal();
    final now = DateTime.now();
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'Today, $h:$m';
    }
    return '${d.day}/${d.month}/${d.year}';
  }
}
