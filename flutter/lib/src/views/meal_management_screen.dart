import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

class MealManagementScreen extends StatefulWidget {
  const MealManagementScreen({super.key});

  @override
  State<MealManagementScreen> createState() => _MealManagementScreenState();
}

class _MealManagementScreenState extends State<MealManagementScreen> {
  static const _proteinColor = Color(0xFF2E7D32);
  static const _carbsColor = Color(0xFF1565C0);
  static const _fatsColor = Color(0xFFF57C00);

  final _searchController = TextEditingController();
  List<MealSummary> meals = [];
  bool isLoading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadMeals();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _fmt(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.001) return rounded.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  Future<void> _loadMeals({String? query}) async {
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      final result = await api.listMeals(limit: 500, offset: 0);
      final filtered = query == null || query.trim().isEmpty
          ? result
          : result
                .where(
                  (m) =>
                      m.name.toLowerCase().contains(query.trim().toLowerCase()),
                )
                .toList();
      setState(() {
        meals = filtered;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        isLoading = false;
      });
    }
  }

  Future<void> _openMealEditor({int? mealId}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _MealEditorScreen(mealId: mealId)),
    );
    if (changed == true && mounted) {
      await _loadMeals(query: _searchController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Meals')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openMealEditor(),
        icon: const Icon(Icons.add),
        label: const Text('New meal'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search meals',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (value) {
                _loadMeals(query: value);
              },
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : meals.isEmpty
                ? const Center(child: Text('No meals found'))
                : ListView.builder(
                    itemCount: meals.length,
                    itemBuilder: (context, index) {
                      final meal = meals[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        onTap: () => _openMealEditor(mealId: meal.id),
                        title: Text(
                          meal.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: RichText(
                          text: TextSpan(
                            style: Theme.of(context).textTheme.bodySmall,
                            children: [
                              TextSpan(text: '${_fmt(meal.totalGrams)}g · '),
                              TextSpan(
                                text: 'P ${_fmt(meal.proteinG)}',
                                style: const TextStyle(
                                  color: _proteinColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: ' C ${_fmt(meal.carbsG)}',
                                style: const TextStyle(
                                  color: _carbsColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: ' F ${_fmt(meal.fatsG)}',
                                style: const TextStyle(
                                  color: _fatsColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.edit_outlined),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MealEditorScreen extends StatefulWidget {
  const _MealEditorScreen({this.mealId});

  final int? mealId;

  @override
  State<_MealEditorScreen> createState() => _MealEditorScreenState();
}

class _MealEditorScreenState extends State<_MealEditorScreen> {
  static const _proteinColor = Color(0xFF2E7D32);
  static const _carbsColor = Color(0xFF1565C0);
  static const _fatsColor = Color(0xFFF57C00);

  final _nameController = TextEditingController();
  final List<_EditableIngredient> _ingredients = [];

  bool _loading = false;
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  bool get _isEditing => widget.mealId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _fmt(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.001) return rounded.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  int _kcalPer100(Food food) =>
      (food.proteinPer100G * 4 + food.carbsPer100G * 4 + food.fatsPer100G * 9)
          .round();

  Future<void> _load() async {
    if (!_isEditing) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await api.getMeal(widget.mealId!);
      if (!mounted) return;
      _nameController.text = detail.name;
      _ingredients
        ..clear()
        ..addAll(
          detail.ingredients.map(
            (ing) => _EditableIngredient(
              food: Food(
                id: ing.foodId,
                name: ing.foodName,
                brand: ing.foodBrand,
                proteinPer100G: ing.proteinPer100G,
                carbsPer100G: ing.carbsPer100G,
                fatsPer100G: ing.fatsPer100G,
                lastWeightG: ing.grams,
                source: 'meal',
              ),
              grams: ing.grams,
            ),
          ),
        );
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<_FoodModalResult?> _showTrackerFoodModal({
    _EditableIngredient? existing,
    bool allowRemove = false,
  }) async {
    final nameController = TextEditingController(text: existing?.food.name ?? '');
    final proteinController = TextEditingController(
      text: existing == null
          ? ''
          : existing.food.proteinPer100G.toStringAsFixed(1),
    );
    final carbsController = TextEditingController(
      text: existing == null ? '' : existing.food.carbsPer100G.toStringAsFixed(1),
    );
    final fatsController = TextEditingController(
      text: existing == null ? '' : existing.food.fatsPer100G.toStringAsFixed(1),
    );
    final weightController = TextEditingController(
      text: existing == null ? '' : _fmt(existing.grams),
    );

    var query = existing?.food.name ?? '';
    List<Food> matches = const [];
    String? error;
    var searchSeq = 0;

    final result = await showDialog<_FoodModalResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) {
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            title: null,
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) {
                    query = v;
                    final q = v.trim();
                    if (q.length < 2) {
                      setLocalState(() => matches = const []);
                      return;
                    }
                    final mySeq = ++searchSeq;
                    api
                        .listFoods(query: q)
                        .then((results) {
                          if (!ctx.mounted || mySeq != searchSeq) return;
                          setLocalState(() => matches = results.take(4).toList());
                        })
                        .catchError((_) {});
                  },
                ),
                if (query.isNotEmpty && matches.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6, bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < matches.length; i++) ...[
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              final saved = matches[i];
                              setLocalState(() {
                                nameController.text = saved.name;
                                query = saved.name;
                                proteinController.text = _fmt(saved.proteinPer100G);
                                carbsController.text = _fmt(saved.carbsPer100G);
                                fatsController.text = _fmt(saved.fatsPer100G);
                                weightController.text = _fmt(saved.lastWeightG);
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      matches[i].name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('${_fmt(matches[i].lastWeightG)}g'),
                                ],
                              ),
                            ),
                          ),
                          if (i != matches.length - 1)
                            Divider(
                              height: 1,
                              color: Theme.of(context).colorScheme.outlineVariant,
                            ),
                        ],
                      ],
                    ),
                  ),
                TextField(
                  controller: proteinController,
                  decoration: const InputDecoration(
                    labelText: 'Protein per 100g (g)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                TextField(
                  controller: carbsController,
                  decoration: const InputDecoration(
                    labelText: 'Carbs per 100g (g)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                TextField(
                  controller: fatsController,
                  decoration: const InputDecoration(labelText: 'Fats per 100g (g)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                TextField(
                  controller: weightController,
                  decoration: const InputDecoration(labelText: 'Total weight (g)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            ),
            actions: [
              if (allowRemove)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(
                    const _FoodModalResult(remove: true),
                  ),
                  child: const Text(
                    'Remove ingredient',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  final protein = double.tryParse(proteinController.text.trim());
                  final carbs = double.tryParse(carbsController.text.trim());
                  final fats = double.tryParse(fatsController.text.trim());
                  final weight = double.tryParse(weightController.text.trim());
                  if (name.isEmpty ||
                      protein == null ||
                      carbs == null ||
                      fats == null ||
                      weight == null ||
                      protein < 0 ||
                      carbs < 0 ||
                      fats < 0 ||
                      weight <= 0) {
                    setLocalState(() => error = 'Enter valid values.');
                    return;
                  }
                  try {
                    final food = await api.upsertFoodManual(
                      name: name,
                      brand: existing?.food.brand ?? '',
                      proteinPer100G: protein,
                      carbsPer100G: carbs,
                      fatsPer100G: fats,
                      lastWeightG: weight,
                      source: existing?.food.source ?? 'manual',
                    );
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop(
                        _FoodModalResult(
                          ingredient: _EditableIngredient(food: food, grams: weight),
                        ),
                      );
                    }
                  } catch (e) {
                    setLocalState(() => error = e.toString());
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      proteinController.dispose();
      carbsController.dispose();
      fatsController.dispose();
      weightController.dispose();
    });
    return result;
  }

  Future<void> _addIngredient() async {
    final result = await _showTrackerFoodModal();
    if (result == null || result.remove || result.ingredient == null || !mounted) {
      return;
    }
    setState(() => _ingredients.add(result.ingredient!));
  }

  Future<void> _editIngredient(int index) async {
    final result = await _showTrackerFoodModal(
      existing: _ingredients[index],
      allowRemove: true,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.remove) {
        _ingredients.removeAt(index);
      } else if (result.ingredient != null) {
        _ingredients[index] = result.ingredient!;
      }
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _ingredients.isEmpty) {
      setState(() {
        _error = 'Name and at least 1 ingredient are required.';
      });
      return;
    }

    final payload = _ingredients
        .map((ing) => {'food_id': ing.food.id, 'grams': ing.grams})
        .toList();

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEditing) {
        await api.updateMeal(widget.mealId!, name: name, ingredients: payload);
      } else {
        await api.createMeal(name: name, ingredients: payload);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final message = e.toString();
      setState(() {
        _error = message.contains('HTTP 409')
            ? 'A meal with this name already exists.'
            : message;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (!_isEditing) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await api.deleteMeal(widget.mealId!);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  double get _proteinTotal => _ingredients.fold(
    0,
    (sum, ing) => sum + (ing.food.proteinPer100G * ing.grams / 100),
  );

  double get _carbsTotal => _ingredients.fold(
    0,
    (sum, ing) => sum + (ing.food.carbsPer100G * ing.grams / 100),
  );

  double get _fatsTotal =>
      _ingredients.fold(0, (sum, ing) => sum + (ing.food.fatsPer100G * ing.grams / 100));

  int get _kcalTotal =>
      (_proteinTotal * 4 + _carbsTotal * 4 + _fatsTotal * 9).round();

  double get _gramsTotal =>
      _ingredients.fold(0, (sum, ing) => sum + ing.grams);

  Widget _buildHeaderCell(
    String label, {
    int flex = 1,
    Color? color,
    bool showDivider = true,
    TextAlign textAlign = TextAlign.left,
  }) {
    final horizontalPadding = flex <= 1 ? 2.0 : (flex == 2 ? 4.0 : 10.0);
    return Expanded(
      flex: flex,
      child: Container(
        alignment: textAlign == TextAlign.center
            ? Alignment.center
            : Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 2),
        decoration: BoxDecoration(
          border: showDivider
              ? Border(
                  right: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.28),
                  ),
                )
              : null,
        ),
        child: Text(
          label,
          textAlign: textAlign,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildValueCell(
    String value, {
    int flex = 1,
    Color? color,
    bool showDivider = true,
    TextAlign textAlign = TextAlign.left,
  }) {
    final horizontalPadding = flex <= 1 ? 2.0 : (flex == 2 ? 4.0 : 10.0);
    return Expanded(
      flex: flex,
      child: Container(
        alignment: textAlign == TextAlign.center
            ? Alignment.center
            : Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 2),
        decoration: BoxDecoration(
          border: showDivider
              ? Border(
                  right: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.22),
                  ),
                )
              : null,
        ),
        child: Text(
          value,
          textAlign: textAlign,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _saving || _deleting;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit meal' : 'Create meal'),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: 'Delete meal',
              onPressed: busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton.icon(
            onPressed: busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Meal name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: busy ? null : _addIngredient,
                        icon: const Icon(Icons.add),
                        label: const Text('Add ingredient'),
                      ),
                      const Spacer(),
                      Text(
                        '${_ingredients.length} ingredient${_ingredients.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              _buildHeaderCell('Name', flex: 5),
                              _buildHeaderCell(
                                'P',
                                flex: 1,
                                color: _proteinColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildHeaderCell(
                                'C',
                                flex: 1,
                                color: _carbsColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildHeaderCell(
                                'F',
                                flex: 1,
                                color: _fatsColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildHeaderCell(
                                'Kcal',
                                flex: 2,
                                color: Theme.of(context).colorScheme.primary,
                                textAlign: TextAlign.center,
                              ),
                              _buildHeaderCell(
                                'g',
                                flex: 2,
                                textAlign: TextAlign.center,
                              ),
                              _buildHeaderCell(
                                '',
                                flex: 1,
                                showDivider: false,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _ingredients.isEmpty
                              ? const Center(child: Text('No ingredients yet'))
                              : ListView.separated(
                                  itemCount: _ingredients.length,
                                  separatorBuilder: (_, __) => Divider(
                                    height: 1,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: 0.35),
                                  ),
                                  itemBuilder: (context, index) {
                                    final ing = _ingredients[index];
                                    return Container(
                                      color: index.isEven
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.surface.withValues(alpha: 0.3)
                                          : null,
                                      padding: const EdgeInsets.symmetric(vertical: 6),
                                      child: Row(
                                        children: [
                                          _buildValueCell(ing.food.name, flex: 5),
                                          _buildValueCell(
                                            _fmt(ing.food.proteinPer100G),
                                            flex: 1,
                                            color: _proteinColor,
                                            textAlign: TextAlign.center,
                                          ),
                                          _buildValueCell(
                                            _fmt(ing.food.carbsPer100G),
                                            flex: 1,
                                            color: _carbsColor,
                                            textAlign: TextAlign.center,
                                          ),
                                          _buildValueCell(
                                            _fmt(ing.food.fatsPer100G),
                                            flex: 1,
                                            color: _fatsColor,
                                            textAlign: TextAlign.center,
                                          ),
                                          _buildValueCell(
                                            '${_kcalPer100(ing.food)}',
                                            flex: 2,
                                            color: Theme.of(context).colorScheme.primary,
                                            textAlign: TextAlign.center,
                                          ),
                                          _buildValueCell(
                                            _fmt(ing.grams),
                                            flex: 2,
                                            textAlign: TextAlign.center,
                                          ),
                                          Expanded(
                                            flex: 1,
                                            child: Align(
                                              alignment: Alignment.center,
                                              child: IconButton(
                                                tooltip: 'Edit ingredient',
                                                onPressed: busy
                                                    ? null
                                                    : () => _editIngredient(index),
                                                icon: const Icon(Icons.edit_outlined),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              _buildValueCell(
                                'Total',
                                flex: 5,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              _buildValueCell(
                                _fmt(_proteinTotal),
                                flex: 1,
                                color: _proteinColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildValueCell(
                                _fmt(_carbsTotal),
                                flex: 1,
                                color: _carbsColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildValueCell(
                                _fmt(_fatsTotal),
                                flex: 1,
                                color: _fatsColor,
                                textAlign: TextAlign.center,
                              ),
                              _buildValueCell(
                                '$_kcalTotal',
                                flex: 2,
                                color: Theme.of(context).colorScheme.primary,
                                textAlign: TextAlign.center,
                              ),
                              _buildValueCell(
                                _fmt(_gramsTotal),
                                flex: 2,
                                textAlign: TextAlign.center,
                              ),
                              _buildValueCell(
                                '',
                                flex: 1,
                                showDivider: false,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _EditableIngredient {
  _EditableIngredient({required this.food, required this.grams});

  final Food food;
  final double grams;
}

class _FoodModalResult {
  const _FoodModalResult({this.ingredient, this.remove = false});

  final _EditableIngredient? ingredient;
  final bool remove;
}
