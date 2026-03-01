import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

/// Full-screen list of templates; tapping one returns it to the caller.
class TemplatesScreen extends StatefulWidget {
  /// If true, show a select mode (returns the chosen template). Otherwise
  /// manage mode (create / delete).
  final bool selectMode;

  const TemplatesScreen({super.key, this.selectMode = false});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<TemplateSummary>? _templates;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await api.listTemplates();
      if (mounted) setState(() { _templates = list; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _createTemplate() async {
    final name = await _askName(context);
    if (name == null || name.isEmpty) return;
    try {
      await api.createTemplate(name: name, sets: []);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete template?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deleteTemplate(id);
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
      appBar: AppBar(
        title: Text(widget.selectMode ? 'Choose template' : 'Templates'),
      ),
      body: _buildBody(),
      floatingActionButton: widget.selectMode
          ? null
          : FloatingActionButton(
              onPressed: _createTemplate,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (_templates == null) return const Center(child: CircularProgressIndicator());
    if (_templates!.isEmpty) {
      return Center(
        child: Text(
          widget.selectMode
              ? 'No templates yet.\nCreate one from the Templates screen.'
              : 'No templates yet.\nTap + to create one.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: _templates!.length,
      itemBuilder: (ctx, i) {
        final t = _templates![i];
        return ListTile(
          leading: const Icon(Icons.content_copy_outlined),
          title: Text(t.name),
          subtitle: Text('${t.setCount} set${t.setCount == 1 ? '' : 's'}'),
          trailing: widget.selectMode
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(t.id),
                ),
          onTap: widget.selectMode
              ? () => Navigator.pop(context, t)
              : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(builder: (_) => _TemplateDetailScreen(templateId: t.id)),
                  ).then((_) => _load()),
        );
      },
    );
  }
}

Future<String?> _askName(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New template'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

// ── Template detail (view / add sets) ─────────────────────────────────────────

class _TemplateDetailScreen extends StatefulWidget {
  final int templateId;
  const _TemplateDetailScreen({required this.templateId});

  @override
  State<_TemplateDetailScreen> createState() => _TemplateDetailScreenState();
}

class _TemplateDetailScreenState extends State<_TemplateDetailScreen> {
  TemplateDetail? _template;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await api.getTemplate(widget.templateId);
      if (mounted) setState(() { _template = t; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _weightStr(double kg) => kg % 1 == 0 ? '${kg.toInt()} kg' : '$kg kg';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_template?.name ?? 'Template')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return Center(child: Text('Error: $_error'));
    if (_template == null) return const Center(child: CircularProgressIndicator());
    final sets = _template!.sets;
    if (sets.isEmpty) {
      return const Center(child: Text('No sets in this template.\nApply the template to a workout and sets will be added.'));
    }

    // Group by exercise
    final Map<int, List<TemplateSet>> byExercise = {};
    final List<int> order = [];
    for (final s in sets) {
      if (!byExercise.containsKey(s.exerciseId)) {
        byExercise[s.exerciseId] = [];
        order.add(s.exerciseId);
      }
      byExercise[s.exerciseId]!.add(s);
    }

    return ListView.builder(
      itemCount: order.length,
      itemBuilder: (ctx, i) {
        final exSets = byExercise[order[i]]!;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(exSets.first.exerciseName,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              ...exSets.map(
                (s) => ListTile(
                  dense: true,
                  title: Text(
                    'Set ${s.setNumber}   ${_weightStr(s.targetWeightKg)} × ${s.targetReps} reps',
                  ),
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
