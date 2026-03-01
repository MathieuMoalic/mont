import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kSmoothingKey = 'chart_smoothing';
const int kSmoothingDefault = 5;

const String kRestTimerKey = 'rest_timer_seconds';
const int kRestTimerDefault = 90;

/// Formats [seconds] as "Mm SSs" (e.g. "1m 30s") or just "SSs" when < 60.
String fmtRestTime(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return m > 0 ? '${m}m ${s.toString().padLeft(2, '0')}s' : '${seconds}s';
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _smoothing = kSmoothingDefault;
  int _restTimer = kRestTimerDefault;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _smoothing = prefs.getInt(kSmoothingKey) ?? kSmoothingDefault;
      _restTimer = prefs.getInt(kRestTimerKey) ?? kRestTimerDefault;
    });
  }

  Future<void> _save(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kSmoothingKey, value);
  }

  Future<void> _saveRestTimer(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kRestTimerKey, value);
  }

  String _fmtRest(int s) => fmtRestTime(s);

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
          const SizedBox(height: 24),
          const Text('Workouts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Rest timer duration'),
              Text(_fmtRest(_restTimer), style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: _restTimer.toDouble(),
            min: 30,
            max: 300,
            divisions: 18, // 15s steps
            label: _fmtRest(_restTimer),
            onChanged: (v) {
              final rounded = (v / 15).round() * 15;
              setState(() => _restTimer = rounded);
              _saveRestTimer(rounded);
            },
          ),
          const Text(
            'Countdown starts automatically after each logged set',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
