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
    if (!mounted) return;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final nameFocus = FocusNode();
    String? scannedBarcode;
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
    final weightFocus = FocusNode();
    var selectedMeal = existing?.mealPeriod ?? meal;
    var foodQuery = '';
    var matches = <Food>[];
    var usda_results = <Map<String, dynamic>>[]; // USDA search results
    var searchSeq = 0;
    String? error;
    String? macroSource;
    bool lookupBusy = false;
    String? usda_search_state; // null, 'foundation_empty', 'legacy_empty', 'found'

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final denseDecoration = (InputDecoration base) => base.copyWith(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            );

            Future<void> lookupAndFill(String rawBarcode) async {
              final b = rawBarcode.trim();
              if (b.isEmpty) return;
              var filled = false;
              setLocalState(() {
                lookupBusy = true;
                error = null;
                // Keep the scanned barcode even if no match is found, so the
                // manual entry can be cached against it on Save.
                scannedBarcode = b;
              });
              try {
                // 1) Try local cache first.
                final cached = await api.getFoodByBarcode(b);
                setLocalState(() {
                  nameController.text = cached.name;
                  foodQuery = cached.name;
                  proteinPer100Controller.text = _fmt(cached.proteinPer100G);
                  carbsPer100Controller.text = _fmt(cached.carbsPer100G);
                  fatsPer100Controller.text = _fmt(cached.fatsPer100G);
                  weightController.text = _fmt(cached.lastWeightG);
                });
                filled = true;
              } catch (_) {
                try {
                  // 2) Fallback to online lookup (Poland-focused).
                  final lookedUp = await api.lookupFoodByBarcode(b);
                  setLocalState(() {
                    nameController.text = lookedUp.name;
                    foodQuery = lookedUp.name;
                    proteinPer100Controller.text = _fmt(
                      lookedUp.proteinPer100G,
                    );
                    carbsPer100Controller.text = _fmt(lookedUp.carbsPer100G);
                    fatsPer100Controller.text = _fmt(lookedUp.fatsPer100G);
                    // Prefer keeping an existing weight if user already typed it.
                    if (weightController.text.trim().isEmpty) {
                      weightController.text = '100';
                    }
                  });
                  filled = true;
                } catch (e) {
                  setLocalState(() {
                    error =
                        'No product found for barcode $b. '
                        'Enter the item manually and press Save to cache it for next time.';
                  });
                  // Fast path after a miss: put the cursor on Name.
                  nameFocus.requestFocus();
                }
              } finally {
                setLocalState(() => lookupBusy = false);
                if (!context.mounted) return;
                if (filled) {
                  // Fastest flow: after fill, jump straight to weight.
                  weightFocus.requestFocus();
                  weightController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: weightController.text.length,
                  );
                }
              }
            }

            Future<void> _extractMacrosWithLlm(
              BuildContext context,
              String foodName,
              StateSetter setLocalState,
            ) async {
              final name = foodName.trim();
              if (name.isEmpty) return;
              setLocalState(() {
                lookupBusy = true;
                error = null;
                macroSource = null;
                usda_search_state = 'none';
              });
              try {
                final macros = await api.extractMacrosWithLlm(name);
                setLocalState(() {
                  nameController.text = (macros['name'] as String?) ?? name;
                  foodQuery = (macros['name'] as String?) ?? name;
                  proteinPer100Controller.text = _fmt(macros['protein_per_100g'] ?? 0);
                  carbsPer100Controller.text = _fmt(macros['carbs_per_100g'] ?? 0);
                  fatsPer100Controller.text = _fmt(macros['fats_per_100g'] ?? 0);
                  macroSource = (macros['source'] as String?) ?? 'unknown';
                  if (weightController.text.trim().isEmpty) {
                    weightController.text = '100';
                  }
                });
                if (!context.mounted) return;
                weightFocus.requestFocus();
                weightController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: weightController.text.length,
                );
              } catch (e) {
                setLocalState(() {
                  error = 'Failed to extract macros: ${e.toString()}';
                });
              } finally {
                setLocalState(() => lookupBusy = false);
              }
            }

            Future<void> _searchUSDAAndFallback(
              BuildContext context,
              String foodName,
              String dataType,
              StateSetter setLocalState,
            ) async {
              final name = foodName.trim();
              if (name.isEmpty) return;
              
              setLocalState(() {
                lookupBusy = true;
                error = null;
                macroSource = null;
              });
              
              try {
                // First, search for results
                final results = await api.searchUSDAFoods(name, dataType);
                
                if (!context.mounted) return;
                
                if (results.isEmpty) {
                  // No results, move to next dataset or LLM
                  setLocalState(() {
                    lookupBusy = false;
                    if (dataType == 'Foundation') {
                      error = null;
                      usda_search_state = 'foundation_empty';
                    } else if (dataType == 'SR Legacy') {
                      error = null;
                      usda_search_state = 'legacy_empty';
                    }
                  });
                  return;
                }

                // Add results to list and display inline
                setLocalState(() {
                  lookupBusy = false;
                  usda_results = results;
                  usda_search_state = 'showing_results';
                });
              } catch (e) {
                setLocalState(() {
                  lookupBusy = false;
                  error = 'Search failed: $e';
                  usda_results = [];
                });
              }
            }

            Future<void> _selectUSDAResult(
              BuildContext context,
              String foodName,
              String dataType,
              Map<String, dynamic> result,
              StateSetter setLocalState,
            ) async {
              try {
                // Extract macros directly from search result (already available from USDA API)
                final protein = (result['protein_per_100g'] as num?)?.toDouble() ?? 0.0;
                final carbs = (result['carbs_per_100g'] as num?)?.toDouble() ?? 0.0;
                final fats = (result['fats_per_100g'] as num?)?.toDouble() ?? 0.0;
                
                setLocalState(() {
                  nameController.text = (result['description'] as String?) ?? foodName;
                  foodQuery = (result['description'] as String?) ?? foodName;
                  proteinPer100Controller.text = _fmt(protein);
                  carbsPer100Controller.text = _fmt(carbs);
                  fatsPer100Controller.text = _fmt(fats);
                  macroSource = 'usda_${dataType.toLowerCase().replaceAll(' ', '_')}';
                  usda_search_state = 'found';
                  usda_results = [];
                  if (weightController.text.trim().isEmpty) {
                    weightController.text = '100';
                  }
                });
                if (!context.mounted) return;
                weightFocus.requestFocus();
                weightController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: weightController.text.length,
                );
              } catch (e) {
                setLocalState(() {
                  error = 'Failed to select food: $e';
                });
              }
            }

            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              titlePadding: EdgeInsets.zero,
              contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              scrollable: true,
              title: null,
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Section dropdown removed for speed; defaults to the section
                    // that the user tapped (or the existing entry's section).
                    if (scannedBarcode != null && scannedBarcode!.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Barcode: $scannedBarcode',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    if (scannedBarcode != null && error != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Not found. Type name + macros, Save to cache this barcode.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    TextField(
                      controller: nameController,
                      focusNode: nameFocus,
                      decoration: denseDecoration(
                        InputDecoration(
                          labelText: 'Name',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Scan barcode',
                                icon: const Icon(Icons.qr_code_scanner),
                                onPressed: () async {
                                  final scanned = await Navigator.of(context)
                                      .push<String>(
                                        MaterialPageRoute(
                                          builder: (_) => const BarcodeScanScreen(),
                                        ),
                                      );
                                  if (scanned == null || scanned.trim().isEmpty) {
                                    return;
                                  }
                                  await lookupAndFill(scanned);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      onChanged: (v) {
                        setLocalState(() => foodQuery = v);
                        final q = v.trim();
                        if (existing != null) return;
                        if (q.length < 2) {
                          setLocalState(() => matches = <Food>[]);
                          return;
                        }
                        final mySeq = ++searchSeq;
                        api
                            .listFoods(query: q)
                            .then((results) {
                              if (!context.mounted) return;
                              if (mySeq != searchSeq) return;
                              setLocalState(
                                () => matches = results.take(4).toList(),
                              );
                            })
                            .catchError((_) {});
                      },
                    ),
                    if (existing == null && (matches.isNotEmpty || usda_results.isNotEmpty || lookupBusy && usda_search_state != null))
                      Container(
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
                            // Show loading spinner if searching USDA
                            if (lookupBusy && usda_results.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                child: Column(
                                  children: [
                                    const SizedBox(
                                      height: 24,
                                      width: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Searching ${usda_search_state == 'showing_results' ? 'USDA' : 'database'}...',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            // Show USDA results if available
                            if (usda_results.isNotEmpty)
                              for (int idx = 0; idx < usda_results.length; idx++) ...[
                                InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: lookupBusy
                                      ? null
                                      : () => _selectUSDAResult(
                                        context,
                                        foodQuery,
                                        usda_results[idx]['data_type'] ?? 'Foundation',
                                        usda_results[idx],
                                        setLocalState,
                                      ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    child: Text(
                                      usda_results[idx]['description'] ?? 'Unknown',
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                                if (idx != usda_results.length - 1)
                                  Divider(
                                    height: 1,
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                  ),
                              ],
                            // Show "Extend search" button if USDA results displayed
                            if (usda_results.isNotEmpty && usda_search_state == 'showing_results') ...[
                              const Divider(height: 8),
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.tonal(
                                    onPressed: lookupBusy
                                        ? null
                                        : () => _searchUSDAAndFallback(
                                          context,
                                          foodQuery,
                                          usda_results[0]['data_type'] == 'Foundation'
                                              ? 'SR Legacy'
                                              : 'Foundation',
                                          setLocalState,
                                        ),
                                    child: Text(
                                      usda_results[0]['data_type'] == 'Foundation'
                                          ? 'Extend search to SR Legacy'
                                          : 'Estimate with AI',
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            // Show local DB results only if no USDA search in progress
                            if (usda_results.isEmpty && !lookupBusy)
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
                                    weightFocus.requestFocus();
                                    weightController.selection = TextSelection(
                                      baseOffset: 0,
                                      extentOffset: weightController.text.length,
                                    );
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
                      ),
                    if (existing == null && foodQuery.isNotEmpty && (matches.isEmpty || matches.length < 4))
                      Column(
                        children: [
                                                     if (usda_search_state == null && usda_results.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 4),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonal(
                                  onPressed: lookupBusy
                                      ? null
                                      : () => _searchUSDAAndFallback(
                                            context,
                                            foodQuery,
                                            'Foundation',
                                            setLocalState,
                                          ),
                                  child: lookupBusy && usda_search_state != 'found'
                                      ? const SizedBox(
                                          height: 16,
                                          width: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Search USDA Foundation'),
                                ),
                              ),
                            ),
                                                     if (usda_search_state == 'foundation_empty' && usda_results.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 4),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonal(
                                  onPressed: lookupBusy
                                      ? null
                                      : () => _searchUSDAAndFallback(
                                            context,
                                            foodQuery,
                                            'SR Legacy',
                                            setLocalState,
                                          ),
                                  child: lookupBusy
                                      ? const SizedBox(
                                          height: 16,
                                          width: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Extend search to SR Legacy'),
                                ),
                              ),
                            ),
                          if (usda_search_state == 'legacy_empty')
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 4),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonal(
                                  onPressed: lookupBusy
                                      ? null
                                      : () => _extractMacrosWithLlm(
                                            context,
                                            foodQuery,
                                            setLocalState,
                                          ),
                                  child: lookupBusy
                                      ? const SizedBox(
                                          height: 16,
                                          width: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Estimate with AI'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    TextField(
                      controller: proteinPer100Controller,
                      decoration: denseDecoration(
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
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: carbsPer100Controller,
                      decoration: denseDecoration(
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
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: fatsPer100Controller,
                      decoration: denseDecoration(
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
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    TextField(
                      controller: weightController,
                      decoration: denseDecoration(
                        const InputDecoration(labelText: 'Total weight (g)'),
                      ),
                      focusNode: weightFocus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (macroSource != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Source: ${macroSource!.toUpperCase()}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                if (existing != null)
                  TextButton.icon(
                    onPressed: () => _deleteFood(existing),
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                const Spacer(),
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
                      setLocalState(
                        () => error = 'Use numbers for macros/weight.',
                      );
                      return;
                    }
                    if (proteinPer100 < 0 ||
                        carbsPer100 < 0 ||
                        fatsPer100 < 0) {
                      setLocalState(() => error = 'Macros cannot be negative.');
                      return;
                    }
                    if (weight <= 0) {
                      setLocalState(
                        () => error = 'Weight must be greater than 0g.',
                      );
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

                      final barcode = scannedBarcode?.trim() ?? '';
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

    nameFocus.dispose();
    weightFocus.dispose();
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
                decoration: const InputDecoration(
                  labelText: 'Extra kcal (adds to today\'s target)',
                  helperText: 'Converted to carbs: kcal / 4 (g).',
                ),
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
            if (existing != null)
              TextButton.icon(
                onPressed: () => _deleteExercise(existing),
                icon: const Icon(Icons.delete),
                label: const Text('Delete'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
              ),
            const Spacer(),
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
    final targets =
        _targets ?? NutritionTargets(proteinG: 0, carbsG: 0, fatsG: 0);

    // Exercise entries increase the day's targets by adding the equivalent kcal
    // as carbs grams (kcal / 4). This keeps targets macro-based and day-scoped.
    final extraCarbsFromExerciseG = exerciseKcal / 4.0;
    final effectiveProteinTargetG = targets.proteinG;
    final effectiveCarbsTargetG = targets.carbsG + extraCarbsFromExerciseG;
    final effectiveFatsTargetG = targets.fatsG;
    final effectiveTargetKcal = _kcalFromMacros(
      effectiveProteinTargetG,
      effectiveCarbsTargetG,
      effectiveFatsTargetG,
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
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _footerMetric(
                  title: 'Protein',
                  unit: 'g',
                  color: _proteinColor,
                  currentText: _fmt(totalProtein),
                  targetText: _fmt(effectiveProteinTargetG),
                  current: totalProtein,
                  target: effectiveProteinTargetG,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _footerMetric(
                  title: 'Carbs',
                  unit: 'g',
                  color: _carbsColor,
                  currentText: _fmt(totalCarbs),
                  targetText: _fmt(effectiveCarbsTargetG),
                  current: totalCarbs,
                  target: effectiveCarbsTargetG,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _footerMetric(
                  title: 'Fats',
                  unit: 'g',
                  color: _fatsColor,
                  currentText: _fmt(totalFats),
                  targetText: _fmt(effectiveFatsTargetG),
                  current: totalFats,
                  target: effectiveFatsTargetG,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _footerMetric(
                  title: 'Energy',
                  unit: 'kcal',
                  color: Theme.of(context).colorScheme.primary,
                  currentText: '$intakeKcal',
                  targetText: '$effectiveTargetKcal',
                  current: intakeKcal.toDouble(),
                  target: effectiveTargetKcal.toDouble(),
                ),
              ),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  onTap: () => _showFoodDialog(meal: meal, existing: entry),
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
                  trailing: Text(
                    '${entry.kcal} kcal',
                    style: const TextStyle(fontWeight: FontWeight.w700),
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
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  onTap: () => _showExerciseDialog(existing: entry),
                  title: Text(entry.name),
                  trailing: Text(
                    '+${_fmt(entry.kcal / 4)}g carbs',
                    style: const TextStyle(fontWeight: FontWeight.w700),
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

  Widget _footerMetric({
    required String title,
    required String unit,
    required Color color,
    required String currentText,
    required String targetText,
    required double current,
    required double target,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title ($unit)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        _compactProgressPill(
          color: color,
          currentText: currentText,
          targetText: targetText,
          current: current,
          target: target,
        ),
      ],
    );
  }

  Widget _compactProgressPill({
    required Color color,
    required String currentText,
    required String targetText,
    required double current,
    required double target,
  }) {
    final hasTarget = target > 0;
    final ratio = hasTarget ? (current / target) : 0.0;
    final progress = hasTarget ? ratio.clamp(0.0, 1.0) : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 22,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LinearProgressIndicator(
              value: progress,
              backgroundColor: color.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 22,
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$currentText/$targetText',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
