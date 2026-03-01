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
      _filtered =
          _all!.where((e) => e.name.toLowerCase().contains(q)).toList();
    });
  }

  Future<void> _createExercise() async {
    final prefill = _searchCtrl.text.trim();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: prefill);
        return AlertDialog(
          title: const Text('New exercise'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final exercise = await api.createExercise(name: name);
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
    if (_filtered.isEmpty) {
      final q = _searchCtrl.text.trim();
      return Center(
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
    }
    return ListView.builder(
      itemCount: _filtered.length,
      itemBuilder: (ctx, i) {
        final e = _filtered[i];
        return ListTile(
          title: Text(e.name),
          subtitle: e.notes != null ? Text(e.notes!) : null,
          onTap: () => Navigator.pop(context, e),
        );
      },
    );
  }
}
