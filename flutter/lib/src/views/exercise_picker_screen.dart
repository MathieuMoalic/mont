import 'package:flutter/material.dart';
import 'dart:convert';

import '../api.dart' as api;
import '../models.dart';
import '../platform/kv_store.dart' as kv;
import '../theme.dart';

class ExercisePickerScreen extends StatefulWidget {
  const ExercisePickerScreen({super.key});

  @override
  State<ExercisePickerScreen> createState() => _ExercisePickerScreenState();
}

class _ExercisePickerScreenState extends State<ExercisePickerScreen> {
  static const _kMuscleGroupsKey = 'exercise_muscle_groups';
  static const _kEquipmentKey = 'exercise_equipment';
  static const List<String> _defaultMuscleGroups = [
    'Chest',
    'Back',
    'Shoulders',
    'Biceps',
    'Triceps',
    'Core',
    'Quads',
    'Hamstrings',
    'Glutes',
    'Calves',
    'Full Body',
    'Cardio',
  ];
  static const List<String> _defaultEquipment = [
    'Barbell',
    'Dumbbell',
    'Machine',
    'Cable',
    'Smith',
    'Bodyweight',
    'Kettlebell',
    'Band',
  ];
  static const List<Color> _colorPalette = [
    Color(0xFF4A3548),
    Color(0xFF354850),
    Color(0xFF4A4535),
    Color(0xFF3A4838),
    Color(0xFF453550),
    Color(0xFF503540),
    Color(0xFF354055),
    Color(0xFF484838),
    Color(0xFF4D3545),
    Color(0xFF354845),
    Color(0xFF3D3D50),
    Color(0xFF504038),
    Color(0xFF2F4B7C),
    Color(0xFF6A4C93),
    Color(0xFF8E5A3C),
    Color(0xFF3B6E57),
    Color(0xFF7A3E65),
    Color(0xFF3B3F73),
  ];

  List<Exercise>? _all;
  List<Exercise> _filtered = [];
  final _searchCtrl = TextEditingController();
  String? _error;
  String? _muscleFilter;
  String? _equipmentFilter;
  List<String> _muscleOptions = List.of(_defaultMuscleGroups);
  List<String> _equipmentOptions = List.of(_defaultEquipment);
  Map<String, Color> _muscleColors = {};

  @override
  void initState() {
    super.initState();
    _loadCategoryOptions();
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
    final used = _all == null
        ? <String>[]
        : _all!
              .map((e) => e.muscleGroup)
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList();
    return {..._muscleOptions, ...used}.toList()..sort();
  }

