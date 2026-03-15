import 'package:flutter/material.dart';

import '../ble/watch_sync_service.dart';

class WatchSyncScreen extends StatefulWidget {
  const WatchSyncScreen({super.key});

  @override
  State<WatchSyncScreen> createState() => _WatchSyncScreenState();
}

class _WatchSyncScreenState extends State<WatchSyncScreen> {
  final WatchSyncService _service = WatchSyncService();

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _startSync() async {
    await _service.sync();
  }

  Future<void> _startQuickSync() async {
    await _service.sync(maxRuns: 5);
  }

  void _cancel() => _service.cancel();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync Watch')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(status: _service.status, message: _service.message),
            const SizedBox(height: 24),
            if (_service.status == SyncStatus.done)
              _DoneCard(syncedCount: _service.syncedCount),
            if (_service.status == SyncStatus.error)
              _ErrorCard(error: _service.lastError ?? 'Unknown error'),
            const Spacer(),
            if (_service.isRunning)
              OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop),
                label: const Text('Cancel'),
              )
            else ...[
              FilledButton.icon(
                onPressed: _startSync,
                icon: const Icon(Icons.sync),
                label: const Text('Sync Now'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _startQuickSync,
                icon: const Icon(Icons.fast_forward),
                label: const Text('Quick Sync (5 runs)'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.message});

  final SyncStatus status;
  final String message;

  IconData get _icon => switch (status) {
        SyncStatus.idle => Icons.watch_outlined,
        SyncStatus.requestingPermissions => Icons.security,
        SyncStatus.scanning => Icons.bluetooth_searching,
        SyncStatus.connecting => Icons.bluetooth_connected,
        SyncStatus.authenticating => Icons.lock_outline,
        SyncStatus.syncing => Icons.cloud_upload_outlined,
        SyncStatus.done => Icons.check_circle_outline,
        SyncStatus.error => Icons.error_outline,
      };

  Color _color(BuildContext context) => switch (status) {
        SyncStatus.done => Colors.green,
        SyncStatus.error => Theme.of(context).colorScheme.error,
        _ => Theme.of(context).colorScheme.primary,
      };

  @override
  Widget build(BuildContext context) {
    final bool busy = status != SyncStatus.idle &&
        status != SyncStatus.done &&
        status != SyncStatus.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (busy)
              const CircularProgressIndicator()
            else
              Icon(_icon, size: 48, color: _color(context)),
            const SizedBox(height: 16),
            Text(
              message.isEmpty ? 'Ready to sync' : message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneCard extends StatelessWidget {
  const _DoneCard({required this.syncedCount});

  final int syncedCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 12),
            Text('$syncedCount ${syncedCount == 1 ? 'activity' : 'activities'} uploaded'),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
