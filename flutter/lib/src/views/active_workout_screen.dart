import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'exercise_picker_screen.dart';
import 'templates_screen.dart';

class ActiveWorkoutScreen extends StatefulWidget {
  final int workoutId;
  const ActiveWorkoutScreen({super.key, required this.workoutId});

  @override
  State<ActiveWorkoutScreen> createState() => _ActiveWorkoutScreenState();
}

class _ActiveWorkoutScreenState extends State<ActiveWorkoutScreen> {
  WorkoutDetail? _workout;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final w = await api.getWorkout(widget.workoutId);
      if (mounted) setState(() { _workout = w; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _applyTemplate() async {
    final template = await Navigator.push<TemplateSummary>(
      context,
      MaterialPageRoute(builder: (_) => const TemplatesScreen(selectMode: true)),
    );
    if (template == null || !mounted) return;
    try {
      await api.applyTemplate(templateId: template.id, workoutId: widget.workoutId);
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Applied "${template.name}"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _addSet() async {
    final exercise = await Navigator.push<Exercise>(
      context,
      MaterialPageRoute(builder: (_) => const ExercisePickerScreen()),
    );
    if (exercise == null || !mounted) return;

    final setsForExercise =
        _workout!.sets.where((s) => s.exerciseId == exercise.id).toList();
    final setNum = setsForExercise.length + 1;

    // Pre-fill with last logged values for this exercise
    int defaultReps = 8;
    double defaultWeight = 0;
    if (setsForExercise.isNotEmpty) {
      final last = setsForExercise.last;
      defaultReps = last.reps;
      defaultWeight = last.weightKg;
    } else {
      try {
        final history = await api.getExerciseHistory(exercise.id);
        if (history.isNotEmpty) {
          final last = history.last;
          defaultReps = last.repsAtMax;
          defaultWeight = last.maxWeightKg;
        }
      } catch (_) {}
    }
    if (!mounted) return;

    final result = await _showAddSetDialog(exercise.name, setNum,
        defaultReps: defaultReps, defaultWeight: defaultWeight);
    if (result == null || !mounted) return;

    try {
      await api.addSet(
        workoutId: widget.workoutId,
        exerciseId: exercise.id,
        setNumber: setNum,
        reps: result.$1,
        weightKg: result.$2,
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<(int, double)?> _showAddSetDialog(String exerciseName, int setNum,
      {int defaultReps = 8, double defaultWeight = 0}) {
    String _fmt(double v) =>
        v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
    final repsCtrl = TextEditingController(text: defaultReps.toString());
    final weightCtrl = TextEditingController(text: _fmt(defaultWeight));

    void bump(TextEditingController ctrl, double delta) {
      final v = (double.tryParse(ctrl.text) ?? 0) + delta;
      final clamped = v.clamp(0.0, 9999.0);
      ctrl.text = clamped % 1 == 0
          ? clamped.toInt().toString()
          : clamped.toStringAsFixed(1);
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    }

    return showDialog<(int, double)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(exerciseName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set $setNum',
                style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 16),
            _counterRow('Weight (kg)', weightCtrl,
                onDec: () => bump(weightCtrl, -2.5),
                onInc: () => bump(weightCtrl, 2.5),
                decimal: true),
            const SizedBox(height: 8),
            _counterRow('Reps', repsCtrl,
                onDec: () => bump(repsCtrl, -1),
                onInc: () => bump(repsCtrl, 1),
                decimal: false),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final reps = (int.tryParse(repsCtrl.text) ?? 1).clamp(1, 9999);
              final weight =
                  (double.tryParse(weightCtrl.text) ?? 0).clamp(0.0, 9999.0);
              Navigator.pop(ctx, (reps, weight));
            },
            child: const Text('Log Set'),
          ),
        ],
      ),
    ).whenComplete(() {
      repsCtrl.dispose();
      weightCtrl.dispose();
    });
  }

  Widget _counterRow(
    String label,
    TextEditingController ctrl, {
    required VoidCallback onDec,
    required VoidCallback onInc,
    required bool decimal,
  }) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(icon: const Icon(Icons.remove), onPressed: onDec),
        SizedBox(
          width: 72,
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.numberWithOptions(decimal: decimal),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        IconButton(icon: const Icon(Icons.add), onPressed: onInc),
      ],
    );
  }

  Future<void> _finishWorkout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish workout?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Finish')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await api.finishWorkout(widget.workoutId);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _deleteSet(int setId) async {
    try {
      await api.deleteSet(workoutId: widget.workoutId, setId: setId);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  String _formatDate(DateTime utc) {
    final d = utc.toLocal();
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day}/${d.month}/${d.year} $h:$m';
  }

  String _weightStr(double kg) =>
      kg % 1 == 0 ? '${kg.toInt()}kg' : '${kg}kg';

  @override
  Widget build(BuildContext context) {
    final isActive = _workout?.isActive ?? true;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _workout == null ? 'Workout' : _formatDate(_workout!.startedAt),
        ),
        actions: [
          if (isActive && _workout != null) ...[
            IconButton(
              icon: const Icon(Icons.content_copy_outlined),
              tooltip: 'Apply template',
              onPressed: _applyTemplate,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _finishWorkout,
                child: const Text('Finish'),
              ),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: isActive
          ? FloatingActionButton(
              onPressed: _addSet,
              child: const Icon(Icons.add),
            )
          : null,
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
    if (_workout == null) return const Center(child: CircularProgressIndicator());
    if (_workout!.sets.isEmpty) {
      return const Center(
        child: Text(
          'No sets logged yet.\nTap + to add an exercise.',
          textAlign: TextAlign.center,
        ),
      );
    }

    // Group sets by exercise, preserving first-seen order
    final Map<int, List<WorkoutSet>> byExercise = {};
    final List<int> order = [];
    for (final s in _workout!.sets) {
      if (!byExercise.containsKey(s.exerciseId)) {
        byExercise[s.exerciseId] = [];
        order.add(s.exerciseId);
      }
      byExercise[s.exerciseId]!.add(s);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: order.length,
      itemBuilder: (ctx, i) {
        final sets = byExercise[order[i]]!;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  sets.first.exerciseName,
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              ...sets.map(
                (s) => ListTile(
                  dense: true,
                  title: Text(
                    'Set ${s.setNumber}   ${_weightStr(s.weightKg)} × ${s.reps} reps',
                  ),
                  trailing: _workout!.isActive
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _deleteSet(s.id),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
  }
}
