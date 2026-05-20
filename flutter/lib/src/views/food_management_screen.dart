import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';

class FoodManagementScreen extends StatefulWidget {
  const FoodManagementScreen({super.key});

  @override
  State<FoodManagementScreen> createState() => _FoodManagementScreenState();
}

class _FoodManagementScreenState extends State<FoodManagementScreen> {
  final _searchController = TextEditingController();
  List<Food> foods = [];
  bool isLoading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadFoods();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFoods({String? query}) async {
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      final result = await api.listFoods(query: query);
      setState(() {
        foods = result;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        isLoading = false;
      });
    }
  }

  Future<void> _showEditDialog(Food food) async {
    final nameController = TextEditingController(text: food.name);
    final brandController = TextEditingController(text: food.brand);
    final proteinController = TextEditingController(
      text: food.proteinPer100G.toStringAsFixed(1),
    );
    final carbsController = TextEditingController(
      text: food.carbsPer100G.toStringAsFixed(1),
    );
    final fatsController = TextEditingController(
      text: food.fatsPer100G.toStringAsFixed(1),
    );
    final sourceController = TextEditingController(text: food.source);

    String? error;
    bool deleting = false;
    bool saving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Edit food'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    controller: brandController,
                    decoration: const InputDecoration(labelText: 'Brand'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: proteinController,
                          decoration: const InputDecoration(
                            labelText: 'Protein (g/100g)',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: carbsController,
                          decoration: const InputDecoration(
                            labelText: 'Carbs (g/100g)',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: fatsController,
                    decoration: const InputDecoration(
                      labelText: 'Fats (g/100g)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                  TextField(
                    controller: sourceController,
                    decoration: const InputDecoration(labelText: 'Source'),
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
                            await api.deleteFood(food.id);
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                            await _loadFoods();
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
                          final protein = double.tryParse(
                            proteinController.text.trim(),
                          );
                          final carbs = double.tryParse(
                            carbsController.text.trim(),
                          );
                          final fats = double.tryParse(
                            fatsController.text.trim(),
                          );

                          if (name.isEmpty ||
                              protein == null ||
                              carbs == null ||
                              fats == null) {
                            setLocalState(
                              () => error = 'Enter valid values for all fields',
                            );
                            return;
                          }

                          try {
                            setLocalState(() {
                              saving = true;
                              error = null;
                            });
                            await api.updateFood(
                              food.id,
                              name: name,
                              brand: brandController.text.trim(),
                              proteinPer100G: protein,
                              carbsPer100G: carbs,
                              fatsPer100G: fats,
                              source: sourceController.text.trim(),
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
      await _loadFoods(query: _searchController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Foods')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search foods',
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
                if (value.isEmpty) {
                  _loadFoods();
                } else {
                  _loadFoods(query: value);
                }
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
                : foods.isEmpty
                ? const Center(child: Text('No foods found'))
                : ListView.builder(
                    itemCount: foods.length,
                    itemBuilder: (context, index) {
                      final food = foods[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        onTap: () => _showEditDialog(food),
                        title: Text(
                          food.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${food.brand} · P ${food.proteinPer100G}g C ${food.carbsPer100G}g F ${food.fatsPer100G}g · ${food.source}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
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
