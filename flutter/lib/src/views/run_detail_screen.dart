import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart' as api;
import '../models.dart';

class RunDetailScreen extends StatefulWidget {
  const RunDetailScreen({super.key, required this.runId});

  final int runId;

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  RunDetail? _run;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final run = await api.getRun(widget.runId);
      if (!mounted) return;
      setState(() {
        _run = run;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _run == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_error ?? 'Unknown error')),
      );
    }

    final run = _run!;
    final points = run.route.map((p) => LatLng(p.lat, p.lon)).toList();

    // Compute map bounds
    final lats = points.map((p) => p.latitude).toList();
    final lons = points.map((p) => p.longitude).toList();
    final bounds = points.isEmpty
        ? null
        : LatLngBounds(
            LatLng(lats.reduce((a, b) => a < b ? a : b),
                lons.reduce((a, b) => a < b ? a : b)),
            LatLng(lats.reduce((a, b) => a > b ? a : b),
                lons.reduce((a, b) => a > b ? a : b)),
          );

    final pace = run.distanceM > 0
        ? () {
            final sPerKm = run.durationS / (run.distanceM / 1000);
            final m = sPerKm ~/ 60;
            final s = (sPerKm % 60).round();
            return "$m'${s.toString().padLeft(2, '0')}\"";
          }()
        : '--';

    return Scaffold(
      appBar: AppBar(
        title: Text(run.startedAt.toLocal().toString().substring(0, 10)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await api.deleteRun(run.id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('Distance', '${(run.distanceM / 1000).toStringAsFixed(2)} km'),
                _stat('Duration', _formatDuration(run.durationS)),
                _stat('Pace', pace),
                if (run.elevationGainM != null)
                  _stat('Elev.', '+${run.elevationGainM!.round()} m'),
                if (run.avgHr != null)
                  _stat('Avg HR', '${run.avgHr} bpm'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: points.isEmpty
                ? const Center(child: Text('No route data'))
                : FlutterMap(
                    options: MapOptions(
                      initialCameraFit: bounds != null
                          ? CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(24))
                          : null,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'eu.matmoa.mont',
                      ),
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: points,
                            strokeWidth: 4,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