  List<String> _distinctEquipment() {
    final used = _all == null
        ? <String>[]
        : _all!
              .map((e) => e.equipment)
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList();
    return {..._equipmentOptions, ...used}.toList()..sort();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
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
    final muscleGroups = _distinctMuscleGroups();
    final equipment = _distinctEquipment();
    return showDialog<(String, String?, String?)>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
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
                      decoration: const InputDecoration(
                        labelText: 'Muscle group',
                      ),
                      items: muscleGroups
                          .map(
                            (g) => DropdownMenuItem(value: g, child: Text(g)),
                          )
                          .toList(),
                      onChanged: (v) => setSt(() => selectedMuscleGroup = v),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedEquipment,
                      hint: const Text('Equipment (optional)'),
                      decoration: const InputDecoration(labelText: 'Equipment'),
                      items: equipment
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (v) => setSt(() => selectedEquipment = v),
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
                  onPressed: () => Navigator.pop(ctx, (
                    ctrl.text.trim(),
                    selectedMuscleGroup,
                    selectedEquipment,
                  )),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() => ctrl.dispose());
  }

  Future<void> _loadCategoryOptions() async {
    final rawMuscles = await kv.getString(_kMuscleGroupsKey);
    final rawEquipment = await kv.getString(_kEquipmentKey);
    if (!mounted) return;
    setState(() {
      _muscleOptions = _decodeCategoryList(rawMuscles, _defaultMuscleGroups);
      _equipmentOptions = _decodeCategoryList(rawEquipment, _defaultEquipment);
      _muscleColors = Map<String, Color>.from(MontColors.muscleColorOverrides);
    });
    MontColors.applyMuscleColorOverrides(_muscleColors);
    try {
      final remote = await api.getExerciseCategories();
      final remoteMuscles =
          remote.muscleGroups
              .map((e) => e.name.trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final remoteEquipment =
          remote.equipment
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final remoteColors = <String, Color>{};
      for (final mg in remote.muscleGroups) {
        final hex = mg.colorHex;
        if (hex == null) continue;
        final parsed = MontColors.colorFromHex(hex);
        if (parsed != null) {
          remoteColors[mg.name] = parsed;
        }
      }
      if (!mounted) return;
      setState(() {
        _muscleOptions = remoteMuscles;
        _equipmentOptions = remoteEquipment;
        _muscleColors = remoteColors;
      });
      MontColors.applyMuscleColorOverrides(_muscleColors);
      await kv.setString(_kMuscleGroupsKey, jsonEncode(_muscleOptions));
      await kv.setString(_kEquipmentKey, jsonEncode(_equipmentOptions));
      await MontColors.saveCustomMuscleColors(_muscleColors);
    } catch (_) {
      // Fall back to local cache/defaults when backend categories are not available.
    }
  }

  List<String> _decodeCategoryList(String? raw, List<String> fallback) {
    if (raw == null || raw.trim().isEmpty) return List.of(fallback);
    try {
      final parsed = jsonDecode(raw) as List<dynamic>;
      final cleaned =
          parsed
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return cleaned.isEmpty ? List.of(fallback) : cleaned;
    } catch (_) {
      return List.of(fallback);
    }
  }

  Future<void> _saveCategoryOptions() async {
    final payload = ExerciseCategories(
      muscleGroups: _muscleOptions
          .map(
            (name) => MuscleGroupCategory(
              name: name,
              colorHex: _muscleColors[name] != null
                  ? MontColors.colorToHex(_muscleColors[name]!)
                  : null,
            ),
          )
          .toList(),
      equipment: _equipmentOptions,
    );
    await api.updateExerciseCategories(payload);
    await kv.setString(_kMuscleGroupsKey, jsonEncode(_muscleOptions));
    await kv.setString(_kEquipmentKey, jsonEncode(_equipmentOptions));
    await MontColors.saveCustomMuscleColors(_muscleColors);
  }

  Future<Color?> _pickMuscleColor(Color current) {
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick color'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _colorPalette
              .map(
                (c) => InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c.toARGB32() == current.toARGB32()
                            ? Colors.white
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askCategoryValue({
    required String title,
    String initialValue = '',
  }) async {
    final ctrl = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Value'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result?.trim().isEmpty == true ? null : result?.trim();
  }

  Future<void> _manageCategories() async {
    final newValue =
        await showDialog<(List<String>, List<String>, Map<String, Color>)>(
          context: context,
          builder: (ctx) {
            final muscleDraft = List<String>.of(_muscleOptions);
            final equipmentDraft = List<String>.of(_equipmentOptions);
            final muscleColorDraft = Map<String, Color>.from(_muscleColors);
            return StatefulBuilder(
              builder: (ctx, setSt) => AlertDialog(
                title: const Text('Manage categories'),
                content: SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _categorySection(
                          context: ctx,
                          title: 'Muscle groups',
                          values: muscleDraft,
                          onAdd: () async {
                            final v = await _askCategoryValue(
                              title: 'Add muscle group',
                            );
                            if (v == null || muscleDraft.contains(v)) return;
                            setSt(() {
                              muscleDraft.add(v);
                              muscleDraft.sort();
                            });
                          },
                          onEdit: (value) async {
                            final v = await _askCategoryValue(
                              title: 'Edit muscle group',
                              initialValue: value,
                            );
                            if (v == null ||
                                (v != value && muscleDraft.contains(v))) {
                              return;
                            }
                            setSt(() {
                              final idx = muscleDraft.indexOf(value);
                              if (idx >= 0) {
                                muscleDraft[idx] = v;
                              }
                              final oldColor = muscleColorDraft.remove(value);
                              if (oldColor != null) {
                                muscleColorDraft[v] = oldColor;
                              }
                              muscleDraft.sort();
                            });
                          },
                          onDelete: (value) {
                            setSt(() {
                              muscleDraft.remove(value);
                              muscleColorDraft.remove(value);
                            });
                          },
                          colorForValue: (value) =>
                              muscleColorDraft[value] ??
                              MontColors.getMuscleColor(value),
                          onColorPick: (value) async {
                            final picked = await _pickMuscleColor(
                              muscleColorDraft[value] ??
                                  MontColors.getMuscleColor(value),
                            );
                            if (picked == null) return;
                            setSt(() => muscleColorDraft[value] = picked);
                          },
                        ),
                        const SizedBox(height: 14),
                        _categorySection(
                          context: ctx,
                          title: 'Equipment',
                          values: equipmentDraft,
                          onAdd: () async {
                            final v = await _askCategoryValue(
                              title: 'Add equipment',
                            );
                            if (v == null || equipmentDraft.contains(v)) return;
                            setSt(() {
                              equipmentDraft.add(v);
                              equipmentDraft.sort();
                            });
                          },
                          onEdit: (value) async {
                            final v = await _askCategoryValue(
                              title: 'Edit equipment',
                              initialValue: value,
                            );
                            if (v == null ||
                                (v != value && equipmentDraft.contains(v))) {
                              return;
                            }
                            setSt(() {
                              final idx = equipmentDraft.indexOf(value);
                              if (idx >= 0) equipmentDraft[idx] = v;
                              equipmentDraft.sort();
                            });
                          },
                          onDelete: (value) {
                            setSt(() => equipmentDraft.remove(value));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, (
                      muscleDraft,
                      equipmentDraft,
                      muscleColorDraft,
                    )),
                    child: const Text('Save'),
                  ),
                ],
              ),
            );
          },
        );

    if (newValue == null || !mounted) return;
    final previousMuscles = List<String>.of(_muscleOptions);
    final previousEquipment = List<String>.of(_equipmentOptions);
    final previousColors = Map<String, Color>.from(_muscleColors);
    setState(() {
      _muscleOptions = newValue.$1;
      _equipmentOptions = newValue.$2;
      _muscleColors = newValue.$3;
    });
    MontColors.applyMuscleColorOverrides(_muscleColors);
    try {
      await _saveCategoryOptions();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _muscleOptions = previousMuscles;
        _equipmentOptions = previousEquipment;
        _muscleColors = previousColors;
      });
      MontColors.applyMuscleColorOverrides(_muscleColors);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save categories: $e')));
      return;
    }
    _filter();
  }

  Widget _categorySection({
    required BuildContext context,
    required String title,
    required List<String> values,
    required VoidCallback onAdd,
    required Future<void> Function(String value) onEdit,
    required void Function(String value) onDelete,
    Color Function(String value)? colorForValue,
    Future<void> Function(String value)? onColorPick,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              tooltip: 'Add',
            ),
          ],
        ),
        if (values.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('No values yet.'),
          )
        else
          ...values.map(
            (v) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: colorForValue != null
                  ? InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: onColorPick == null ? null : () => onColorPick(v),
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: colorForValue(v),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24),
                        ),
                      ),
                    )
                  : null,
              title: Text(v),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    onPressed: () => onEdit(v),
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    onPressed: () => onDelete(v),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                  ),
                ],
              ),
            ),
          ),
      ],
    );
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
            icon: const Icon(Icons.tune),
            tooltip: 'Manage categories',
            onPressed: _manageCategories,
          ),
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
    final hasFilters = muscleGroups.isNotEmpty || equipmentList.isNotEmpty;

    if (_filtered.isEmpty) {
      final q = _searchCtrl.text.trim();
      return Column(
        children: [
          if (hasFilters) _buildFilters(muscleGroups, equipmentList),
          Expanded(
            child: Center(
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
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (hasFilters) _buildFilters(muscleGroups, equipmentList),
        Expanded(
          child: ListView.builder(
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
          ),
        ),
      ],
    );
  }

  Widget _buildFilters(List<String> muscleGroups, List<String> equipmentList) {
    return Container(
      color: MontColors.background,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (muscleGroups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: const Text('All muscles'),
                    selected: _muscleFilter == null,
                    onSelected: (_) => setState(() {
                      _muscleFilter = null;
                      _filter();
                    }),
                  ),
                  ...muscleGroups.map(
                    (g) => FilterChip(
                      label: Text(g),
                      selected: _muscleFilter == g,
                      backgroundColor: MontColors.getMuscleColor(g),
                      selectedColor: MontColors.getMuscleAccent(g),
                      side: BorderSide(
                        color: MontColors.getMuscleAccent(g),
                        width: _muscleFilter == g ? 2 : 1,
                      ),
                      onSelected: (_) => setState(() {
                        _muscleFilter = g;
                        _filter();
                      }),
                    ),
                  ),
                ],
              ),
            ),
          if (equipmentList.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: const Text('All equipment'),
                    selected: _equipmentFilter == null,
                    onSelected: (_) => setState(() {
                      _equipmentFilter = null;
                      _filter();
                    }),
                  ),
                  ...equipmentList.map(
                    (e) => FilterChip(
                      label: Text(e),
                      selected: _equipmentFilter == e,
                      onSelected: (_) => setState(() {
                        _equipmentFilter = e;
                        _filter();
                      }),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
