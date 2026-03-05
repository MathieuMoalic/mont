import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart' as api;

// ── Heatmap computation (top-level so it can run in a compute isolate) ────────

const int _kCellSize = 4; // pixels per density-grid cell

typedef _HeatmapInput = ({
  List<List<List<double>>> routes, // [[x,y], …] already in screen-space
  int width,
  int height,
});

/// Builds an RGBA pixel buffer (cols×rows) representing the density heatmap.
Uint32List _buildDensityGrid(_HeatmapInput input) {
  final cols = (input.width / _kCellSize).ceil();
  final rows = (input.height / _kCellSize).ceil();
  final density = Float32List(cols * rows);

  // Gaussian kernel – radius 2 cells, σ = 4/3
  const kr = 2;
  const sigma = kr / 1.5;
  const ks = kr * 2 + 1;
  final kernel = List.generate(ks, (dy) => List.generate(ks, (dx) {
    final x = (dx - kr).toDouble(), y = (dy - kr).toDouble();
    return math.exp(-(x * x + y * y) / (2 * sigma * sigma));
  }));

  for (final route in input.routes) {
    for (final pt in route) {
      final px = pt[0], py = pt[1];
      if (px < -kr * _kCellSize || py < -kr * _kCellSize ||
          px > input.width + kr * _kCellSize ||
          py > input.height + kr * _kCellSize) { continue; }
      final cx = (px / _kCellSize).round();
      final cy = (py / _kCellSize).round();
      for (int dy = 0; dy < ks; dy++) {
        final row = cy + dy - kr;
        if (row < 0 || row >= rows) { continue; }
        for (int dx = 0; dx < ks; dx++) {
          final col = cx + dx - kr;
          if (col < 0 || col >= cols) { continue; }
          density[row * cols + col] += kernel[dy][dx];
        }
      }
    }
  }

  double maxD = 0;
  for (final v in density) {
    if (v > maxD) maxD = v;
  }
  if (maxD == 0) return Uint32List(0);

  final pixels = Uint32List(cols * rows);
  for (int i = 0; i < density.length; i++) {
    // sqrt-scale so faint routes stay visible
    final t = math.sqrt(density[i] / maxD);
    if (t < 0.01) continue;
    pixels[i] = _heatColor(t);
  }
  return pixels;
}

/// Maps t∈[0,1] → RGBA Uint32 (little-endian: R | G<<8 | B<<16 | A<<24).
/// Palette: transparent → dark-blue → cyan → yellow → white
int _heatColor(double t) {
  final double r, g, b, a;
  if (t < 0.25) {
    final s = t / 0.25;
    (r, g, b, a) = (0, 0, 180 * s, 160 * s);
  } else if (t < 0.5) {
    final s = (t - 0.25) / 0.25;
    (r, g, b, a) = (0, s * 200, 180 - 80 * s, 160 + 40 * s);
  } else if (t < 0.75) {
    final s = (t - 0.5) / 0.25;
    (r, g, b, a) = (255 * s, 200 + 30 * s, 100 * (1 - s), 200 + 30 * s);
  } else {
    final s = (t - 0.75) / 0.25;
    (r, g, b, a) = (255, 230 + 25 * s, 120 * s, 230 + 25 * s);
  }
  return (a.round().clamp(0, 255) << 24) |
      (b.round().clamp(0, 255) << 16) |
      (g.round().clamp(0, 255) << 8) |
      r.round().clamp(0, 255);
}

// ── HeatmapLayer ──────────────────────────────────────────────────────────────

class HeatmapLayer extends StatefulWidget {
  const HeatmapLayer({super.key, required this.routes});
  final List<List<LatLng>> routes;

  @override
  State<HeatmapLayer> createState() => _HeatmapLayerState();
}

class _HeatmapLayerState extends State<HeatmapLayer> {
  ui.Image? _image;
  Timer? _debounce;
  bool _computing = false;
  MapCamera? _pendingCamera;
  Size? _pendingSize;

  @override
  void dispose() {
    _debounce?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _scheduleRebuild(MapCamera camera, Size size) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => _rebuild(camera, size));
  }

  Future<void> _rebuild(MapCamera camera, Size size) async {
    if (_computing) {
      _pendingCamera = camera;
      _pendingSize = size;
      return;
    }
    _computing = true;
    _pendingCamera = null;
    _pendingSize = null;

    final screenRoutes = widget.routes.map((route) => route.map((ll) {
          final pt = camera.latLngToScreenOffset(ll);
          return [pt.dx, pt.dy];
        }).toList()).toList();

    final input = (
      routes: screenRoutes,
      width: size.width.round(),
      height: size.height.round(),
    );

    final pixels = await compute(_buildDensityGrid, input);
    _computing = false;
    if (!mounted) return;

    if (pixels.isEmpty) {
      if (_pendingCamera != null) _rebuild(_pendingCamera!, _pendingSize!);
      return;
    }

    final cols = (size.width / _kCellSize).ceil();
    final rows = (size.height / _kCellSize).ceil();

    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels.buffer.asUint8List());
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: cols,
      height: rows,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();

    if (!mounted) return;
    setState(() {
      _image?.dispose();
      _image = frame.image;
    });

    if (_pendingCamera != null) _rebuild(_pendingCamera!, _pendingSize!);
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      _scheduleRebuild(camera, size);
      return CustomPaint(
        painter: _HeatmapImagePainter(_image, size),
        size: size,
      );
    });
  }
}

class _HeatmapImagePainter extends CustomPainter {
  final ui.Image? image;
  final Size targetSize;

  const _HeatmapImagePainter(this.image, this.targetSize);

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) return;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, targetSize.width, targetSize.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_HeatmapImagePainter old) =>
      old.image != image || old.targetSize != targetSize;
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

