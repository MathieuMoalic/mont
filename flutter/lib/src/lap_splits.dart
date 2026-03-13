import 'dart:math' as math;
import 'models.dart';

/// One per-km split for a run.
class LapSplit {
  final int lapNumber; // 1-based km index
  final double distanceKm; // nominal km (1.0, 2.0, …)
  final int? paceSeconds; // seconds per km (null if no time data)
  final double? avgHr; // average heart rate (null if no HR data)
  final double? elevationDelta; // ele gain/loss in metres (null if no ele data)
  final double? avgCadence; // steps per minute (null if no cadence data)
  final double? avgStrideM; // metres per stride (null if no cadence/speed data)

  const LapSplit({
    required this.lapNumber,
    required this.distanceKm,
    this.paceSeconds,
    this.avgHr,
    this.elevationDelta,
    this.avgCadence,
    this.avgStrideM,
  });
}

/// Computes per-km lap splits from a list of [RunPoint]s.
///
/// Requires [cumKm] to be the cumulative distance in km for each point
/// (same length as [pts], pre-computed with haversine).
List<LapSplit> computeLapSplits(List<RunPoint> pts, List<double> cumKm) {
  if (pts.length < 2 || cumKm.isEmpty) return [];

  final totalKm = cumKm.last;
  final fullLaps = totalKm.floor();
  if (fullLaps == 0) return [];

  final splits = <LapSplit>[];

  for (var lap = 1; lap <= fullLaps; lap++) {
    final startKm = (lap - 1).toDouble();
    final endKm = lap.toDouble();

    // Collect indices in [startKm, endKm)
    final indices = <int>[];
    for (var i = 0; i < pts.length; i++) {
      if (cumKm[i] >= startKm && cumKm[i] < endKm) {
        indices.add(i);
      }
    }
    // Include the boundary point at or just past endKm
    final boundaryIdx =
        cumKm.indexWhere((d) => d >= endKm);
    if (boundaryIdx != -1) indices.add(boundaryIdx);

    if (indices.isEmpty) continue;

    // Pace: seconds from first to last point in this lap / km
    int? paceSeconds;
    final firstT = pts[indices.first].t;
    final lastT = pts[indices.last].t;
    if (firstT != null && lastT != null && lastT > firstT) {
      // Scale elapsed time to 1 km
      final elapsedS = lastT - firstT;
      final lapDistKm = cumKm[indices.last] - cumKm[indices.first];
      if (lapDistKm > 0) {
        paceSeconds = (elapsedS / lapDistKm).round();
      }
    }

    // Avg HR
    final hrValues = indices
        .map((i) => pts[i].hr)
        .whereType<int>()
        .toList();
    final double? avgHr = hrValues.isEmpty
        ? null
        : hrValues.reduce((a, b) => a + b) / hrValues.length;

    // Elevation delta
    double? elevationDelta;
    final firstEle = pts[indices.first].ele;
    final lastEle = pts[indices.last].ele;
    if (firstEle != null && lastEle != null) {
      elevationDelta = lastEle - firstEle;
    }

    // Avg cadence
    final cadValues = indices.map((i) => pts[i].cad).whereType<int>().toList();
    final double? avgCadence = cadValues.isEmpty
        ? null
        : cadValues.reduce((a, b) => a + b) / cadValues.length;

    // Avg stride: speed * 120 / cad for each consecutive pair with cad+time
    final strideValues = <double>[];
    for (var k = 0; k < indices.length - 1; k++) {
      final ia = indices[k], ib = indices[k + 1];
      final ca = pts[ia].cad, ta = pts[ia].t, tb = pts[ib].t;
      if (ca == null || ca == 0 || ta == null || tb == null) continue;
      final dt = (tb - ta).toDouble();
      if (dt <= 0) continue;
      final dm = _haversine(pts[ia].lat, pts[ia].lon, pts[ib].lat, pts[ib].lon);
      if (dm < 0.1) continue;
      final stride = (dm / dt) * 60.0 / ca;
      if (stride < 0.25 || stride > 1.75) continue;
      strideValues.add(stride);
    }
    final double? avgStrideM = strideValues.isEmpty
        ? null
        : strideValues.reduce((a, b) => a + b) / strideValues.length;

    splits.add(LapSplit(
      lapNumber: lap,
      distanceKm: endKm,
      paceSeconds: paceSeconds,
      avgHr: avgHr,
      elevationDelta: elevationDelta,
      avgCadence: avgCadence,
      avgStrideM: avgStrideM,
    ));
  }

  return splits;
}

/// Formats [seconds] as "m:ss/km".
String fmtPaceFromSeconds(int seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

double _haversine(double lat1, double lon1, double lat2, double lon2) {
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
