import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart' as api;
import '../models.dart';
import 'body_pictures_widget.dart';

class HealthJournalEntry {
  final int id;
  String text;
  final DateTime createdAt;

  HealthJournalEntry({
    required this.id,
    required this.text,
    required this.createdAt,
  });
}

class CaffeineDose {
  final int id;
  final int mg;
  final DateTime timestamp;

  CaffeineDose({
    required this.id,
    required this.mg,
    required this.timestamp,
  });
}


enum _Range {
  twoWeeks('2W', 14),
  oneMonth('1M', 30),
  threeMonths('3M', 90),
  all('All', 0);

  const _Range(this.label, this.days);
  final String label;
  final int days; // 0 = unlimited
}

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  List<DailyHealth>? _days;
  List<WeightEntry>? _weights;
  String? _error;
  bool _syncing = false;
  _Range _range = _Range.twoWeeks;
  Map<DateTime, List<HealthJournalEntry>> _journalEntries = {};
  Map<DateTime, List<CaffeineDose>> _caffeineDoses = {};

  double? _parseWeightKg(String raw) {
    final v = raw.trim().replaceAll(',', '.');
    return double.tryParse(v);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        api.listDailyHealth(),
        api.listWeight(),
      ]);
      if (mounted) {
        setState(() {
          _days = results[0] as List<DailyHealth>;
          _weights = results[1] as List<WeightEntry>;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final result = await api.syncGadgetbridge();
      final healthDays = result['health_days'] as int? ?? 0;
      final imported = result['imported'] as int? ?? 0;
      final errors = (result['errors'] as List?)?.cast<String>() ?? [];
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Synced: $imported runs, $healthDays health days'
              '${errors.isNotEmpty ? ', ${errors.length} errors' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _addWeight() async {
    String raw = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log body mass'),
        content: TextFormField(
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Body mass (kg)',
            suffixText: 'kg',
          ),
          onChanged: (v) => raw = v,
          onFieldSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final entered = _parseWeightKg(raw);
    if (confirmed != true || entered == null || entered <= 0 || !mounted) {
      if (confirmed == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid body mass (kg)')),
        );
      }
      return;
    }
    try {
      await api.createWeightEntry(weightKg: entered);
      await _load();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _captureBodyPicture() async {
    // Request camera permission
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission denied')),
        );
      }
      return;
    }

    final picker = ImagePicker();
    try {
      final pickedFile = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
      );

      if (pickedFile == null) return;

      // Show uploading dialog
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Uploading photo...'),
              ],
            ),
          ),
        );
      }

      // Read and convert to base64
      final bytes = await pickedFile.readAsBytes();
      final base64Data = base64.encode(bytes);

      // Get today's date in YYYY-MM-DD format
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Upload to backend
      await api.uploadBodyPicture(pictureDate: today, base64Data: base64Data);

      if (mounted) {
        Navigator.pop(context); // Close upload dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo saved successfully')),
        );
        _load(); // Refresh health data
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close upload dialog
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<void> _deleteWeight(WeightEntry entry) async {
    try {
      await api.deleteWeightEntry(entry.id);
      _load();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _editWeight(WeightEntry entry) async {
    final d = entry.measuredAt.toLocal();
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    double? newKg = entry.weightKg;
    String? newDate = dateStr;
    final kgCtrl = TextEditingController(
      text: entry.weightKg.toStringAsFixed(1),
    );
    final dateCtrl = TextEditingController(text: dateStr);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: kgCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Body mass (kg)',
                suffixText: 'kg',
              ),
              onChanged: (v) => newKg = _parseWeightKg(v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: dateCtrl,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(labelText: 'Date (YYYY-MM-DD)'),
              onChanged: (v) => newDate = v.trim(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final parsedKg = _parseWeightKg(kgCtrl.text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      kgCtrl.dispose();
      dateCtrl.dispose();
    });
    if (confirmed != true || !mounted) return;
    if (parsedKg == null || parsedKg <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid body mass (kg)')),
      );
      return;
    }
    try {
      final measuredAt = newDate != null && newDate!.isNotEmpty
          ? '${newDate!}T12:00:00Z'
          : null;
      await api.updateWeightEntry(
        entry.id,
        weightKg: parsedKg,
        measuredAt: measuredAt,
      );
      _load();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  List<DailyHealth> get _filteredDays {
    final all = _days ?? [];
    if (_range.days == 0 || all.isEmpty) return all;
    final cutoff = DateTime.now().subtract(Duration(days: _range.days));
    final cutStr =
        '${cutoff.year}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    return all.where((d) => d.date.compareTo(cutStr) >= 0).toList();
  }

  List<WeightEntry> get _filteredWeights {
    final all = _weights ?? [];
    if (_range.days == 0 || all.isEmpty) return all;
    final cutoff = DateTime.now().subtract(Duration(days: _range.days));
    return all.where((w) => w.measuredAt.isAfter(cutoff)).toList();
  }

  void _addJournalEntry() {
    final textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Journal Entry'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            labelText: 'What\'s on your mind?',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = textCtrl.text.trim();
              if (text.isEmpty) return;
              setState(() {
                final today = DateTime(
                  DateTime.now().year,
                  DateTime.now().month,
                  DateTime.now().day,
                );
                _journalEntries.putIfAbsent(today, () => []);
                _journalEntries[today]!.insert(
                  0,
                  HealthJournalEntry(
                    id: DateTime.now().millisecondsSinceEpoch,
                    text: text,
                    createdAt: DateTime.now(),
                  ),
                );
              });
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildJournalSection() {
    // Get all entries sorted by date (newest first)
    final allEntries = <HealthJournalEntry>[];
    for (final entries in _journalEntries.values) {
      allEntries.addAll(entries);
    }
    allEntries.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Health Journal',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (allEntries.isEmpty)
            Text(
              'No journal entries yet',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: allEntries.length,
              itemBuilder: (ctx, i) {
                final entry = allEntries[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    title: Text(
                      entry.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _formatEntryDate(entry.createdAt),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        setState(() {
                          _journalEntries.values
                              .toList()
                              .forEach((entries) => entries.removeWhere(
                                    (e) => e.id == entry.id,
                                  ));
                        });
                      },
                      tooltip: 'Delete',
                    ),
                    onTap: () => _editJournalEntry(entry),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _editJournalEntry(HealthJournalEntry entry) {
    final textCtrl = TextEditingController(text: entry.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Journal Entry'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            labelText: 'Journal entry',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = textCtrl.text.trim();
              if (text.isNotEmpty) {
                setState(() {
                  entry.text = text;
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatEntryDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final entryDate = DateTime(dt.year, dt.month, dt.day);

    String dateStr;
    if (entryDate == today) {
      dateStr = 'Today';
    } else if (entryDate == yesterday) {
      dateStr = 'Yesterday';
    } else {
      dateStr =
          '${entryDate.day}/${entryDate.month}/${entryDate.year}';
    }

    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$dateStr at $time';
  }

  void _addCaffeineDose() {
    int mg = 50;
    TimeOfDay time = TimeOfDay.now();
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Add Caffeine Dose'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                keyboardType: TextInputType.number,
                onChanged: (v) => setLocalState(() => mg = int.tryParse(v) ?? 50),
                decoration: const InputDecoration(
                  labelText: 'Caffeine (mg)',
                  suffixText: 'mg',
                ),
                controller: TextEditingController(text: mg.toString()),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Time:'),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: time,
                      );
                      if (picked != null) {
                        setLocalState(() => time = picked);
                      }
                    },
                    child: Text(
                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);
                final doseTime = today.add(Duration(hours: time.hour, minutes: time.minute));
                
                setState(() {
                  _caffeineDoses.putIfAbsent(today, () => []);
                  _caffeineDoses[today]!.add(
                    CaffeineDose(
                      id: DateTime.now().millisecondsSinceEpoch,
                      mg: mg,
                      timestamp: doseTime,
                    ),
                  );
                  // Sort by time
                  _caffeineDoses[today]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
          actionsPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _buildCaffeineSection() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final doses = _caffeineDoses[today] ?? [];
    final totalMg = doses.fold<int>(0, (sum, dose) => sum + dose.mg);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Caffeine Today',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                '${totalMg}mg',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (doses.isEmpty)
            Text(
              'No doses logged',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: doses.length,
              itemBuilder: (ctx, i) {
                final dose = doses[i];
                final doseTime = '${dose.timestamp.hour.toString().padLeft(2, '0')}:${dose.timestamp.minute.toString().padLeft(2, '0')}';
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    title: Text('${dose.mg}mg'),
                    subtitle: Text(doseTime),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        setState(() {
                          _caffeineDoses[today]?.removeWhere((d) => d.id == dose.id);
                        });
                      },
                      tooltip: 'Delete',
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _captureBodyPicture,
            tooltip: 'Capture body picture',
            child: const Icon(Icons.camera_alt),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            onPressed: _addWeight,
            tooltip: 'Log body mass',
            child: const Icon(Icons.monitor_weight_outlined),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            onPressed: _addJournalEntry,
            tooltip: 'Add journal entry',
            child: const Icon(Icons.edit_note),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            onPressed: _addCaffeineDose,
            tooltip: 'Add caffeine dose',
            child: const Icon(Icons.local_cafe),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _error != null
            ? Center(child: Text(_error!))
            : (_days == null || _weights == null)
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final days = _filteredDays;
    final weights = _filteredWeights;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('Health'),
          floating: true,
          actions: [
            if (_syncing)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Sync from Gadgetbridge',
                onPressed: _sync,
              ),
          ],
        ),
        SliverToBoxAdapter(child: _buildRangeChips()),
        SliverToBoxAdapter(child: _buildHrChart(days)),
        SliverToBoxAdapter(child: _buildHrvChart(days)),
        SliverToBoxAdapter(child: _buildStepsChart(days)),
        SliverToBoxAdapter(child: _buildWeightChart(weights)),
        const SliverToBoxAdapter(child: BodyPicturesSection()),
        SliverToBoxAdapter(child: _buildJournalSection()),
        SliverToBoxAdapter(child: _buildCaffeineSection()),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Widget _buildRangeChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: _Range.values
            .map(
              (r) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(r.label),
                  selected: _range == r,
                  onSelected: (_) => setState(() => _range = r),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────

  // Format date string (YYYY-MM-DD) as DD/MM
  static String _fmtDate(String dateStr) {
    final date = DateTime.tryParse(dateStr);
    if (date == null) return dateStr;
    return '${date.day}/${date.month}';
  }

  FlTitlesData _axisTitlesWithDates({
    required double yReserved,
    required List<DailyHealth> days,
    double? yInterval,
  }) => FlTitlesData(
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: yReserved,
        interval: yInterval,
        getTitlesWidget: (v, meta) {
          return Text(
            v.toInt().toString(),
            style: const TextStyle(fontSize: 9),
          );
        },
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 20,
        interval: days.length > 20
            ? (days.length / 4).ceilToDouble()
            : (days.length > 10 ? 3 : 2),
        getTitlesWidget: (v, _) {
          final idx = v.toInt();
          if (idx < 0 || idx >= days.length) return const SizedBox.shrink();
          return Text(
            _fmtDate(days[idx].date),
            style: const TextStyle(fontSize: 8),
          );
        },
      ),
    ),
    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
  );

  LineTouchData _intTooltip(List<DailyHealth> days, {int decimals = 0}) =>
      LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (spots) => spots.map((s) {
            final idx = s.x.toInt();
            final date = idx >= 0 && idx < days.length ? days[idx].date : '';
            return LineTooltipItem(
              '${s.y.toStringAsFixed(decimals)}\n$date',
              const TextStyle(fontSize: 11),
            );
          }).toList(),
        ),
      );

  Widget _chartSection({
    required String label,
    required double height,
    required Widget child,
    Widget? action,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              if (action != null) ...[const Spacer(), action],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }

  // ── Charts ────────────────────────────────────────────────────────────────

  Widget _detailsBtn(VoidCallback onTap) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    ),
    child: const Text('Details'),
  );

  void _showSheet(String title, List<Widget> rows) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        minChildSize: 0.25,
        expand: false,
        builder: (_, scroll) => Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ListView(controller: scroll, children: rows),
            ),
          ],
        ),
      ),
    );
  }

  void _showHrDetails(List<DailyHealth> days) {
    _showSheet(
      'Heart Rate (bpm)',
      days.reversed
          .map(
            (d) => ListTile(
              dense: true,
              title: Text(d.date),
              trailing: Text(
                d.avgHr != null
                    ? 'avg ${d.avgHr} • min ${d.minHr ?? '—'} • max ${d.maxHr ?? '—'}'
                    : '—',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          )
          .toList(),
    );
  }

  void _showHrvDetails(List<DailyHealth> days) {
    _showSheet(
      'HRV (ms)',
      days.reversed
          .map(
            (d) => ListTile(
              dense: true,
              title: Text(d.date),
              trailing: Text(
                d.hrvRmssd != null ? d.hrvRmssd!.toStringAsFixed(0) : '—',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          )
          .toList(),
    );
  }

  void _showStepsDetails(List<DailyHealth> days) {
    _showSheet(
      'Steps per day',
      days.reversed
          .map(
            (d) => ListTile(
              dense: true,
              title: Text(d.date),
              trailing: Text(
                d.steps != null ? '${d.steps}' : '—',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          )
          .toList(),
    );
  }

  void _showWeightDetails(List<WeightEntry> weights) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final sorted = [...weights]
            ..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
          return DraggableScrollableSheet(
            initialChildSize: 0.5,
            maxChildSize: 0.9,
            minChildSize: 0.25,
            expand: false,
            builder: (_, scroll) => Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Body Mass (kg)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: sorted.length,
                    itemBuilder: (_, i) {
                      final entry = sorted[i];
                      final d = entry.measuredAt.toLocal();
                      return Dismissible(
                        key: ValueKey(entry.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) {
                          _deleteWeight(entry);
                          setSheetState(() => sorted.removeAt(i));
                        },
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.monitor_weight_outlined),
                          title: Text('${entry.weightKg} kg'),
                          subtitle: Text('${d.day}/${d.month}/${d.year}'),
                          trailing: const Icon(Icons.edit_outlined, size: 16),
                          onTap: () {
                            Navigator.pop(ctx);
                            _editWeight(entry);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHrChart(List<DailyHealth> days) {
    final hrDays = days.where((d) => d.avgHr != null).toList();
    if (hrDays.isEmpty) {
      return _chartSection(
        label: 'Heart Rate (bpm)',
        height: 48,
        child: const Center(
          child: Text('No HR data in range', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    final indexed = hrDays.asMap().entries.toList();
    final avgSpots = indexed
        .map((e) => FlSpot(e.key.toDouble(), e.value.avgHr!.toDouble()))
        .toList();
    final minSpots = indexed
        .map(
          (e) => FlSpot(
            e.key.toDouble(),
            (e.value.minHr ?? e.value.avgHr!).toDouble(),
          ),
        )
        .toList();
    final maxSpots = indexed
        .map(
          (e) => FlSpot(
            e.key.toDouble(),
            (e.value.maxHr ?? e.value.avgHr!).toDouble(),
          ),
        )
        .toList();
    final allHr = hrDays
        .expand((d) => [d.minHr ?? d.avgHr!, d.maxHr ?? d.avgHr!])
        .map((v) => v.toDouble());
    final maxY =
        ((allHr.reduce((a, b) => a > b ? a : b) + 10) / 20).ceil() * 20.0;
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'Heart Rate (bpm)',
      height: 160,
      action: _detailsBtn(() => _showHrDetails(hrDays)),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            horizontalInterval: 40,
            verticalInterval: 1000,
          ),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitlesWithDates(
            yReserved: 36,
            days: hrDays,
            yInterval: 40,
          ),
          lineTouchData: _intTooltip(hrDays),
          lineBarsData: [
            LineChartBarData(
              spots: minSpots,
              isCurved: true,
              color: scheme.primary.withValues(alpha: 0.45),
              dotData: FlDotData(show: false),
              barWidth: 1.5,
              dashArray: [4, 4],
            ),
            LineChartBarData(
              spots: avgSpots,
              isCurved: true,
              color: scheme.primary,
              dotData: FlDotData(show: false),
              barWidth: 2,
            ),
            LineChartBarData(
              spots: maxSpots,
              isCurved: true,
              color: scheme.primary.withValues(alpha: 0.45),
              dotData: FlDotData(show: false),
              barWidth: 1.5,
              dashArray: [4, 4],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHrvChart(List<DailyHealth> days) {
    final hrvDays = days.where((d) => d.hrvRmssd != null).toList();
    if (hrvDays.isEmpty) {
      return _chartSection(
        label: 'HRV (ms)',
        height: 48,
        child: const Center(
          child: Text('No HRV data in range', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    final indexed = hrvDays.asMap().entries.toList();
    final spots = indexed
        .map((e) => FlSpot(e.key.toDouble(), e.value.hrvRmssd!))
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'HRV (ms)',
      height: 120,
      action: _detailsBtn(() => _showHrvDetails(hrvDays)),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 180,
          gridData: FlGridData(
            show: true,
            horizontalInterval: 30,
            verticalInterval: 1000,
          ),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitlesWithDates(
            yReserved: 36,
            days: hrvDays,
            yInterval: 30,
          ),
          lineTouchData: _intTooltip(hrvDays),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: scheme.tertiary,
              dotData: FlDotData(show: false),
              barWidth: 2,
              belowBarData: BarAreaData(
                show: true,
                color: scheme.tertiary.withValues(alpha: 0.10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepsChart(List<DailyHealth> days) {
    final stepDays = days
        .where((d) => d.steps != null && d.steps! > 0)
        .toList();
    if (stepDays.isEmpty) {
      return _chartSection(
        label: 'Steps per day',
        height: 48,
        child: const Center(
          child: Text('No steps data in range', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    final indexed = stepDays.asMap().entries.toList();
    final spots = indexed
        .map((e) => FlSpot(e.key.toDouble(), e.value.steps!.toDouble()))
        .toList();
    final maxSteps = stepDays
        .map((d) => d.steps!.toDouble())
        .reduce((a, b) => a > b ? a : b);
    final maxY = ((maxSteps + 2000) / 5000).ceil() * 5000.0;
    final yInterval = maxY > 20000 ? 10000.0 : 5000.0;
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'Steps per day',
      height: 120,
      action: _detailsBtn(() => _showStepsDetails(stepDays)),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            horizontalInterval: yInterval,
            verticalInterval: 1000,
          ),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitlesWithDates(
            yReserved: 44,
            days: stepDays,
            yInterval: yInterval,
          ),
          lineTouchData: _intTooltip(stepDays),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: scheme.secondary,
              dotData: FlDotData(show: false),
              barWidth: 2,
              belowBarData: BarAreaData(
                show: true,
                color: scheme.secondary.withValues(alpha: 0.10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeightChart(List<WeightEntry> weights) {
    if (weights.length < 2) {
      return _chartSection(
        label: 'Body Mass (kg)',
        height: 48,
        child: Center(
          child: Text(
            weights.isEmpty
                ? 'No body mass entries in range'
                : 'Need at least 2 entries to show chart',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      );
    }
    final sorted = [...weights]
      ..sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
    final base = sorted.first.measuredAt.toLocal();
    double xFor(DateTime dt) =>
        dt.toLocal().difference(base).inMinutes.toDouble() / (60 * 24);
    DateTime dateForX(double x) =>
        base.add(Duration(minutes: (x * 60 * 24).round()));
    final spots = sorted
        .map((w) => FlSpot(xFor(w.measuredAt), w.weightKg))
        .toList();
    final minX = spots.first.x;
    final maxX = spots.last.x;
    final xSpan = (maxX - minX).abs();
    final xInterval = xSpan <= 4 ? 1.0 : (xSpan / 4).ceilToDouble();
    final ws = weights.map((w) => w.weightKg);
    final minW = ws.reduce((a, b) => a < b ? a : b);
    final maxW = ws.reduce((a, b) => a > b ? a : b);
    final minY = (minW - 2).floorToDouble();
    final maxY = (maxW + 2).ceilToDouble();
    final scheme = Theme.of(context).colorScheme;
    return _chartSection(
      label: 'Body Mass (kg)',
      height: 160,
      action: _detailsBtn(() => _showWeightDetails(weights)),
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            horizontalInterval: 2,
            verticalInterval: 1000,
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 2,
                getTitlesWidget: (v, meta) {
                  return Text(
                    v.toInt().toString(),
                    style: const TextStyle(fontSize: 9),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: xInterval,
                getTitlesWidget: (v, _) {
                  final d = dateForX(v);
                  return Text(
                    '${d.day}/${d.month}',
                    style: const TextStyle(fontSize: 8),
                  );
                },
              ),
            ),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots.map((s) {
                final idx = s.spotIndex;
                final d = idx >= 0 && idx < sorted.length
                    ? sorted[idx].measuredAt.toLocal()
                    : null;
                final date = d != null ? '${d.day}/${d.month}/${d.year}' : '';
                return LineTooltipItem(
                  '${s.y.toStringAsFixed(1)} kg\n$date',
                  const TextStyle(fontSize: 11),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: scheme.primary,
              barWidth: 2.5,
              dotData: FlDotData(show: spots.length <= 30),
              belowBarData: BarAreaData(
                show: true,
                color: scheme.primary.withValues(alpha: 0.10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
