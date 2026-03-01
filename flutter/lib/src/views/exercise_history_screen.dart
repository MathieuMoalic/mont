import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

class ExerciseHistoryScreen extends StatefulWidget {
  const ExerciseHistoryScreen({super.key});

  @override
  State<ExerciseHistoryScreen> createState() => _ExerciseHistoryScreenState();
}

class _ExerciseHistoryScreenState extends State<ExerciseHistoryScreen> {
  List<Exercise>? _exercises;
  Exercise? _selected;
  List<ExerciseHistoryPoint>? _history;
  String? _error;
  bool _showVolume = false;

  @override
  void initState() {
    super.initState();
    _loadExercises();
  }

  Future<void> _loadExercises() async {
    try {
      final list = await api.listExercises();
      if (mounted) setState(() { _exercises = list; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _selectExercise(Exercise ex) async {
    setState(() { _selected = ex; _history = null; });
    try {
      final h = await api.getExerciseHistory(ex.id);
      if (mounted) setState(() => _history = h);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _fmtDate(DateTime d) {
    final l = d.toLocal();
    return '${l.day}/${l.month}/${l.year.toString().substring(2)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected == null ? 'Exercise History' : _selected!.name),
        actions: [
          if (_selected != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_ios),
              tooltip: 'Pick another exercise',
              onPressed: () => setState(() { _selected = null; _history = null; }),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (_selected == null) {
      return _buildExercisePicker();
    }
    if (_history == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_history!.isEmpty) {
      return const Center(child: Text('No workout sets recorded for this exercise yet.'));
    }
    return _buildHistoryView();
  }

  Widget _buildExercisePicker() {
    if (_exercises == null) return const Center(child: CircularProgressIndicator());
    return ListView.builder(
      itemCount: _exercises!.length,
      itemBuilder: (ctx, i) {
        final ex = _exercises![i];
        return ListTile(
          title: Text(ex.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _selectExercise(ex),
        );
      },
    );
  }

  Widget _buildHistoryView() {
    final history = _history!;
    final useVolume = _showVolume;

    final values = useVolume
        ? history.map((p) => p.totalVolume).toList()
        : history.map((p) => p.maxWeightKg).toList();
    final maxY = values.reduce((a, b) => a > b ? a : b);
    final minY = values.reduce((a, b) => a < b ? a : b);
    final yPad = (maxY - minY) * 0.15;
    final effectiveMin = (minY - yPad).clamp(0.0, double.infinity);
    final effectiveMax = maxY + yPad;

    final spots = List.generate(
      history.length,
      (i) => FlSpot(i.toDouble(), values[i]),
    );

    final lastMaxWeight = history.last.maxWeightKg;
    final pr = history.reduce((a, b) => a.maxWeightKg >= b.maxWeightKg ? a : b);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toggle chip
          Row(
            children: [
              ChoiceChip(
                label: const Text('Max weight'),
                selected: !_showVolume,
                onSelected: (_) => setState(() => _showVolume = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Volume (kg·reps)'),
                selected: _showVolume,
                onSelected: (_) => setState(() => _showVolume = true),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Chart
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                minY: effectiveMin,
                maxY: effectiveMax,
                gridData: FlGridData(
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: Colors.grey.withValues(alpha: 0.2), strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 52,
                      getTitlesWidget: (v, _) => Text(
                        useVolume ? '${v.round()}' : '${v.toStringAsFixed(1)}kg',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: _xInterval(history.length),
                      getTitlesWidget: (v, _) {
                        final i = v.round();
                        if (i < 0 || i >= history.length) return const SizedBox.shrink();
                        return Text(_fmtDate(history[i].workoutDate),
                            style: const TextStyle(fontSize: 9));
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => spots.map((s) {
                      final i = s.x.round();
                      final p = history[i];
                      final label = useVolume
                          ? '${p.totalVolume.toStringAsFixed(0)} kg·reps'
                          : '${p.maxWeightKg.toStringAsFixed(1)} kg';
                      return LineTooltipItem(
                        '${_fmtDate(p.workoutDate)}\n$label',
                        const TextStyle(color: Colors.white, fontSize: 12),
                      );
                    }).toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.3,
                    color: Theme.of(context).colorScheme.primary,
                    barWidth: 2.5,
                    dotData: FlDotData(show: history.length <= 20),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Stats cards
          Text('Stats', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _statCard('🏋️ Current max', '${lastMaxWeight.toStringAsFixed(1)} kg'),
              _statCard('🏅 All-time PR', '${pr.maxWeightKg.toStringAsFixed(1)} kg\n${_fmtDate(pr.workoutDate)}'),
              _statCard('💪 Est. 1RM', _fmt1RM(history)),
              _statCard('📅 Sessions', '${history.length}'),
              _statCard('🔁 Total sets', '${history.fold(0, (s, p) => s + p.totalSets)}'),
            ],
          ),
          const SizedBox(height: 24),
          // Recent sessions table
          Text('Recent sessions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildTable(history),
        ],
      ),
    );
  }

  String _fmt1RM(List<ExerciseHistoryPoint> history) {
    final best = history.map((p) => p.estimated1RM).reduce((a, b) => a > b ? a : b);
    return '${best.toStringAsFixed(1)} kg';
  }

  double _xInterval(int n) {
    if (n <= 6) return 1;
    if (n <= 12) return 2;
    if (n <= 30) return 5;
    return (n / 6).roundToDouble();
  }

  Widget _statCard(String label, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(List<ExerciseHistoryPoint> history) {
    final recent = history.reversed.take(10).toList();
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3))),
          ),
          children: const [
            _HeaderCell('Date'),
            _HeaderCell('Max weight'),
            _HeaderCell('Sets'),
            _HeaderCell('Reps'),
          ],
        ),
        ...recent.map(
          (p) => TableRow(
            children: [
              _Cell(_fmtDate(p.workoutDate)),
              _Cell('${p.maxWeightKg.toStringAsFixed(1)} kg'),
              _Cell('${p.totalSets}'),
              _Cell('${p.totalReps}'),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
      );
}

class _Cell extends StatelessWidget {
  final String text;
  const _Cell(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
}
