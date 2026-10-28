import 'package:flutter/material.dart';

import '../platform/kv_store.dart' as kv;
import '../platform/ble_relay.dart' as ble_relay;

// Shared with the maps screen (its upload flow reads the same credentials).
const String kHotspotSsidKey = 'watch_hotspot_ssid';
const String kHotspotPasswordKey = 'watch_hotspot_password';

/// "Watch transfer" controls: toggles the watch's Wi-Fi hotspot and FTP
/// server (what Gadgetbridge used to do before dropping the Cheetah Pro
/// capability). After starting, the phone joins the watch's Wi-Fi and any
/// FTP app can copy files (maps live under `map/res/scl/`).
class WatchTransferSection extends StatefulWidget {
  const WatchTransferSection({super.key});

  @override
  State<WatchTransferSection> createState() => _WatchTransferSectionState();
}

class _WatchTransferSectionState extends State<WatchTransferSection> {
  final TextEditingController _ssidCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _ftpAddress;
  String? _ftpUsername;
  String? _stateLine;

  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCredentials() async {
    final ssid = await kv.getString(kHotspotSsidKey);
    final password = await kv.getString(kHotspotPasswordKey);
    if (!mounted) return;
    setState(() {
      _ssidCtrl.text = ssid ?? '';
      _passwordCtrl.text = password ?? '';
    });
  }

  Future<void> _saveCredentials() async {
    await kv.setString(kHotspotSsidKey, _ssidCtrl.text.trim());
    await kv.setString(kHotspotPasswordKey, _passwordCtrl.text);
  }

  Future<void> _run(List<Map<String, dynamic>> actions) async {
    if (_busy) return;
    await _saveCredentials();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final starting = actions.first['k'] == 'hotspot_start';
      final Map<String, dynamic> outcome;
      if (starting) {
        // Held session: the watch keeps the hotspot up only while this BLE
        // link is alive, so the session is held open until Stop.
        outcome = await ble_relay.startHeldWatchTransfer(actions: actions);
      } else if (ble_relay.activeWatchTransfer?.isAlive ?? false) {
        outcome = await ble_relay.activeWatchTransfer!.release(actions);
      } else {
        outcome = await ble_relay.runTransferSession(actions: actions);
      }
      final results =
          (outcome['controls_results'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [];
      String? stateLine;
      String? address;
      String? username;
      for (final r in results) {
        if (r['status'] != 'ok') {
          final err = r['error'] ?? r['status'] ?? 'failed';
          await _fail('${r['action'] ?? 'action'}: $err');
          return;
        }
        if (r['address'] != null) address = r['address'] as String;
        if (r['username'] != null) username = r['username'] as String;
        if (r['state'] != null) stateLine = r['state'] as String;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ftpAddress = starting ? address : null;
        _ftpUsername = starting ? username : null;
        _stateLine = stateLine;
      });
    } catch (e) {
      await _fail('$e');
    }
  }

  Future<void> _fail(String message) async {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ssid = _ssidCtrl.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ssidCtrl,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Hotspot name (SSID)',
            hintText: 'Shown on the phone when you search for Wi-Fi',
          ),
        ),
        TextField(
          controller: _passwordCtrl,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Hotspot password (min 8 chars)',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    (_busy ||
                        _ssidCtrl.text.trim().isEmpty ||
                        _passwordCtrl.text.length < 8)
                    ? null
                    : () => _run([
                        {
                          'k': 'hotspot_start',
                          'ssid': _ssidCtrl.text.trim(),
                          'password': _passwordCtrl.text,
                        },
                        {'k': 'ftp_start', 'root_dir': '/mnt/data'},
                      ]),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Start hotspot & FTP'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run([
                      {'k': 'ftp_stop'},
                      {'k': 'hotspot_stop'},
                    ]),
              icon: const Icon(Icons.wifi_tethering_off),
              label: const Text('Stop'),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        if (_ftpAddress != null) ...[
          const SizedBox(height: 12),
          Text(
            'Watch FTP is up: $_ftpAddress · user $_ftpUsername · empty password',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            '1. Join the Wi-Fi "$ssid" on this phone\n'
            '2. Open an FTP app and connect to $_ftpAddress '
            '(user $_ftpUsername, no password)\n'
            '3. Copy the 11 folder to map/res/scl/\n'
            'Keep this app open while copying — the hotspot goes down when '
            'the connection to the watch does (or after 15 min).',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ] else if (_stateLine == 'stopped')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Watch hotspot and FTP stopped.'),
          ),
      ],
    );
  }
}
