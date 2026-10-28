import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' as api;
import '../ble/ble_relay_io.dart' as ble_relay;
import '../platform/gpx_picker.dart' show pickGpxFile;
import '../platform/map_zip_saver.dart' show saveMapZip;
import '../watch_map_install.dart' show WatchMapInstaller;
import 'watch_transfer_section.dart' show kHotspotPasswordKey, kHotspotSsidKey;

/// GPX route upload to the watch runs over BLE — Android/iOS only.
bool get _bleSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

const List<({String value, String label})> _styles = [
  (value: 'cheetah-topo', label: 'CheetahTopo (Amazfit hiking)'),
  (value: 'default', label: 'Default (generic)'),
];

/// Build Zepp OS watch map tiles (`11/<x>/<y>.img`) from a GPX route and
/// download them as a ZIP, ready for `/mnt/data/map/` on the watch.
class WatchMapsScreen extends StatefulWidget {
  const WatchMapsScreen({super.key});

  @override
  State<WatchMapsScreen> createState() => _WatchMapsScreenState();
}

class _WatchMapsScreenState extends State<WatchMapsScreen> {
  final TextEditingController _bufferCtrl = TextEditingController(text: '1.0');
  final TextEditingController _overlapCtrl = TextEditingController(
    text: '0.002',
  );
  final ScrollController _logScroll = ScrollController();

  bool? _serverReady;
  ({List<int> bytes, String name})? _gpx;
  String _style = 'cheetah-topo';
  bool _refreshOsm = false;
  String? _sendError;

  String? _jobId;
  String _status = 'idle'; // idle | queued | running | done | error
  final List<String> _logs = [];
  bool _downloading = false;
  bool _uploading = false;
  bool _sending = false;
  bool _autoUpload = false; // build-then-upload ("with tiles" button)
  Uint8List? _zipBytes;
  Timer? _pollTimer;

  /// Sends the picked GPX to the watch over BLE (file-transfer service).
  /// The route appears in the watch's workout routes list.
  Future<void> _sendRoute() async {
    final gpx = _gpx;
    if (gpx == null || _sending || _jobActive) return;
    setState(() {
      _sending = true;
      _sendError = null;
      _logs.add('Sending route to watch over BLE…');
    });
    try {
      final name = gpx.name.replaceFirst(
        RegExp(r'\.gpx$', caseSensitive: false),
        '',
      );
      final outcome = await ble_relay.runTransferSession(
        actions: [
          {'k': 'file_send', 'name': name, 'data': base64Encode(gpx.bytes)},
        ],
      );
      final results =
          (outcome['controls_results'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [];
      for (final r in results) {
        if (r['status'] != 'ok') {
          throw Exception(r['error'] ?? r['status'] ?? 'failed');
        }
      }
      if (!mounted) return;
      setState(() => _sending = false);
      _log('Route sent ✓ — check the watch routes list');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = 'Send failed: $e';
      });
    }
  }

  /// Appends a line to the on-screen progress log.
  void _log(String line) {
    setState(() => _logs.add(line));
    _scrollLogToBottom();
  }

