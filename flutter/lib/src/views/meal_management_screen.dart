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
              .where((m) =>
                  m.name.toLowerCase().contains(query.trim().toLowerCase()))
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

  Future<void> _showEditDialog(MealSummary meal) async {
    try {
      final detail = await api.getMeal(meal.id);
      if (!mounted) return;

      final nameController = TextEditingController(text: detail.name);
      String? error;
      bool deleting = false;
      bool saving = false;

      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: const Text('Edit meal'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Meal name'),
                    ),
                    const SizedBox(height: 12),
                    const Text('Ingredients:', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    for (final ing in detail.ingredients)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(ing.foodName),
                        subtitle: Text('${ing.grams}g'),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: deleting || saving
                        ? null
                        : () async {
                            try {
                              setLocalState(() {
                                deleting = true;
                                error = null;
                              });
                              await api.deleteMeal(detail.id);
                              if (ctx.mounted) Navigator.of(ctx).pop(true);
                              await _loadMeals(query: _searchController.text);
                            } catch (e) {
                              setLocalState(() => error = e.toString());
                            } finally {
                              setLocalState(() => deleting = false);
                            }
                          },
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: deleting || saving
                        ? null
                        : () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: deleting || saving
                        ? null
                        : () async {
                            final name = nameController.text.trim();
                            if (name.isEmpty) {
                              setLocalState(
                                () => error = 'Enter a meal name',
                              );
                              return;
                            }

                            try {
                              setLocalState(() {
                                saving = true;
                                error = null;
                              });
                              await api.updateMeal(
                                detail.id,
                                name: name,
                                ingredients: detail.ingredients
                                    .map((ing) => {
                                          'food_id': ing.foodId,
                                          'grams': ing.grams,
                                        })
                                    .toList(),
                              );
                              if (ctx.mounted) Navigator.of(ctx).pop(true);
                            } catch (e) {
                              setLocalState(() => error = e.toString());
                            } finally {
                              setLocalState(() => saving = false);
                            }
                          },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      if (saved == true) {
        await _loadMeals(query: _searchController.text);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Meals')),
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
                        onTap: () => _showEditDialog(meal),
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
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
