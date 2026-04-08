import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import '../theme.dart';

class ExercisePickerScreen extends StatefulWidget {
  const ExercisePickerScreen({super.key});

  @override
  State<ExercisePickerScreen> createState() => _ExercisePickerScreenState();
}

class _ExercisePickerScreenState extends State<ExercisePickerScreen> {
  List<Exercise>? _all;
  List<Exercise> _filtered = [];
  final _searchCtrl = TextEditingController();
  String? _error;
  String? _muscleFilter;
  String? _equipmentFilter;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final exercises = await api.listExercises();
      if (mounted) {
        setState(() {
          _all = exercises;
          _filtered = exercises;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _filter() {
    if (_all == null) return;
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _all!.where((e) {
        final matchesSearch = e.name.toLowerCase().contains(q);
        final matchesMuscle =
            _muscleFilter == null || e.muscleGroup == _muscleFilter;
        final matchesEquipment =
            _equipmentFilter == null || e.equipment == _equipmentFilter;
        return matchesSearch && matchesMuscle && matchesEquipment;
      }).toList();
    });
  }

  List<String> _distinctMuscleGroups() {
    if (_all == null) return [];
    return _all!
        .map((e) => e.muscleGroup)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> _distinctEquipment() {
    if (_all == null) return [];
    return _all!
        .map((e) => e.equipment)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> _createExercise() async {
    final prefill = _searchCtrl.text.trim();
    final result = await _showExerciseDialog(
      title: 'New exercise',
      initialName: prefill,
    );
    if (result == null || result.$1.isEmpty || !mounted) return;
    try {
      final exercise = await api.createExercise(
        name: result.$1,
        muscleGroup: result.$2,
        equipment: result.$3,
      );
      if (mounted) Navigator.pop(context, exercise);
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _editExercise(Exercise exercise) async {
    final result = await _showExerciseDialog(
      title: 'Edit exercise',
      initialName: exercise.name,
      initialMuscleGroup: exercise.muscleGroup,
      initialEquipment: exercise.equipment,
      initialNotes: exercise.notes,
    );
    if (result == null || !mounted) return;
    try {
      await api.updateExercise(
        exercise.id,
        name: result.$1.isEmpty ? null : result.$1,
        muscleGroup: result.$2,
        equipment: result.$3,
      );
      _load();
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<(String, String?, String?)?> _showExerciseDialog({
    required String title,
    String initialName = '',
    String? initialMuscleGroup,
    String? initialEquipment,
    String? initialNotes,
  }) {
    final ctrl = TextEditingController(text: initialName);
    String? selectedMuscleGroup = initialMuscleGroup;
    String? selectedEquipment = initialEquipment;
    const muscleGroups = [
      'Chest', 'Back', 'Shoulders', 'Biceps', 'Triceps',
      'Core', 'Quads', 'Hamstrings', 'Glutes', 'Calves',
      'Full Body', 'Cardio',
    ];
    const equipment = [
      'Barbell', 'Dumbbell', 'Machine', 'Cable', 'Smith',
      'Bodyweight', 'Kettlebell', 'Band',
    ];
    return showDialog<(String, String?, String?)>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return AlertDialog(
            title: Text(title),
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
                  DropdownButtonFormField<String>(
                    initialValue: selectedMuscleGroup,
                    hint: const Text('Muscle group (optional)'),
                    decoration: const InputDecoration(labelText: 'Muscle group'),
                    items: muscleGroups
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: (v) => setSt(() => selectedMuscleGroup = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedEquipment,
                    hint: const Text('Equipment (optional)'),
                    decoration: const InputDecoration(labelText: 'Equipment'),
                    items: equipment
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setSt(() => selectedEquipment = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, (ctrl.text.trim(), selectedMuscleGroup, selectedEquipment)),
                  child: const Text('Save')),
            ],
          );
        });
      },
    ).whenComplete(() => ctrl.dispose());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search exercises…',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New exercise',
            onPressed: _createExercise,
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
    if (_all == null) return const Center(child: CircularProgressIndicator());

    final muscleGroups = _distinctMuscleGroups();
    final equipmentList = _distinctEquipment();

    Widget listContent;
    if (_filtered.isEmpty) {
      final q = _searchCtrl.text.trim();
      listContent = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No exercises found.'),
            TextButton(
              onPressed: _createExercise,
              child: Text('Create "${q.isEmpty ? 'new exercise' : q}"'),
            ),
          ],
        ),
      );
    } else {
      listContent = ListView.builder(
        shrinkWrap: muscleGroups.isNotEmpty,
        physics: muscleGroups.isNotEmpty
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: _filtered.length,
        itemBuilder: (ctx, i) {
          final e = _filtered[i];
          final sub = [
            if (e.muscleGroup != null) e.muscleGroup!,
            if (e.equipment != null) e.equipment!,
          ].join(' • ');
          return ListTile(
            leading: Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: MontColors.getMuscleAccent(e.muscleGroup),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            title: Text(e.displayName),
            subtitle: sub.isNotEmpty ? Text(sub) : null,
            onTap: () => Navigator.pop(context, e),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => _editExercise(e),
              tooltip: 'Edit exercise',
            ),
          );
        },
      );
    }

    if (muscleGroups.isEmpty && equipmentList.isEmpty) return listContent;

    return CustomScrollView(
      slivers: [
        // Muscle group filter
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
                    onSelected: (_) =>
                        setState(() { _muscleFilter = null; _filter(); }),
                  ),
                  ...muscleGroups.map((g) => Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: FilterChip(
                          label: Text(g),
                          selected: _muscleFilter == g,
                          backgroundColor: MontColors.getMuscleColor(g),
                          selectedColor: MontColors.getMuscleAccent(g),
                          side: BorderSide(
                            color: MontColors.getMuscleAccent(g),
                            width: _muscleFilter == g ? 2 : 1,
                          ),
                          onSelected: (_) =>
                              setState(() { _muscleFilter = g; _filter(); }),
                        ),
                      )),
                ],
              ),
            ),
          ),
        // Equipment filter
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
                    onSelected: (_) =>
                        setState(() { _equipmentFilter = null; _filter(); }),
                  ),
                  ...equipmentList.map((e) => Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: FilterChip(
                          label: Text(e),
                          selected: _equipmentFilter == e,
                          onSelected: (_) =>
                              setState(() { _equipmentFilter = e; _filter(); }),
                        ),
                      )),
                ],
              ),
            ),
          ),
        SliverFillRemaining(child: listContent),
      ],
    );
  }
}
