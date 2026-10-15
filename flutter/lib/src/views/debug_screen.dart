import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../platform/ble_relay.dart' as ble;

/// Temporary tab to inspect what the BLE watch sync imported.
/// Not meant to be pretty — it will be removed once the import is trusted.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  Map<String, dynamic>? _debug;
  String? _error;
  bool _syncing = false;
  String? _lastSyncResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await api.getBleDebug();
      if (!mounted) return;
      setState(() {
        _debug = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _lastSyncResult = null;
    });
    try {
      final result = await ble.startManualSync();
      if (!mounted) return;
      setState(() => _lastSyncResult = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastSyncResult = 'error: $e');
    } finally {
      await _load();
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final debug = _debug;
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE debug'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _syncing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Syncing from watch… (keep the watch nearby)'),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  FilledButton.icon(
                    onPressed: _syncNow,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now (connect to watch)'),
                  ),
                  if (_lastSyncResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Last sync: $_lastSyncResult',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Error: $_error',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  if (debug == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _section('Sync state'),
                    ...(debug['syncState'] as List? ?? []).map(_tile),
                    _section('Activity samples'),
                    ListTile(
                      dense: true,
                      title: Text(
                        'count: ${debug['sampleRange']?['samples'] ?? 0}',
                      ),
                      subtitle: Text(
                        'first: ${debug['sampleRange']?['first'] ?? '—'}  '
                        'last: ${debug['sampleRange']?['last'] ?? '—'}',
                      ),
                    ),
                    _section('Daily health (last 14)'),
                    ...(debug['daily'] as List? ?? []).map(_tile),
                    _section('Resting / max HR marks'),
                    ...(debug['hrMarks'] as List? ?? []).map(_tile),
                    _section('HRV readings (last 50)'),
                    ...(debug['hrv'] as List? ?? []).map(_tile),
                    _section('Session recordings'),
                    ...(debug['sessions'] as List? ?? []).map(_tile),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _tile(Object? item) {
    if (item is Map) {
      return ListTile(
        dense: true,
        title: Text(
          item['date']?.toString() ??
              item['file']?.toString() ??
              'ts ${item['ts'] ?? '—'}',
        ),
        subtitle: Text(
          item.entries
              .where((e) => e.key != 'date' && e.key != 'file' && e.key != 'ts')
              .map((e) => '${e.key}: ${e.value}')
              .join('  '),
        ),
      );
    }
    return ListTile(dense: true, title: Text('$item'));
  }
}
