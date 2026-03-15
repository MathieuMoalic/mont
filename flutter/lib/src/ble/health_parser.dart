// Parser for Huami/ZeppOS ACTIVITY data (fetch type 0x01).
//
// Each chunk carries a 1-byte seq-counter prefix (stripped here).
// The remaining bytes are 8-byte per-minute samples in the extended format:
//   byte 0: kind        (activity type)
//   byte 1: intensity   (raw step intensity)
//   byte 2: steps       (step count in this minute, uint8)
//   byte 3: heartRate   (bpm, 0 = no reading)
//   byte 4: unknown1
//   byte 5: sleep       (sleep flag)
//   byte 6: deepSleep
//   byte 7: remSleep
//
// [firstSampleTime] is the timestamp of byte 0 from the fetch response.
// Each subsequent sample is +1 minute.

/// One day's aggregated health data derived from per-minute activity samples.
class DailyHealthData {
  const DailyHealthData({
    required this.date,
    this.avgHr,
    this.minHr,
    this.maxHr,
    this.steps,
  });

  final String date; // "YYYY-MM-DD" UTC
  final int? avgHr;
  final int? minHr;
  final int? maxHr;
  final int? steps;

  Map<String, dynamic> toJson() => {
        'date': date,
        'avg_hr': avgHr,
        'min_hr': minHr,
        'max_hr': maxHr,
        'steps': steps,
      };
}

class _DayAccum {
  int stepsTotal = 0;
  int hrSum = 0;
  int hrCount = 0;
  int hrMin = 255;
  int hrMax = 0;
}

/// Parse a batch of activity chunks into per-day aggregates.
///
/// Returns one [DailyHealthData] per UTC day, sorted ascending by date.
List<DailyHealthData> parseActivitySamples(
  List<List<int>> chunks,
  DateTime firstSampleTime,
) {
  // Assemble chunks, stripping the 1-byte seq prefix from each.
  final assembled = <int>[];
  for (final chunk in chunks) {
    if (chunk.length < 2) continue;
    assembled.addAll(chunk.skip(1));
  }

  const sampleSize = 8;
  if (assembled.length < sampleSize) return [];

  final days = <String, _DayAccum>{};
  var t = firstSampleTime.toUtc();

  for (int i = 0; i + sampleSize <= assembled.length; i += sampleSize) {
    final steps = assembled[i + 2];
    final hr = assembled[i + 3];
    final date =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

    final acc = days.putIfAbsent(date, _DayAccum.new);
    acc.stepsTotal += steps;
    if (hr > 0) {
      acc.hrSum += hr;
      acc.hrCount++;
      if (hr < acc.hrMin) acc.hrMin = hr;
      if (hr > acc.hrMax) acc.hrMax = hr;
    }
    t = t.add(const Duration(minutes: 1));
  }

  return days.entries.map((e) {
    final acc = e.value;
    return DailyHealthData(
      date: e.key,
      steps: acc.stepsTotal > 0 ? acc.stepsTotal : null,
      avgHr: acc.hrCount > 0 ? (acc.hrSum / acc.hrCount).round() : null,
      minHr: acc.hrCount > 0 ? acc.hrMin : null,
      maxHr: acc.hrCount > 0 ? acc.hrMax : null,
    );
  }).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
}
