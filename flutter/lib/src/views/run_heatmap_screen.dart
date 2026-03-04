import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart' as api;

class RunHeatmapScreen extends StatefulWidget {
  const RunHeatmapScreen({super.key});

  @override
  State<RunHeatmapScreen> createState() => _RunHeatmapScreenState();
}

class _RunHeatmapScreenState extends State<RunHeatmapScreen> {
  List<List<LatLng>>? _routes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await api.fetchHeatmap();
      if (!mounted) return;
      setState(() {
        _routes = raw
            .map((r) => r.map((pt) => LatLng(pt[0], pt[1])).toList())
            .toList();
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

  LatLngBounds? _bounds() {
    final routes = _routes;
    if (routes == null || routes.isEmpty) return null;
    double minLat = double.infinity,
        maxLat = double.negativeInfinity,
        minLon = double.infinity,
        maxLon = double.negativeInfinity;
    for (final route in routes) {
      for (final p in route) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
    }
    return LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run Heatmap')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _routes!.isEmpty
                  ? const Center(child: Text('No runs with GPS data yet.'))
                  : FlutterMap(
                      options: MapOptions(
                        initialCameraFit: _bounds() != null
                            ? CameraFit.bounds(
                                bounds: _bounds()!,
                                padding: const EdgeInsets.all(32),
                              )
                            : null,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'eu.matmoa.mont',
                        ),
                        PolylineLayer(
                          polylines: _routes!
                              .map((pts) => Polyline(
                                    points: pts,
                                    strokeWidth: 2.5,
                                    color: Colors.blue.withValues(alpha: 0.35),
                                  ))
                              .toList(),
                        ),
                      ],
                    ),
    );
  }
}
