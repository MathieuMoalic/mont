import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'exercise_picker_screen.dart';

class ExerciseHistoryScreen extends StatefulWidget {
  final Exercise? exercise;
  const ExerciseHistoryScreen({super.key, this.exercise});

  @override
  State<ExerciseHistoryScreen> createState() => _ExerciseHistoryScreenState();
}

class _ExerciseHistoryScreenState extends State<ExerciseHistoryScreen> {
  List<Exercise>? _exercises;
  List<Exercise>? _filtered;
  Exercise? _selected;
  List<ExerciseHistoryPoint>? _history;
  ExercisePersonalRecord? _pr;
  String? _error;
  bool _showVolume = false;
  String? _muscleFilter;
  String? _equipmentFilter;

  @override
  void initState() {
    super.initState();
    _selected = widget.exercise;
    if (_selected != null) {
      _loadExercises();
      _selectExercise(_selected!);
    } else {
      _loadExercises();
    }
  }

  Future<void> _loadExercises() async {
    try {
      final list = await api.listExercises();
      if (mounted) {
        setState(() {
          _exercises = list;
          _filtered = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _applyFilters() {
    if (_exercises == null) return;
    setState(() {
      _filtered = _exercises!.where((e) {
        final matchesMuscle =
            _muscleFilter == null || e.muscleGroup == _muscleFilter;
        final matchesEquipment =
            _equipmentFilter == null || e.equipment == _equipmentFilter;
        return matchesMuscle && matchesEquipment;
      }).toList();
    });
  }

  List<String> _distinctMuscleGroups() {
    if (_exercises == null) return [];
    return _exercises!
        .map((e) => e.muscleGroup)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> _distinctEquipment() {
    if (_exercises == null) return [];
    return _exercises!
        .map((e) => e.equipment)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> _selectExercise(Exercise ex) async {
    setState(() {
      _selected = ex;
      _history = null;
      _pr = null;
    });
    try {
      final h = await api.getExerciseHistory(ex.id);
      final pr = await api.getExercisePersonalRecords(ex.id);
      if (mounted)
        setState(() {
          _history = h;
          _pr = pr;
        });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _fmtDate(DateTime d) {
    final l = d.toLocal();
    return '${l.day}/${l.month}/${l.year.toString().substring(2)}';
  }

  Future<void> _editExercise() async {
    if (_selected == null || !mounted) return;
    final result = await _showExerciseDialog(_selected!);
    if (result == null || !mounted) return;

    try {
      final equipment = result.$3;
      await api.updateExercise(
        _selected!.id,
        name: result.$1 == null || result.$1!.isEmpty ? null : result.$1,
        muscleGroup: result.$2,
        equipment: equipment,
      );
      setState(() {
        final newName = result.$1 == null || result.$1!.isEmpty
            ? _selected!.name
            : result.$1!;
        _selected = Exercise(
          id: _selected!.id,
          name: newName,
          notes: _selected!.notes,
          muscleGroup: result.$2,
          equipment: equipment,
        );
      });
      _selectExercise(_selected!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<(String?, String?, String?, String?)?> _showExerciseDialog(
    Exercise exercise,
  ) {
    final ctrl = TextEditingController(text: exercise.name);
    String? selectedMuscleGroup = exercise.muscleGroup;
    String? selectedEquipment = exercise.equipment;
    bool addingNewMuscle = false;
    bool addingNewEquipment = false;
    // Ensure the exercise's current values are always present in the dropdown
    // lists, even if they were added after the exercises were loaded.
    final muscleGroups = _distinctMuscleGroups();
    final equipment = _distinctEquipment();
    final allMuscleGroups =
        (muscleGroups.toSet()
              ..addAll([exercise.muscleGroup].whereType<String>()))
            .toList()
          ..sort();
    final allEquipment =
        (equipment.toSet()..addAll([exercise.equipment].whereType<String>()))
            .toList()
          ..sort();
    final TextEditingController equipmentCtrl = TextEditingController();
    final TextEditingController muscleCtrl = TextEditingController();

    return showDialog<(String?, String?, String?, String?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('Edit exercise'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    value: selectedMuscleGroup,
                    hint: const Text('Muscle group (optional)'),
                    decoration: const InputDecoration(
                      labelText: 'Muscle group',
                    ),
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(value: null, child: const Text('None')),
                      ...allMuscleGroups.map(
                        (g) =>
                            DropdownMenuItem<String?>(value: g, child: Text(g)),
                      ),
                      DropdownMenuItem<String?>(
                        value: '___NEW_MUSCLE___',
                        child: Row(
                          children: [
                            const Icon(Icons.add, size: 16),
                            const SizedBox(width: 4),
                            const Text('Add new muscle'),
                          ],
                        ),
                      ),
                    ].toList(),
                    onChanged: (v) {
                      if (v == '___NEW_MUSCLE___') {
                        setSt(() {
                          selectedMuscleGroup = '___NEW_MUSCLE___';
                          addingNewMuscle = true;
                        });
                      } else {
                        setSt(() {
                          selectedMuscleGroup = v;
                          addingNewMuscle = false;
                        });
                      }
                    },
                  ),
                  if (addingNewMuscle)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: muscleCtrl,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Enter new muscle group',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    value: selectedEquipment,
                    hint: const Text('Equipment (optional)'),
                    decoration: const InputDecoration(labelText: 'Equipment'),
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: const Text('No equipment'),
                      ),
                      ...allEquipment.map(
                        (e) =>
                            DropdownMenuItem<String?>(value: e, child: Text(e)),
                      ),
                      DropdownMenuItem<String?>(
                        value: '___NEW___',
                        child: Row(
                          children: [
                            const Icon(Icons.add, size: 16),
                            const SizedBox(width: 4),
                            const Text('Add new equipment'),
                          ],
                        ),
                      ),
                    ].toList(),
                    onChanged: (v) {
                      if (v == '___NEW___') {
                        setSt(() {
                          selectedEquipment = '___NEW___';
                          addingNewEquipment = true;
                        });
                      } else {
                        setSt(() {
                          selectedEquipment = v;
                          addingNewEquipment = false;
                        });
                      }
                    },
                  ),
                  if (addingNewEquipment)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: equipmentCtrl,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Enter new equipment',
                          border: OutlineInputBorder(),
                          helperText:
                              'This will be added to your equipment list',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final muscleResult = addingNewMuscle
                      ? (muscleCtrl.text.trim().isEmpty
                            ? null
                            : muscleCtrl.text.trim())
                      : selectedMuscleGroup;
                  final equipmentResult = addingNewEquipment
                      ? (equipmentCtrl.text.trim().isEmpty
                            ? null
                            : equipmentCtrl.text.trim())
                      : selectedEquipment;
                  Navigator.pop(ctx, (
                    ctrl.text.trim(),
                    muscleResult,
                    equipmentResult,
                    null,
                  ));
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPRCard(ExercisePersonalRecord pr) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emoji_events, color: Color(0xFFC4B5FD)),
                const SizedBox(width: 8),
                Text(
                  'Personal Records',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _prItem(
                    '🏋️',
                    'Max Weight',
                    '${pr.maxWeightKg.toStringAsFixed(1)} kg',
                    '${pr.maxWeightReps} reps on ${_fmtDate(pr.maxWeightDate)}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _prItem(
                    '💪',
                    'Max Reps',
                    '${pr.maxReps} reps',
                    '${pr.maxRepsWeightKg.toStringAsFixed(1)} kg on ${_fmtDate(pr.maxRepsDate)}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _prItem(
                    '📊',
                    'Max Volume',
                    '${pr.maxVolumeWorkout.toStringAsFixed(0)} kg',
                    'on ${_fmtDate(pr.maxVolumeDate)}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _prItem(
                    '⭐',
                    'Best Set',
                    '${pr.bestSetWeightKg.toStringAsFixed(1)} kg × ${pr.bestSetReps}',
                    'on ${_fmtDate(pr.bestSetDate)}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _prItem(String emoji, String label, String value, String detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: const Color(0xFFC4B5FD),
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          detail,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected == null ? 'Exercise History' : _selected!.name),
        actions: [
          if (_selected != null)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit exercise',
              onPressed: () => _editExercise(),
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
      return const Center(
        child: Text('No workout sets recorded for this exercise yet.'),
      );
    }
    return _buildHistoryView();
  }

  Widget _buildExercisePicker() {
    if (_exercises == null)
      return const Center(child: CircularProgressIndicator());

    final muscleGroups = _distinctMuscleGroups();
    final equipmentList = _distinctEquipment();
    final filtered = _filtered ?? _exercises!;

    return CustomScrollView(
      slivers: [
        // Muscle group filter chips
        if (muscleGroups.isNotEmpty)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('All muscles'),
                    selected: _muscleFilter == null,
                    onSelected: (_) {
                      setState(() => _muscleFilter = null);
                      _applyFilters();
                    },
                  ),
                  ...muscleGroups.map(
                    (g) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: FilterChip(
                        label: Text(g),
                        selected: _muscleFilter == g,
                        onSelected: (_) {
                          setState(() => _muscleFilter = g);
                          _applyFilters();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Equipment filter chips
        if (equipmentList.isNotEmpty)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('All equipment'),
                    selected: _equipmentFilter == null,
                    onSelected: (_) {
                      setState(() => _equipmentFilter = null);
                      _applyFilters();
                    },
                  ),
                  ...equipmentList.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: FilterChip(
                        label: Text(e),
                        selected: _equipmentFilter == e,
                        onSelected: (_) {
                          setState(() => _equipmentFilter = e);
                          _applyFilters();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Exercise list
        if (filtered.isEmpty)
          const SliverFillRemaining(
            child: Center(
              child: Text('No exercises match the selected filters.'),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((ctx, i) {
              final ex = filtered[i];
              final subtitle = [
                if (ex.muscleGroup != null) ex.muscleGroup!,
                if (ex.equipment != null) ex.equipment!,
              ].join(' • ');
              return ListTile(
                title: Text(ex.name),
                subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _selectExercise(ex),
              );
            }, childCount: filtered.length),
          ),
      ],
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
          // Personal Records Card
          if (_pr != null) _buildPRCard(_pr!),
          if (_pr != null) const SizedBox(height: 16),
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
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: Colors.grey.withValues(alpha: 0.2),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 52,
                      getTitlesWidget: (v, _) => Text(
                        useVolume
                            ? '${v.round()}'
                            : '${v.toStringAsFixed(1)}kg',
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
                        if (i < 0 || i >= history.length)
                          return const SizedBox.shrink();
                        return Text(
                          _fmtDate(history[i].workoutDate),
                          style: const TextStyle(fontSize: 9),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
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
              _statCard(
                '🏋️ Current max',
                '${lastMaxWeight.toStringAsFixed(1)} kg',
              ),
              _statCard(
                '🏅 All-time PR',
                '${pr.maxWeightKg.toStringAsFixed(1)} kg\n${_fmtDate(pr.workoutDate)}',
              ),
              _statCard('💪 Est. 1RM', _fmt1RM(history)),
              _statCard('📅 Sessions', '${history.length}'),
              _statCard(
                '🔁 Total sets',
                '${history.fold(0, (s, p) => s + p.totalSets)}',
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Recent sessions table
          Text(
            'Recent sessions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildTable(history),
        ],
      ),
    );
  }

  String _fmt1RM(List<ExerciseHistoryPoint> history) {
    final best = history
        .map((p) => p.estimated1RM)
        .reduce((a, b) => a > b ? a : b);
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
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
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
            border: Border(
              bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            ),
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
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
      ),
    ),
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
