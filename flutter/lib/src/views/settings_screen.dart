import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' as api;
import '../auth.dart';
import 'login_page.dart';
import 'watch_maps_screen.dart';
import 'watch_transfer_section.dart';

const String kSmoothingKey = 'chart_smoothing';
const int kSmoothingDefault = 5;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _smoothing = kSmoothingDefault;
  String? _clientVersion;
  String? _serverVersion;
  List<Map<String, dynamic>>? _bleLog;
  bool _bleLogLoading = false;
  bool? _mapsReady;

  @override
  void initState() {
    super.initState();
    _load();
    _loadBleLog();
    _loadMapsReady();
  }

  Future<void> _loadMapsReady() async {
    try {
      final ready = await api.mapsReady();
      if (!mounted) return;
      setState(() => _mapsReady = ready);
    } catch (_) {
      if (!mounted) return;
      setState(() => _mapsReady = false);
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();
    String? serverVersion;
    try {
      serverVersion = await api.fetchBackendVersion();
    } catch (_) {
      serverVersion = 'unavailable';
    }
    if (!mounted) return;
    setState(() {
      _smoothing = prefs.getInt(kSmoothingKey) ?? kSmoothingDefault;
      _clientVersion = packageInfo.version;
      _serverVersion = serverVersion;
    });
  }

  Future<void> _save(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kSmoothingKey, value);
  }

  Future<void> _loadBleLog() async {
    setState(() => _bleLogLoading = true);
    try {
      final entries = await api.getBleSyncLog(limit: 20);
      if (!mounted) return;
      setState(() => _bleLog = entries.cast<Map<String, dynamic>>());
    } catch (_) {
      // BLE sync not available (disabled or old server): hide the section.
      if (!mounted) return;
      setState(() => _bleLog = null);
    } finally {
      if (mounted) setState(() => _bleLogLoading = false);
    }
  }

  Future<void> _logIssue() async {
    String message = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log an issue'),
        content: TextFormField(
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'What went wrong?',
            hintText: 'Steps, expected vs actual, anything helpful...',
          ),
          onChanged: (v) => message = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    message = message.trim();
    if (ok != true || message.isEmpty || !mounted) return;

    final platform = kIsWeb
        ? 'web'
        : defaultTargetPlatform.toString().split('.').last;

    try {
      await api.createIssueReport(
        message: message,
        clientVersion: _clientVersion,
        serverVersion: _serverVersion,
        platform: platform,
        baseUrl: api.baseUrl,
        route: 'settings',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Issue saved. Thanks!')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save issue: $e')));
    }
  }

  void _showIssues() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        bool loading = false;
        String? error;
        List<Map<String, dynamic>>? issues;

        Future<void> refresh(
          void Function(void Function()) setModalState,
        ) async {
          setModalState(() {
            loading = true;
            error = null;
          });
          try {
            final res = await api.listIssueReports(limit: 50, offset: 0);
            setModalState(() => issues = res);
          } catch (e) {
            setModalState(() => error = e.toString());
          } finally {
            setModalState(() => loading = false);
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            if (issues == null && !loading && error == null) {
              // Kick off initial load once the sheet is built.
              Future.microtask(() => refresh(setModalState));
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Issue reports',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: loading
                              ? null
                              : () => refresh(setModalState),
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('Failed to load: $error'),
                      )
                    else
                      Expanded(
                        child: ListView.separated(
                          itemCount: (issues ?? const []).length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = issues![i];
                            final createdAt = (r['created_at'] ?? '')
                                .toString();
                            final message = (r['message'] ?? '').toString();
                            final platform = (r['platform'] ?? '').toString();
                            return ListTile(
                              title: Text(
                                message,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if (createdAt.isNotEmpty) createdAt,
                                  if (platform.isNotEmpty) platform,
                                ].join(' • '),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _logout() async {
    await Auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  static const _months = [
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

  String _bleLogTime(String ts) {
    final t = DateTime.tryParse(ts)?.toLocal();
    if (t == null) return ts;
    return '${_months[t.month - 1]} ${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  (IconData, String) _bleLogKind(String kind, int stored, bool isError) {
    if (isError) return (Icons.error_outline, 'Sync problem ($kind)');
    return switch (kind) {
      'workout' => (Icons.directions_run, 'Run imported'),
      'sleep_session' => (Icons.bedtime_outlined, 'Sleep · $stored nights'),
      'activity' => (Icons.directions_walk, 'Activity · $stored min'),
      'hrv' => (Icons.favorite_outline, 'HRV · $stored samples'),
      'stress' => (Icons.bolt, 'Stress · $stored samples'),
      'max_hr' => (Icons.speed, 'Max HR · $stored marks'),
      'resting_hr' => (Icons.monitor_heart, 'Resting HR · $stored marks'),
      _ => (Icons.sync, 'Sync'),
    };
  }

  Widget _bleLogTile(Map<String, dynamic> e) {
    final kind = (e['kind'] ?? '').toString();
    final status = (e['status'] ?? '').toString();
    final stored = (e['stored'] as num?)?.toInt() ?? 0;
    final detail = (e['detail'] ?? '').toString();
    final source = (e['source'] ?? '').toString();
    final isError = status != 'ok';
    final (icon, title) = _bleLogKind(kind, stored, isError);
    final subtitle = [
      _bleLogTime((e['ts'] ?? '').toString()),
      if (detail.isNotEmpty) detail,
      if (source.isNotEmpty && source != 'sync') source,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, color: isError ? Colors.redAccent : null),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Widget _bleLogSection() {
    final log = _bleLog ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Watch sync',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _bleLogLoading ? null : _loadBleLog,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (log.isEmpty)
          const Text(
            'No sync history yet',
            style: TextStyle(color: Colors.grey),
          )
        else
          for (final e in log) _bleLogTile(e),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_mapsReady == true) ...[
            const Text(
              'Watch maps',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.map_outlined),
              title: const Text('Watch maps'),
              subtitle: const Text(
                'Upload a GPX route to the watch — with or without map tiles',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WatchMapsScreen()),
              ),
            ),
            const SizedBox(height: 32),
          ],
          if (_bleLog != null) ...[
            const SizedBox(height: 8),
            ExpansionTile(
              leading: const Icon(Icons.wifi_tethering_outlined),
              title: const Text('Watch Wi-Fi / FTP'),
              subtitle: const Text('Manual hotspot & transfer controls'),
              children: const [WatchTransferSection()],
            ),
            const SizedBox(height: 24),
          ],
          const Text(
            'Charts',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Smoothing (k points)'),
              Text(
                '$_smoothing',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Slider(
            value: _smoothing.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$_smoothing',
            onChanged: (v) {
              setState(() => _smoothing = v.round());
              _save(v.round());
            },
          ),
          Text(
            _smoothing == 1
                ? 'No smoothing — raw data'
                : 'Each point is the average of $_smoothing consecutive measurements',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 32),
          const Text(
            'Support',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Log an issue'),
            subtitle: const Text('Sends a report to the server database'),
            onTap: _logIssue,
          ),
          if (kDebugMode)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Issue inbox (debug)'),
              subtitle: const Text('View latest reports from the server'),
              onTap: _showIssues,
            ),
          if (_bleLog != null) _bleLogSection(),
          const SizedBox(height: 32),
          const Text(
            'About',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Client version'),
              Text(
                _clientVersion ?? '...',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Server version'),
              Text(
                _serverVersion ?? '...',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: _logout,
          ),
        ],
      ),
    );
  }
}
