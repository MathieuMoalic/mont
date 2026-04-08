import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' as api;

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

  @override
  void initState() {
    super.initState();
    _load();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Charts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Smoothing (k points)'),
              Text('$_smoothing', style: const TextStyle(fontWeight: FontWeight.bold)),
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
          const Text('About', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Client version'),
              Text(_clientVersion ?? '...', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Server version'),
              Text(_serverVersion ?? '...', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}
