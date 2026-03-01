import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' as api;
import '../models.dart';
import 'settings_screen.dart';

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
  int _smoothing = kSmoothingDefault;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final run = await api.getRun(widget.runId);
      if (!mounted) return;
      setState(() {
        _run = run;
        _smoothing = prefs.getInt(kSmoothingKey) ?? kSmoothingDefault;
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
            child: ListView(
              children: [
                SizedBox(
                  height: 280,
                  child: points.isEmpty
                      ? const Center(child: Text('No route data'))
                      : FlutterMap(
                          options: MapOptions(
                            initialCameraFit: bounds != null
                                ? CameraFit.bounds(
                                    bounds: bounds,
                                    padding: const EdgeInsets.all(24))
                                : null,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'eu.matmoa.mont',
                            ),
                            PolylineLayer(polylines: [
                              Polyline(
                                  points: points,
                                  strokeWidth: 4,
                                  color: Colors.blue),
                            ]),
                          ],
                        ),
                ),
                if (_hasHr(run)) _hrChart(context, run),
                if (_hasPace(run)) _paceChart(context, run),
                if (_hasEle(run)) _eleChart(context, run),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static bool _hasHr(RunDetail run) =>
      run.route.any((p) => p.hr != null);
  static bool _hasPace(RunDetail run) =>
      run.route.length >= 2 && run.route.any((p) => p.t != null);
  static bool _hasEle(RunDetail run) =>
      run.route.any((p) => p.ele != null);

  // Cumulative distance in km for each point in the route
  static List<double> _cumKm(List<RunPoint> pts) {
    final out = <double>[0.0];
    for (int i = 1; i < pts.length; i++) {
      out.add(out.last +
          _haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon) /
              1000.0);
    }
    return out;
  }

  static String _fmtKm(double km) => '${km.toStringAsFixed(1)} km';

  Widget _hrChart(BuildContext context, RunDetail run) {
    final pts = run.route.where((p) => p.hr != null).toList();
    final km = _cumKm(pts);
    final spots = List.generate(pts.length,
        (i) => FlSpot(km[i], pts[i].hr!.toDouble()));
    return _chartCard(
      title: 'Heart rate (bpm)',
      color: Colors.red,
      spots: _smooth(spots, _smoothing),
      leftLabel: (v) => v.round().toString(),
      bottomLabel: _fmtKm,
    );
  }

  Widget _paceChart(BuildContext context, RunDetail run) {
    final pts = run.route.where((p) => p.t != null).toList();
    if (pts.length < 2) return const SizedBox.shrink();
    final km = _cumKm(pts);

    final List<FlSpot> spots = [];
    const windowSecs = 30;
    for (int i = 0; i < pts.length; i++) {
      int j = i;
      while (j > 0 && (pts[i].t! - pts[j].t!) < windowSecs) { j--; }
      if (j == i) continue;
      final dt = (pts[i].t! - pts[j].t!).toDouble();
      if (dt <= 0) continue;
      double dm = 0;
      for (int k = j; k < i; k++) {
        dm += _haversine(
          pts[k].lat, pts[k].lon, pts[k + 1].lat, pts[k + 1].lon);
      }
      if (dm < 1) continue;
      final paceMinKm = (dt / dm) * (1000 / 60);
      if (paceMinKm > 20 || paceMinKm < 2) continue;
      spots.add(FlSpot(km[i], paceMinKm));
    }
    if (spots.isEmpty) return const SizedBox.shrink();

    return _chartCard(
      title: 'Pace (min/km)',
      color: Colors.blue,
      spots: _smooth(spots, _smoothing),
      leftLabel: (v) {
        final m = v.floor();
        final s = ((v - m) * 60).round();
        return "$m:${s.toString().padLeft(2, '0')}";
      },
      bottomLabel: _fmtKm,
      flipY: true,
    );
  }

  Widget _eleChart(BuildContext context, RunDetail run) {
    final pts = run.route.where((p) => p.ele != null).toList();
    final km = _cumKm(pts);
    final spots = List.generate(pts.length,
        (i) => FlSpot(km[i], pts[i].ele!));
    return _chartCard(
      title: 'Elevation (m)',
      color: Colors.green,
      spots: _smooth(spots, _smoothing),
      leftLabel: (v) => v.round().toString(),
      bottomLabel: _fmtKm,
    );
  }


  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dlat = (lat2 - lat1) * math.pi / 180;
    final dlon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dlat / 2) * math.sin(dlat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dlon / 2) *
            math.sin(dlon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  // Simple centred moving average over k points
  static List<FlSpot> _smooth(List<FlSpot> spots, int k) {
    if (k <= 1 || spots.length < k) return spots;
    final half = k ~/ 2;
    final out = <FlSpot>[];
    for (int i = 0; i < spots.length; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(spots.length - 1, i + half);
      final avg = spots.sublist(lo, hi + 1).map((s) => s.y).reduce((a, b) => a + b) / (hi - lo + 1);
      out.add(FlSpot(spots[i].x, avg));
    }
    return out;
  }

  Widget _chartCard({
    required String title,
    required Color color,
    required List<FlSpot> spots,
    required String Function(double) leftLabel,
    required String Function(double) bottomLabel,
    bool flipY = false,
  }) {
    final ys = spots.map((s) => s.y).toList();
    final minY = ys.fold(double.infinity, math.min);
    final maxY = ys.fold(double.negativeInfinity, math.max);
    final pad = math.max((maxY - minY) * 0.1, 1.0);
    final xs = spots.map((s) => s.x).toList();
    final maxX = xs.fold(0.0, math.max);
    // Pick a round interval so we get ~5 ticks
    final rawInterval = maxX / 5;
    final interval = rawInterval <= 0.5 ? 0.5
        : rawInterval <= 1.0 ? 1.0
        : rawInterval <= 2.0 ? 2.0
        : rawInterval <= 5.0 ? 5.0
        : 10.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
              ),
              SizedBox(
                height: 160,
                child: LineChart(LineChartData(
                  minY: flipY ? minY - pad : minY - pad,
                  maxY: flipY ? maxY + pad : maxY + pad,
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) => spots
                          .map((s) => LineTooltipItem(
                                leftLabel(s.y),
                                const TextStyle(fontSize: 12),
                              ))
                          .toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: color,
                      dotData: const FlDotData(show: false),
                      barWidth: 2,
                      belowBarData: BarAreaData(
                        show: true,
                        color: color.withValues(alpha: 0.12),
                      ),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (v, _) => Text(leftLabel(v),
                            style: const TextStyle(fontSize: 9)),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 20,
                        interval: interval,
                        getTitlesWidget: (v, _) => Text(bottomLabel(v),
                            style: const TextStyle(fontSize: 9)),
                      ),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  gridData: const FlGridData(show: true),
                  borderData: FlBorderData(show: false),
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
