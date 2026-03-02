import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

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
        return matchesSearch && matchesMuscle;
      }).toList();
    });
  }

  List<String> _distinctMuscleGroups() {
    if (_all == null) return [];
    return _all!
        .map((e) => e.muscleGroup)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> _createExercise() async {
    final prefill = _searchCtrl.text.trim();
    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: prefill);
        String? selectedMuscleGroup;
        const muscleGroups = [
          'Chest', 'Back', 'Shoulders', 'Biceps', 'Triceps',
          'Core', 'Quads', 'Hamstrings', 'Glutes', 'Calves',
          'Full Body', 'Cardio',
        ];
        return StatefulBuilder(builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('New exercise'),
            content: Column(
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
                  value: selectedMuscleGroup,
                  hint: const Text('Muscle group (optional)'),
                  decoration: const InputDecoration(labelText: 'Muscle group'),
                  items: muscleGroups
                      .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  onChanged: (v) => setSt(() => selectedMuscleGroup = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, (ctrl.text.trim(), selectedMuscleGroup)),
                  child: const Text('Create')),
            ],
          );
        });
      },
    );
    if (result == null || result.$1.isEmpty || !mounted) return;
    try {
      final exercise = await api.createExercise(
        name: result.$1,
        muscleGroup: result.$2,
      );
      if (mounted) Navigator.pop(context, exercise);
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
            if (e.notes != null) e.notes!,
          ].join(' · ');
          return ListTile(
            title: Text(e.name),
            subtitle: sub.isNotEmpty ? Text(sub) : null,
            onTap: () => Navigator.pop(context, e),
          );
        },
      );
    }

    if (muscleGroups.isEmpty) return listContent;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _muscleFilter == null,
                  onSelected: (_) =>
                      setState(() { _muscleFilter = null; _filter(); }),
                ),
                ...muscleGroups.map((g) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: FilterChip(
                        label: Text(g),
                        selected: _muscleFilter == g,
                        onSelected: (_) =>
                            setState(() { _muscleFilter = g; _filter(); }),
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
