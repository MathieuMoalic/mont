import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'barcode_scan_screen.dart';

class CaloriesScreen extends StatefulWidget {
  const CaloriesScreen({super.key});

  @override
  State<CaloriesScreen> createState() => _CaloriesScreenState();
}

class _CaloriesScreenState extends State<CaloriesScreen> {
  static const _mealOrder = ['morning', 'afternoon', 'evening'];
  static const _proteinColor = Color(0xFF2E7D32);
  static const _carbsColor = Color(0xFF1565C0);
  static const _fatsColor = Color(0xFFF57C00);

  List<CalorieEntry>? _entries;
  List<CalorieExerciseEntry>? _exercises;
  NutritionTargets? _targets;
  String? _error;
  DateTime _visibleMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  DateTime _selectedDay = _dayKey(DateTime.now());
  bool _showCalendar = false;

  String _selectedDayLabel() {
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${_selectedDay.day} ${monthNames[_selectedDay.month - 1]} ${_selectedDay.year}';
  }

  @override
  void initState() {
    super.initState();
    _loadMonth();
  }

  static DateTime _dayKey(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static String _dayString(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime _dayFromString(String day) {
    final parts = day.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  ({DateTime start, DateTime end}) _visibleGridRange() {
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final leadingBlanks = firstOfMonth.weekday - 1;
    final cellCount = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;
    final start = firstOfMonth.subtract(Duration(days: leadingBlanks));
    final end = start.add(Duration(days: cellCount - 1));
    return (start: start, end: end);
  }

  Future<void> _loadMonth() async {
    final range = _visibleGridRange();
    try {
      final results = await Future.wait<dynamic>([
        api.listCalorieEntries(
          startDay: _dayString(range.start),
          endDay: _dayString(range.end),
        ),
        api.listCalorieExercises(
          startDay: _dayString(range.start),
          endDay: _dayString(range.end),
        ),
        api.getNutritionTargets(),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = results[0] as List<CalorieEntry>;
        _exercises = results[1] as List<CalorieExerciseEntry>;
        _targets = results[2] as NutritionTargets;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Map<DateTime, List<CalorieEntry>> _entriesByDay() {
    final byDay = <DateTime, List<CalorieEntry>>{};
    for (final entry in _entries ?? const <CalorieEntry>[]) {
      final day = _dayFromString(entry.day);
      (byDay[day] ??= []).add(entry);
    }
    for (final items in byDay.values) {
      items.sort((a, b) {
        final mealComp = _mealOrder
            .indexOf(a.mealPeriod)
            .compareTo(_mealOrder.indexOf(b.mealPeriod));
        if (mealComp != 0) return mealComp;
        return a.id.compareTo(b.id);
      });
    }
    return byDay;
  }

  Map<DateTime, List<CalorieExerciseEntry>> _exerciseByDay() {
    final byDay = <DateTime, List<CalorieExerciseEntry>>{};
    for (final entry in _exercises ?? const <CalorieExerciseEntry>[]) {
      final day = _dayFromString(entry.day);
      (byDay[day] ??= []).add(entry);
    }
    return byDay;
  }

  String _monthLabel(DateTime d) {
    const monthNames = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${monthNames[d.month - 1]} ${d.year}';
  }

  String _mealLabel(String meal) =>
      meal[0].toUpperCase() + meal.substring(1).toLowerCase();

  String _fmt(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.001) return rounded.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  int _kcalFromMacros(double proteinG, double carbsG, double fatsG) =>
      (proteinG * 4 + carbsG * 4 + fatsG * 9).round();

  Future<void> _changeMonth(int delta) async {
    setState(() {
      _visibleMonth = DateTime(
        _visibleMonth.year,
        _visibleMonth.month + delta,
        1,
      );
    });
    await _loadMonth();
  }

  Future<void> _jumpToToday() async {
    setState(() {
      final today = _dayKey(DateTime.now());
      _visibleMonth = DateTime(today.year, today.month, 1);
      _selectedDay = today;
    });
    await _loadMonth();
  }

  Future<void> _showFoodDialog({
    required String meal,
    CalorieEntry? existing,
  }) async {
    final savedFoods = existing == null ? await api.listFoods() : <Food>[];
    if (!mounted) return;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final barcodeController = TextEditingController();
    final proteinPer100Controller = TextEditingController(
      text: existing != null ? _fmt(existing.proteinPer100G) : '',
    );
    final carbsPer100Controller = TextEditingController(
      text: existing != null ? _fmt(existing.carbsPer100G) : '',
    );
    final fatsPer100Controller = TextEditingController(
      text: existing != null ? _fmt(existing.fatsPer100G) : '',
    );
    final weightController = TextEditingController(
      text: existing != null ? _fmt(existing.weightG) : '',
    );
    var selectedMeal = existing?.mealPeriod ?? meal;
    var foodQuery = '';
    String? error;
    bool lookupBusy = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: Text(existing == null ? 'Add item' : 'Edit item'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: selectedMeal,
                      decoration: const InputDecoration(labelText: 'Section'),
                      items: _mealOrder
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(_mealLabel(v)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setLocalState(() => selectedMeal = v);
                      },
                    ),
                    TextField(
                      controller: barcodeController,
                      decoration: InputDecoration(
                        labelText: 'Barcode (EAN)',
                        hintText: 'e.g. 5901234123457',
                        prefixIcon: const Icon(Icons.qr_code_2),
                        suffixIcon: IconButton(
                          tooltip: 'Lookup in Polish sources (Open Food Facts)',
                          onPressed:
                              lookupBusy
                                  ? null
                                  : () async {
                                    final b = barcodeController.text.trim();
                                    if (b.isEmpty) return;
                                    setLocalState(() {
                                      lookupBusy = true;
                                      error = null;
                                    });
                                    try {
                                      // 1) Try local cache first
                                      final cached = await api.getFoodByBarcode(
                                        b,
                                      );
                                      setLocalState(() {
                                        nameController.text = cached.name;
                                        foodQuery = cached.name;
                                        proteinPer100Controller.text = _fmt(
                                          cached.proteinPer100G,
                                        );
                                        carbsPer100Controller.text = _fmt(
                                          cached.carbsPer100G,
                                        );
                                        fatsPer100Controller.text = _fmt(
                                          cached.fatsPer100G,
                                        );
                                        weightController.text = _fmt(
                                          cached.lastWeightG,
                                        );
                                      });
                                    } catch (_) {
                                      try {
                                        // 2) Fallback to online lookup
                                        final lookedUp =
                                            await api.lookupFoodByBarcode(b);
                                        setLocalState(() {
                                          nameController.text = lookedUp.name;
                                          foodQuery = lookedUp.name;
                                          proteinPer100Controller.text = _fmt(
                                            lookedUp.proteinPer100G,
                                          );
                                          carbsPer100Controller.text = _fmt(
                                            lookedUp.carbsPer100G,
                                          );
                                          fatsPer100Controller.text = _fmt(
                                            lookedUp.fatsPer100G,
                                          );
                                        });
                                      } catch (e) {
                                        setLocalState(() => error = e.toString());
                                      }
                                    } finally {
                                      setLocalState(() => lookupBusy = false);
                                    }
                                  },
                          icon:
                              lookupBusy
                                  ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.search),
                        ),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final scanned = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                              builder: (_) => const BarcodeScanScreen(),
                            ),
                          );
                          if (scanned == null || scanned.trim().isEmpty) return;
                          setLocalState(() => barcodeController.text = scanned.trim());
                        },
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan barcode'),
                      ),
                    ),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => setLocalState(() => foodQuery = v),
                    ),
                    if (existing == null && foodQuery.trim().isNotEmpty)
                      Builder(
                        builder: (context) {
                          final q = foodQuery.trim().toLowerCase();
                          final matches = savedFoods
                              .where((f) => f.name.toLowerCase().contains(q))
                              .take(4)
                              .toList();
                          if (matches.isEmpty) {
                            return const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('No saved foods'),
                            );
                          }
                          return Container(
                            margin: const EdgeInsets.only(top: 6, bottom: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: [
                                for (
                                  int index = 0;
                                  index < matches.length;
                                  index++
                                ) ...[
                                  InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      final saved = matches[index];
                                      setLocalState(() {
                                        nameController.text = saved.name;
                                        foodQuery = saved.name;
                                        proteinPer100Controller.text = _fmt(
                                          saved.proteinPer100G,
                                        );
                                        carbsPer100Controller.text = _fmt(
                                          saved.carbsPer100G,
                                        );
                                        fatsPer100Controller.text = _fmt(
                                          saved.fatsPer100G,
                                        );
                                        weightController.text = _fmt(
                                          saved.lastWeightG,
                                        );
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 6,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              matches[index].name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${_fmt(matches[index].lastWeightG)}g',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (index != matches.length - 1)
                                    Divider(
                                      height: 1,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                    ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    TextField(
                      controller: proteinPer100Controller,
                      decoration:
                          const InputDecoration(
                            labelText: 'Protein per 100g (g)',
                          ).copyWith(
                            prefixIcon: const Icon(
                              Icons.circle,
                              color: _proteinColor,
                              size: 12,
                            ),
                            labelStyle: const TextStyle(color: _proteinColor),
                          ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: carbsPer100Controller,
                      decoration:
                          const InputDecoration(
                            labelText: 'Carbs per 100g (g)',
                          ).copyWith(
                            prefixIcon: const Icon(
                              Icons.circle,
                              color: _carbsColor,
                              size: 12,
                            ),
                            labelStyle: const TextStyle(color: _carbsColor),
                          ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: fatsPer100Controller,
                      decoration:
                          const InputDecoration(
                            labelText: 'Fats per 100g (g)',
                          ).copyWith(
                            prefixIcon: const Icon(
                              Icons.circle,
                              color: _fatsColor,
                              size: 12,
                            ),
                            labelStyle: const TextStyle(color: _fatsColor),
                          ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: weightController,
                      decoration: const InputDecoration(
                        labelText: 'Total weight (g)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
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
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      setLocalState(() => error = 'Enter a name.');
                      return;
                    }

                    final proteinText = proteinPer100Controller.text.trim();
                    final carbsText = carbsPer100Controller.text.trim();
                    final fatsText = fatsPer100Controller.text.trim();
                    final weightText = weightController.text.trim();

                    if (proteinText.isEmpty ||
                        carbsText.isEmpty ||
                        fatsText.isEmpty) {
                      setLocalState(
                        () => error = 'Enter protein/carbs/fats per 100g.',
                      );
                      return;
                    }
                    if (weightText.isEmpty) {
                      setLocalState(() => error = 'Enter total weight (g).');
                      return;
                    }

                    final proteinPer100 = double.tryParse(proteinText);
                    final carbsPer100 = double.tryParse(carbsText);
                    final fatsPer100 = double.tryParse(fatsText);
                    final weight = double.tryParse(weightText);
                    if (proteinPer100 == null ||
                        carbsPer100 == null ||
                        fatsPer100 == null ||
                        weight == null) {
                      setLocalState(() => error = 'Use numbers for macros/weight.');
                      return;
                    }
                    if (proteinPer100 < 0 || carbsPer100 < 0 || fatsPer100 < 0) {
                      setLocalState(() => error = 'Macros cannot be negative.');
                      return;
                    }
                    if (weight <= 0) {
                      setLocalState(() => error = 'Weight must be greater than 0g.');
                      return;
                    }

                    try {
                      if (existing == null) {
                        await api.createCalorieEntry(
                          day: _dayString(_selectedDay),
                          mealPeriod: selectedMeal,
                          name: name,
                          proteinPer100G: proteinPer100,
                          carbsPer100G: carbsPer100,
                          fatsPer100G: fatsPer100,
                          weightG: weight,
                        );
                      } else {
                        await api.updateCalorieEntry(
                          existing.id,
                          day: _dayString(_selectedDay),
                          mealPeriod: selectedMeal,
                          name: name,
                          proteinPer100G: proteinPer100,
                          carbsPer100G: carbsPer100,
                          fatsPer100G: fatsPer100,
                          weightG: weight,
                        );
                      }

                      final barcode = barcodeController.text.trim();
                      if (barcode.isNotEmpty) {
                        // Cache the lookup locally so future scans / manual entries are instant.
                        await api.upsertFoodByBarcode(
                          barcode: barcode,
                          name: name,
                          proteinPer100G: proteinPer100,
                          carbsPer100G: carbsPer100,
                          fatsPer100G: fatsPer100,
                          lastWeightG: weight,
                          source: 'user',
                        );
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    } catch (e) {
                      setLocalState(() => error = e.toString());
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      await _loadMonth();
    }
  }

  Future<void> _showExerciseDialog({CalorieExerciseEntry? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final kcalController = TextEditingController(
      text: existing?.kcal.toString() ?? '',
    );
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: Text(existing == null ? 'Add exercise' : 'Edit exercise'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Exercise'),
              ),
              TextField(
                controller: kcalController,
                decoration: const InputDecoration(labelText: 'kcal burned'),
                keyboardType: TextInputType.number,
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
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final kcal = int.tryParse(kcalController.text.trim());
                if (name.isEmpty || kcal == null || kcal < 0) {
                  setLocalState(
                    () => error = 'Provide a valid exercise and kcal.',
                  );
                  return;
                }
                try {
                  if (existing == null) {
                    await api.createCalorieExercise(
                      day: _dayString(_selectedDay),
                      name: name,
                      kcal: kcal,
                    );
                  } else {
                    await api.updateCalorieExercise(
                      existing.id,
                      day: _dayString(_selectedDay),
                      name: name,
                      kcal: kcal,
                    );
                  }
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } catch (e) {
                  setLocalState(() => error = e.toString());
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _loadMonth();
    }
  }

  Future<void> _showTargetsDialog() async {
    final targets =
        _targets ?? NutritionTargets(proteinG: 0, carbsG: 0, fatsG: 0);
    final proteinController = TextEditingController(
      text: _fmt(targets.proteinG),
    );
    final carbsController = TextEditingController(text: _fmt(targets.carbsG));
    final fatsController = TextEditingController(text: _fmt(targets.fatsG));
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Daily targets'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: proteinController,
                decoration: const InputDecoration(
                  labelText: 'Protein target (g)',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              TextField(
                controller: carbsController,
                decoration: const InputDecoration(
                  labelText: 'Carbs target (g)',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              TextField(
                controller: fatsController,
                decoration: const InputDecoration(labelText: 'Fats target (g)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final p = double.tryParse(proteinController.text.trim());
                final c = double.tryParse(carbsController.text.trim());
                final f = double.tryParse(fatsController.text.trim());
                if (p == null ||
                    c == null ||
                    f == null ||
                    p < 0 ||
                    c < 0 ||
                    f < 0) {
                  setLocalState(
                    () => error = 'Provide valid non-negative targets.',
                  );
                  return;
                }
                try {
                  await api.updateNutritionTargets(
                    NutritionTargets(proteinG: p, carbsG: c, fatsG: f),
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } catch (e) {
                  setLocalState(() => error = e.toString());
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _loadMonth();
    }
  }

  Future<void> _deleteFood(CalorieEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text(entry.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await api.deleteCalorieEntry(entry.id);
    await _loadMonth();
  }

  Future<void> _deleteExercise(CalorieExerciseEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete exercise?'),
        content: Text(entry.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await api.deleteCalorieExercise(entry.id);
    await _loadMonth();
  }

  @override
  Widget build(BuildContext context) {
    final byDay = _entriesByDay();
    final exerciseByDay = _exerciseByDay();
    final selectedEntries = byDay[_selectedDay] ?? const <CalorieEntry>[];
    final selectedExercises =
        exerciseByDay[_selectedDay] ?? const <CalorieExerciseEntry>[];
    final totalProtein = selectedEntries.fold<double>(
      0,
      (sum, e) => sum + e.proteinG,
    );
    final totalCarbs = selectedEntries.fold<double>(
      0,
      (sum, e) => sum + e.carbsG,
    );
    final totalFats = selectedEntries.fold<double>(
      0,
      (sum, e) => sum + e.fatsG,
    );
    final intakeKcal = selectedEntries.fold<int>(0, (sum, e) => sum + e.kcal);
    final exerciseKcal = selectedExercises.fold<int>(
      0,
      (sum, e) => sum + e.kcal,
    );
    final netKcal = intakeKcal - exerciseKcal;
    final targets =
        _targets ?? NutritionTargets(proteinG: 0, carbsG: 0, fatsG: 0);
    final targetKcal = _kcalFromMacros(
      targets.proteinG,
      targets.carbsG,
      targets.fatsG,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calories'),
        actions: [
          IconButton(
            onPressed: _showTargetsDialog,
            icon: const Icon(Icons.tune),
            tooltip: 'Daily targets',
          ),
        ],
      ),
      body: _buildBody(byDay, exerciseByDay),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _macroProgressRow(
                label: 'P',
                color: _proteinColor,
                current: totalProtein,
                target: targets.proteinG,
              ),
              const SizedBox(height: 6),
              _macroProgressRow(
                label: 'C',
                color: _carbsColor,
                current: totalCarbs,
                target: targets.carbsG,
              ),
              const SizedBox(height: 6),
              _macroProgressRow(
                label: 'F',
                color: _fatsColor,
                current: totalFats,
                target: targets.fatsG,
              ),
              const SizedBox(height: 8),
              _kcalProgressRow(netKcal: netKcal, targetKcal: targetKcal),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    Map<DateTime, List<CalorieEntry>> byDay,
    Map<DateTime, List<CalorieExerciseEntry>> exerciseByDay,
  ) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error: $_error'),
            TextButton(onPressed: _loadMonth, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_entries == null || _exercises == null || _targets == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedEntries = byDay[_selectedDay] ?? const <CalorieEntry>[];
    final selectedExercises =
        exerciseByDay[_selectedDay] ?? const <CalorieExerciseEntry>[];
    return RefreshIndicator(
      onRefresh: _loadMonth,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selectedDayLabel(),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showCalendar = !_showCalendar),
                    icon: Icon(
                      _showCalendar
                          ? Icons.calendar_month
                          : Icons.calendar_month_outlined,
                    ),
                    label: Text(_showCalendar ? 'Hide calendar' : 'Choose day'),
                  ),
                ],
              ),
            ),
          ),
          if (_showCalendar) ...[
            _buildCalendar(byDay, exerciseByDay),
            const SizedBox(height: 12),
          ],
          for (final meal in _mealOrder)
            _buildMealSection(
              meal: meal,
              entries: selectedEntries
                  .where((e) => e.mealPeriod == meal)
                  .toList(),
            ),
          _buildExerciseSection(entries: selectedExercises),
        ],
      ),
    );
  }

  Widget _buildCalendar(
    Map<DateTime, List<CalorieEntry>> byDay,
    Map<DateTime, List<CalorieExerciseEntry>> exerciseByDay,
  ) {
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final leadingBlanks = firstOfMonth.weekday - 1;
    final cellCount = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;
    const weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final today = _dayKey(DateTime.now());

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 120) return;
        _changeMonth(velocity < 0 ? 1 : -1);
      },
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _monthLabel(_visibleMonth),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                onPressed: _jumpToToday,
                icon: const Icon(Icons.today_outlined),
                tooltip: 'Jump to today',
              ),
              IconButton(
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Row(
            children: [
              for (final day in weekdays)
                Expanded(
                  child: Center(
                    child: Text(
                      day,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 4.0;
              final cellWidth = (constraints.maxWidth - (spacing * 6)) / 7;
              final cellHeight = (cellWidth * 1.05).clamp(54.0, 74.0);
              final aspectRatio = cellWidth / cellHeight;

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  childAspectRatio: aspectRatio,
                ),
                itemCount: cellCount,
                itemBuilder: (ctx, index) {
                  final day = firstOfMonth.subtract(
                    Duration(days: leadingBlanks - index),
                  );
                  final entries = byDay[day] ?? const <CalorieEntry>[];
                  final exEntries =
                      exerciseByDay[day] ?? const <CalorieExerciseEntry>[];
                  final hasEntries = entries.isNotEmpty || exEntries.isNotEmpty;
                  final totalKcal =
                      entries.fold<int>(0, (sum, e) => sum + e.kcal) -
                      exEntries.fold<int>(0, (sum, e) => sum + e.kcal);
                  final isToday = day == today;
                  final isSelected = day == _selectedDay;
                  final colors = Theme.of(context).colorScheme;
                  final cellColor = isToday
                      ? colors.tertiaryContainer
                      : hasEntries
                      ? colors.primaryContainer
                      : colors.surfaceContainerLow;
                  final textColor = hasEntries
                      ? colors.onPrimaryContainer
                      : colors.onSurface;

                  return Material(
                    color: cellColor,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() {
                        _selectedDay = day;
                        _showCalendar = false;
                      }),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? colors.primary
                                : isToday
                                ? colors.tertiary
                                : Colors.transparent,
                            width: isSelected || isToday ? 1.8 : 0,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isToday
                                      ? colors.onTertiaryContainer
                                      : textColor,
                                ),
                              ),
                              const Spacer(),
                              if (hasEntries)
                                Text(
                                  '$totalKcal kcal',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ).copyWith(color: textColor),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMealSection({
    required String meal,
    required List<CalorieEntry> entries,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _mealLabel(meal),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => _showFoodDialog(meal: meal),
                  icon: const Icon(Icons.add),
                  tooltip: 'Add item',
                ),
              ],
            ),
            if (entries.isEmpty)
              Text('No items', style: Theme.of(context).textTheme.bodySmall)
            else
              for (final entry in entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.name),
                  subtitle: RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.bodySmall,
                      children: [
                        TextSpan(text: '${_fmt(entry.weightG)}g · '),
                        TextSpan(
                          text: 'P ${_fmt(entry.proteinG)}',
                          style: const TextStyle(
                            color: _proteinColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: 'C ${_fmt(entry.carbsG)}',
                          style: const TextStyle(
                            color: _carbsColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: 'F ${_fmt(entry.fatsG)}',
                          style: const TextStyle(
                            color: _fatsColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${entry.kcal} kcal',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        onPressed: () =>
                            _showFoodDialog(meal: meal, existing: entry),
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        onPressed: () => _deleteFood(entry),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildExerciseSection({required List<CalorieExerciseEntry> entries}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Exercise',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => _showExerciseDialog(),
                  icon: const Icon(Icons.add),
                  tooltip: 'Add exercise',
                ),
              ],
            ),
            if (entries.isEmpty)
              Text(
                'No exercise entries',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              for (final entry in entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '-${entry.kcal} kcal',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        onPressed: () => _showExerciseDialog(existing: entry),
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        onPressed: () => _deleteExercise(entry),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _macroProgressRow({
    required String label,
    required Color color,
    required double current,
    required double target,
  }) {
    final hasTarget = target > 0;
    final ratio = hasTarget ? current / target : 0.0;
    final overflow = hasTarget && ratio > 1 ? current - target : 0.0;
    final progress = hasTarget ? ratio.clamp(0.0, 1.0) : 0.0;
    final currentText = _fmt(current);
    final targetText = hasTarget ? _fmt(target) : '-';
    final overflowText = overflow > 0 ? ' +${_fmt(overflow)}' : '';

    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            currentText,
            textAlign: TextAlign.right,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 2),
        Text('/', style: TextStyle(color: color.withValues(alpha: 0.7))),
        const SizedBox(width: 2),
        SizedBox(
          width: 52,
          child: Text(
            targetText,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            overflowText,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
      ],
    );
  }

  Widget _kcalProgressRow({required int netKcal, required int targetKcal}) {
    final hasTarget = targetKcal > 0;
    final ratio = hasTarget ? netKcal / targetKcal : 0.0;
    final overflow = hasTarget && ratio > 1 ? netKcal - targetKcal : 0;
    final progress = hasTarget ? ratio.clamp(0.0, 1.0) : 0.0;
    final color = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            'K',
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '$netKcal',
            textAlign: TextAlign.right,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 2),
        Text('/', style: TextStyle(color: color.withValues(alpha: 0.7))),
        const SizedBox(width: 2),
        SizedBox(
          width: 52,
          child: Text(
            hasTarget ? '$targetKcal' : '-',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            overflow > 0 ? ' +$overflow' : '',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
      ],
    );
  }
}