  @override
  void initState() {
    super.initState();
    _checkReady();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _bufferCtrl.dispose();
    _overlapCtrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _checkReady() async {
    try {
      final ready = await api.mapsReady();
      if (!mounted) return;
      setState(() => _serverReady = ready);
    } catch (_) {
      if (!mounted) return;
      setState(() => _serverReady = false);
    }
  }

  Future<void> _pickGpx() async {
    final picked = await pickGpxFile();
    if (!mounted) return;
    setState(() => _gpx = picked);
  }

  bool get _jobActive => _status == 'queued' || _status == 'running';

  /// "With map tiles" — builds the tile set, then auto-installs it on the
  /// watch (hotspot + FTP). Needs the hotspot credentials from Settings.
  Future<void> _buildAndUpload() async {
    if (_gpx == null || _jobActive || _uploading || _sending) return;
    final prefs = await SharedPreferences.getInstance();
    final ssid = (prefs.getString(kHotspotSsidKey) ?? '').trim();
    final password = prefs.getString(kHotspotPasswordKey) ?? '';
    if (ssid.isEmpty || password.length < 8) {
      setState(() {
        _sendError =
            'Set the hotspot name and password first (Advanced → Watch Wi-Fi)';
      });
      return;
    }
    setState(() {
      _sendError = null;
      _autoUpload = true;
    });
    await _startJob();
  }

  Future<void> _startJob() async {
    final gpx = _gpx;
    if (gpx == null || _jobActive) return;
    final double bufferKm;
    final double overlapDegrees;
    try {
      bufferKm = double.parse(_bufferCtrl.text.trim());
      overlapDegrees = double.parse(_overlapCtrl.text.trim());
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buffer and overlap must be numbers')),
      );
      return;
    }
    setState(() {
      _logs.clear();
      _logs.add('Uploading ${gpx.name}...');
      _status = 'queued';
    });
    try {
      final jobId = await api.startMapJob(
        gpx.bytes,
        gpx.name,
        style: _style,
        bufferKm: bufferKm,
        overlapDegrees: overlapDegrees,
        refreshOsm: _refreshOsm,
      );
      if (!mounted) return;
      setState(() => _jobId = jobId);
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
      await _poll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _logs.add('Error: $e');
      });
    }
  }

  Future<void> _poll() async {
    final jobId = _jobId;
    if (jobId == null) return;
    try {
      final job = await api.getMapJob(jobId);
      if (!mounted) return;
      final status = (job['status'] ?? '').toString();
      final logs = ((job['logs'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      setState(() {
        _status = status;
        _logs
          ..clear()
          ..addAll(logs);
      });
      _scrollLogToBottom();
      if (status == 'done' || status == 'error') {
        _pollTimer?.cancel();
      }
      if (status == 'done' && _autoUpload) {
        _autoUpload = false;
        unawaited(_uploadToWatch());
      }
    } catch (_) {
      // Transient network hiccup: keep polling until the job resolves.
    }
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _download() async {
    final jobId = _jobId;
    if (jobId == null || _downloading) return;
    setState(() => _downloading = true);
    try {
      final bytes = await api.downloadMapZip(jobId);
      await saveMapZip(bytes, '11.zip');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Saved 11.zip — copy it to /mnt/data/map/ on the watch',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Downloads the built ZIP (consuming the job) and installs it onto the
  /// watch: hotspot + FTP over BLE, join the watch Wi-Fi, FTP-upload.
  Future<void> _uploadToWatch() async {
    final jobId = _jobId;
    if (jobId == null || _uploading || !WatchMapInstaller.isSupported) return;
    final prefs = await SharedPreferences.getInstance();
    final ssid = (prefs.getString(kHotspotSsidKey) ?? '').trim();
    final password = prefs.getString(kHotspotPasswordKey) ?? '';
    if (ssid.isEmpty || password.length < 8) {
      setState(() {
        _sendError =
            'Set the hotspot name and password first (Advanced → Watch Wi-Fi)';
      });
      _log(
        'Set the hotspot name and password in Settings → Watch transfer first',
      );
      return;
    }

    setState(() => _uploading = true);
    try {
      _log('Downloading built tiles…');
      _zipBytes = await api.downloadMapZip(jobId);
      await WatchMapInstaller.installFromZip(
        zipBytes: _zipBytes!,
        ssid: ssid,
        password: password,
        log: _log,
      );
      _log('Map installed ✓ — check the watch map app');
    } catch (e) {
      _log('Upload failed: $e');
      // The job's download was consumed; a new build is needed to retry.
      setState(() => _status = 'error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _logPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(minHeight: 96, maxHeight: 260),
      child: SingleChildScrollView(
        controller: _logScroll,
        child: Text(
          _logs.isEmpty ? 'Idle.' : _logs.join('\n'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _serverReady;
    final idle = !_jobActive && !_uploading && !_sending;
    Widget spinner() => const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Watch maps')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (ready == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.route_outlined),
              title: Text(_gpx?.name ?? 'No GPX selected'),
              subtitle: const Text('Pick a GPX route to upload'),
              trailing: TextButton(
                onPressed: _pickGpx,
                child: const Text('Pick'),
              ),
            ),
            if (ready == false)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Map tile builds are not available on this server '
                  '(needs MONT_MKGMAP_JAR + java/osmium) — route-only '
                  'upload still works.',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            const SizedBox(height: 4),
            if (WatchMapInstaller.isSupported) ...[
              FilledButton.icon(
                onPressed: (_gpx != null && idle && ready == true)
                    ? _buildAndUpload
                    : null,
                icon: (_jobActive || _uploading)
                    ? spinner()
                    : const Icon(Icons.map_outlined),
                label: Text(
                  _jobActive
                      ? 'Building tiles…'
                      : _uploading
                      ? 'Uploading tiles…'
                      : 'Upload with map tiles',
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_bleSupported) ...[
              FilledButton.tonalIcon(
                onPressed: (_gpx != null && idle) ? _sendRoute : null,
                icon: _sending
                    ? spinner()
                    : const Icon(Icons.navigation_outlined),
                label: Text(
                  _sending ? 'Sending route…' : 'Upload route only (no tiles)',
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (!WatchMapInstaller.isSupported && !_bleSupported)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Route upload needs an Android or iOS device. On the web you '
                  'can still build tiles and download the ZIP (Advanced).',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            if (_sendError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _sendError!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            const SizedBox(height: 8),
            ExpansionTile(
              initiallyExpanded: false,
              childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
              title: const Text('Advanced'),
              subtitle: const Text(
                'Tile settings, manual transfer, Wi-Fi, logs',
              ),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _style,
                  decoration: const InputDecoration(labelText: 'Map style'),
                  items: _styles
                      .map(
                        (s) => DropdownMenuItem(
                          value: s.value,
                          child: Text(s.label),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _style = v);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _bufferCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Buffer km',
                          hintText: 'Padding around the route',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        enabled: !_jobActive,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _overlapCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Overlap degrees',
                          hintText: 'Per-tile extraction padding',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        enabled: !_jobActive,
                      ),
                    ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Refresh OSM cache'),
                  subtitle: const Text(
                    'Re-download Geofabrik data instead of using the cache',
                  ),
                  value: _refreshOsm,
                  onChanged: _jobActive
                      ? null
                      : (v) => setState(() => _refreshOsm = v ?? false),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: (_gpx != null && !_jobActive) ? _startJob : null,
                  icon: const Icon(Icons.build_outlined),
                  label: Text(
                    _jobActive ? 'Building...' : 'Generate tiles only',
                  ),
                ),
                if (_status == 'done') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: (_downloading || _uploading || _zipBytes != null)
                        ? null
                        : _download,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download 11.zip'),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The built ZIP is single-use — start a new build to '
                    'transfer or download again.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 12),
                _logPanel(),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
