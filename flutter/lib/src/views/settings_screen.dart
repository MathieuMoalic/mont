import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/settings.dart';

const String kSmoothingKey = 'chart_smoothing';
const int kSmoothingDefault = 5;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _smoothing = kSmoothingDefault;
  final _keyController = TextEditingController();
  String? _keyError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final keyHex = await loadDeviceKeyHex();
    if (!mounted) return;
    setState(() {
      _smoothing = prefs.getInt(kSmoothingKey) ?? kSmoothingDefault;
      _keyController.text = keyHex ?? '';
    });
  }

  Future<void> _save(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kSmoothingKey, value);
  }

  Future<void> _saveKey() async {
    final hex = _keyController.text.trim();
    if (hex.isEmpty) {
      await clearBleSettings();
      if (mounted) setState(() => _keyError = null);
      return;
    }
    try {
      hexToBytes(hex); // validate
      await saveDeviceKeyHex(hex);
      if (mounted) setState(() => _keyError = null);
    } on FormatException catch (e) {
      if (mounted) setState(() => _keyError = e.message);
    }
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
          const Text('Watch', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          const Text(
            'Device key (32 hex chars). Find it via Gadgetbridge → Device Info, '
            'or extract it from the Zepp app data.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyController,
            decoration: InputDecoration(
              labelText: 'Device key (hex)',
              hintText: 'e.g. 0102030405060708090a0b0c0d0e0f10',
              errorText: _keyError,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Save key',
                onPressed: _saveKey,
              ),
            ),
            onSubmitted: (_) => _saveKey(),
            maxLength: 32,
          ),
        ],
      ),
    );
  }
}
