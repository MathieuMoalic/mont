import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart' as api;

// ── HeatmapLayer ──────────────────────────────────────────────────────────────
//
// Approach: additive blending (BlendMode.plus). Each route contributes a dark
// blue stroke; overlapping areas accumulate colour toward cyan → white.  No
// isolate, no pixel-buffer round-trip — Flutter's GPU canvas handles it all.
//
// Pan  → instant: we just shift the canvas origin by the camera delta.
// Zoom → reproject screen coords (synchronous, no isolate), debounced 80 ms.

class HeatmapLayer extends StatefulWidget {
  const HeatmapLayer({super.key, required this.routes});
  final List<List<LatLng>> routes;

  @override
  State<HeatmapLayer> createState() => _HeatmapLayerState();
}

class _HeatmapLayerState extends State<HeatmapLayer> {
  List<List<Offset>>? _screenRoutes;
  MapCamera? _renderCamera;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Project lat/lng → screen coords for the current camera (synchronous).
  void _reproject(MapCamera camera) {
    _screenRoutes = widget.routes
        .map((r) => r.map((ll) => camera.latLngToScreenOffset(ll)).toList())
        .toList();
    _renderCamera = camera;
  }

  void _scheduleReproject(MapCamera camera) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      setState(() => _reproject(camera));
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);

      // Reproject if this is the first build or the zoom changed.
      final rc = _renderCamera;
      if (rc == null || (camera.zoom - rc.zoom).abs() > 0.15) {
        _scheduleReproject(camera);
      }

      // Pan offset: how much every screen-coord has shifted since last render.
      Offset panOffset = Offset.zero;
      if (rc != null) {
        panOffset = camera.latLngToScreenOffset(rc.center) -
            Offset(size.width / 2, size.height / 2);
      }

      return CustomPaint(
        painter: _HeatmapPainter(_screenRoutes, panOffset),
        size: size,
        isComplex: true,
        willChange: false,
      );
    });
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<List<Offset>>? routes;
  final Offset panOffset;

  const _HeatmapPainter(this.routes, this.panOffset);

  @override
  void paint(Canvas canvas, Size size) {
    final routes = this.routes;
    if (routes == null || routes.isEmpty) return;

    canvas.save();
    canvas.translate(panOffset.dx, panOffset.dy);

    // Offscreen layer with additive blend: overlapping routes brighten toward
    // white (dark-blue → blue → cyan → white as density increases).
    canvas.saveLayer(
      Rect.fromLTWH(-size.width, -size.height, size.width * 3, size.height * 3),
      Paint(),
    );

    // Wide halo pass: broad, very dim.
    final haloPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.plus
      // alpha=18: single route ≈ 7% opacity; ~14 overlaps → fully saturated
      ..color = const Color(0x1200061A); // (a=18, r=0, g=6, b=26)

    // Narrow core pass: brighter centre.
    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.plus
      ..color = const Color(0x1C000E34); // (a=28, r=0, g=14, b=52)

    for (final route in routes) {
      if (route.length < 2) continue;
      final path = ui.Path()..moveTo(route[0].dx, route[0].dy);
      for (int i = 1; i < route.length; i++) {
        path.lineTo(route[i].dx, route[i].dy);
      }
      canvas.drawPath(path, haloPaint);
      canvas.drawPath(path, corePaint);
    }

    canvas.restore(); // saveLayer
    canvas.restore(); // translate
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.routes != routes || old.panOffset != panOffset;
}

// ── Screen ────────────────────────────────────────────────────────────────────

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
        _routes = raw.map((r) => r.map((pt) => LatLng(pt[0], pt[1])).toList()).toList();
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
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'eu.matmoa.mont',
                        ),
                        HeatmapLayer(routes: _routes!),
                      ],
                    ),
    );
  }
}

