import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'run_heatmap_screen.dart';
import 'run_calendar_screen.dart';
import 'run_detail_screen.dart';
import 'run_stats_screen.dart';

enum RunSortField { date, distance, duration, pace, avgHr, elevation }

class RunsScreen extends StatefulWidget {
  const RunsScreen({super.key});

  @override
  State<RunsScreen> createState() => _RunsScreenState();
}

class _RunsScreenState extends State<RunsScreen> {
  List<RunSummary> _runs = [];
  List<PersonalRecord> _prs = [];
  bool _loading = true;
  RunSortField _sortField = RunSortField.date;
  bool _sortAscending = false; // false = descending (newest/longest first)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        api.listRuns(),
        api.getPersonalRecords(),
      ]);
      if (!mounted) return;
      setState(() {
        _runs = results[0] as List<RunSummary>;
        _prs = results[1] as List<PersonalRecord>;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatPace(RunSummary run) {
    if (run.distanceM < 1) return '--';
    final secsPerKm = run.durationS / (run.distanceM / 1000);
    final m = secsPerKm ~/ 60;
    final s = (secsPerKm % 60).round();
    return "$m'${s.toString().padLeft(2, '0')}\"/km";
  }

  Future<void> _syncGadgetbridge() async {
    try {
      final result = await api.syncGadgetbridge();
      await _load();
      if (!mounted) return;
      final imported = result['imported'] as int;
      final errs = (result['errors'] as List?)?.length ?? 0;
      final msg = errs > 0
          ? 'Synced: $imported runs, $errs errors'
          : 'Synced: $imported runs updated';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e')),
      );
    }
  }

  Future<void> _resetAndResync() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all runs?'),
        content: const Text(
            'This will delete every run and reimport them from Gadgetbridge. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset & Reimport'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteAllRuns();
      await _syncGadgetbridge();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset failed: $e')),
      );
    }
  }

  Set<int> get _prRunIds => _prs.map((p) => p.runId).toSet();

  double _getPace(RunSummary run) {
    if (run.distanceM < 1) return double.infinity;
    return run.durationS / (run.distanceM / 1000); // seconds per km
  }

  List<RunSummary> get _sortedRuns {
    final sorted = List<RunSummary>.from(_runs);
    sorted.sort((a, b) {
      int cmp;
      switch (_sortField) {
        case RunSortField.date:
          cmp = a.startedAt.compareTo(b.startedAt);
        case RunSortField.distance:
          cmp = a.distanceM.compareTo(b.distanceM);
        case RunSortField.duration:
          cmp = a.durationS.compareTo(b.durationS);
        case RunSortField.pace:
          cmp = _getPace(a).compareTo(_getPace(b));
        case RunSortField.avgHr:
          final aHr = a.avgHr ?? 0;
          final bHr = b.avgHr ?? 0;
          cmp = aHr.compareTo(bHr);
        case RunSortField.elevation:
          final aElev = a.elevationGainM ?? 0;
          final bElev = b.elevationGainM ?? 0;
          cmp = aElev.compareTo(bElev);
      }
      return _sortAscending ? cmp : -cmp;
    });
    return sorted;
  }

  String _getSortLabel() {
    final arrow = _sortAscending ? '↑' : '↓';
    switch (_sortField) {
      case RunSortField.date:
        return 'Date $arrow';
      case RunSortField.distance:
        return 'Distance $arrow';
      case RunSortField.duration:
        return 'Duration $arrow';
      case RunSortField.pace:
        return 'Pace $arrow';
      case RunSortField.avgHr:
        return 'Avg HR $arrow';
      case RunSortField.elevation:
        return 'Elevation $arrow';
    }
  }

  void _showSortMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Sort by', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            ...RunSortField.values.map((field) {
              final isSelected = field == _sortField;
              String label;
              switch (field) {
                case RunSortField.date:
                  label = 'Date';
                case RunSortField.distance:
                  label = 'Distance';
                case RunSortField.duration:
                  label = 'Duration';
                case RunSortField.pace:
                  label = 'Pace';
                case RunSortField.avgHr:
                  label = 'Avg Heart Rate';
                case RunSortField.elevation:
                  label = 'Elevation Gain';
              }
              return ListTile(
                leading: Icon(
                  isSelected
                      ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                      : Icons.sort,
                  color: isSelected ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(label),
                selected: isSelected,
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    if (_sortField == field) {
                      _sortAscending = !_sortAscending;
                    } else {
                      _sortField = field;
                      // Default directions that make sense
                      _sortAscending = field == RunSortField.pace; // fastest first for pace
                    }
                  });
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Runs'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.sort, size: 18),
            label: Text(_getSortLabel(), style: const TextStyle(fontSize: 12)),
            onPressed: _runs.isEmpty ? null : _showSortMenu,
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Heatmap',
            onPressed: _runs.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RunHeatmapScreen(),
                      ),
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Calendar',
            onPressed: _runs.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RunCalendarScreen(runs: _runs),
                      ),
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Stats',
            onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RunStatsScreen(),
                  ),
                ),
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync Gadgetbridge',
            onPressed: _syncGadgetbridge,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Reset & Reimport',
            onPressed: _resetAndResync,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _runs.isEmpty
              ? const Center(child: Text('No runs yet. Tap ↻ to sync from Gadgetbridge.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _sortedRuns.length,
                    itemBuilder: (context, i) {
                      final run = _sortedRuns[i];
                      final isPr = _prRunIds.contains(run.id);
                      return ListTile(
                        leading: run.isInvalid
                            ? const Icon(Icons.not_interested, color: Colors.grey)
                            : isPr
                                ? const Icon(Icons.emoji_events, color: Colors.amber)
                                : const Icon(Icons.directions_run),
                        title: Text(
                          '${(run.distanceM / 1000).toStringAsFixed(2)} km  ·  ${_formatDuration(run.durationS)}',
                          style: run.isInvalid
                              ? const TextStyle(
                                  color: Colors.grey,
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null,
                        ),
                        subtitle: Text(
                          '${run.startedAt.toLocal().toString().substring(0, 16)}  ·  ${_formatPace(run)}${run.isInvalid ? '  · ⚠ invalid' : ''}',
                          style: run.isInvalid
                              ? const TextStyle(color: Colors.grey)
                              : null,
                        ),
                        trailing: Text(
                          run.avgHr != null ? '♥ ${run.avgHr}' : '',
                          style: const TextStyle(color: Colors.red),
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => RunDetailScreen(runId: run.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
