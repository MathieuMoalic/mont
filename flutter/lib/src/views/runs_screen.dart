import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../models.dart';
import 'run_calendar_screen.dart';
import 'run_detail_screen.dart';
import 'run_stats_screen.dart';

class RunsScreen extends StatefulWidget {
  const RunsScreen({super.key});

  @override
  State<RunsScreen> createState() => _RunsScreenState();
}

class _RunsScreenState extends State<RunsScreen> {
  List<RunSummary> _runs = [];
  List<PersonalRecord> _prs = [];
  bool _loading = true;

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

  Set<int> get _prRunIds => _prs.map((p) => p.runId).toSet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Runs'),
        actions: [
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
            onPressed: _runs.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RunStatsScreen(runs: _runs),
                      ),
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync Gadgetbridge',
            onPressed: _syncGadgetbridge,
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
                    itemCount: _runs.length,
                    itemBuilder: (context, i) {
                      final run = _runs[i];
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
