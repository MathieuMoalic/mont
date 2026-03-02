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

  Widget _buildPrSection() {
    if (_prs.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.all(12),
      child: ExpansionTile(
        leading: const Icon(Icons.emoji_events, color: Colors.amber),
        title: const Text('Personal Records',
            style: TextStyle(fontWeight: FontWeight.bold)),
        initiallyExpanded: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _prs.map((pr) {
                final date =
                    '${pr.runDate.toLocal().day}/${pr.runDate.toLocal().month}/${pr.runDate.toLocal().year.toString().substring(2)}';
                return ActionChip(
                  avatar: const Icon(Icons.emoji_events, size: 16, color: Colors.amber),
                  label: Text(
                    '${pr.distanceLabel}: ${pr.formattedTime}\n$date',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => RunDetailScreen(runId: pr.runId)),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

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
                    itemCount: _runs.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) return _buildPrSection();
                      final run = _runs[i - 1];
                      final isPr = _prRunIds.contains(run.id);
                      return ListTile(
                        leading: isPr
                            ? const Icon(Icons.emoji_events, color: Colors.amber)
                            : const Icon(Icons.directions_run),
                        title: Text(
                          '${(run.distanceM / 1000).toStringAsFixed(2)} km  ·  ${_formatDuration(run.durationS)}',
                        ),
                        subtitle: Text(
                          '${run.startedAt.toLocal().toString().substring(0, 16)}  ·  ${_formatPace(run)}',
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
