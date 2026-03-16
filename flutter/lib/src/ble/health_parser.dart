// Parser for Huami/ZeppOS health data.
//
// ACTIVITY data (fetch type 0x01):
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
// RESTING_HEART_RATE (0x3a) and MAX_HEART_RATE (0x3d):
// 6-byte records after a 2-byte header:
//   bytes 0-3: unix timestamp (seconds, little-endian uint32)
//   byte 4:    UTC offset in quarter-hours (signed)
//   byte 5:    heart rate (bpm, uint8)
//
// [firstSampleTime] is the timestamp of byte 0 from the fetch response.
// Each subsequent activity sample is +1 minute.

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

/// Activity kind constants from HuamiExtendedSampleProvider.
class _HuamiKind {
  static const int notWorn = 115;
  static const int charging = 118;
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

  // Skip the 2-byte BLE framing header present at the start of all assembled
  // Huami2021 data transfers (same as sports summaries and GPS detail).
  const headerSize = 2;
  const sampleSize = 8;
  if (assembled.length < headerSize + sampleSize) return [];
  final samples = assembled.skip(headerSize).toList();

  final days = <String, _DayAccum>{};
  var t = firstSampleTime.toUtc();

  for (int i = 0; i + sampleSize <= samples.length; i += sampleSize) {
    // Extended 8-byte sample: [kind, intensity, steps, hr, unk1, sleep, deepSleep, remSleep]
    final kind = samples[i];
    final steps = samples[i + 2];
    final hr = samples[i + 3];
    final date =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

    final acc = days.putIfAbsent(date, _DayAccum.new);

    // Count steps from all minutes (including not-worn, some devices still
    // report valid step counts in those slots).
    acc.stepsTotal += steps;

    // Only include HR from minutes where the watch is actually worn.
    // NOT_WORN (115) and CHARGING (118) samples have unreliable HR readings.
    // Exclude physiologically impossible values: 0x01 (sentinel = no reading),
    // < 40 (artifact values this watch emits; 30 BPM is a common spurious value),
    // and >= 255.
    final isWorn =
        kind != _HuamiKind.notWorn && kind != _HuamiKind.charging;
    if (isWorn && hr >= 40 && hr < 255) {
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

/// Parse daily HR records from RESTING_HEART_RATE (0x3a) or MAX_HEART_RATE (0x3d) data.
///
/// Record format (6 bytes each, after the 2-byte chunk header):
///   bytes 0-3: unix timestamp seconds, little-endian uint32
///   byte 4:    UTC offset in quarter-hours (signed, ignored here)
///   byte 5:    heart rate bpm
///
/// Returns a map of "YYYY-MM-DD" → HR value.
Map<String, int> parseDailyHrSamples(List<List<int>> chunks) {
  final assembled = <int>[];
  for (final chunk in chunks) {
    if (chunk.length < 2) continue;
    assembled.addAll(chunk.skip(1));
  }

  const headerSize = 2;
  const sampleSize = 6;
  if (assembled.length < headerSize + sampleSize) return {};
  final samples = assembled.skip(headerSize).toList();

  final result = <String, int>{};
  for (int i = 0; i + sampleSize <= samples.length; i += sampleSize) {
    final tsSeconds = (samples[i] & 0xff) |
        ((samples[i + 1] & 0xff) << 8) |
        ((samples[i + 2] & 0xff) << 16) |
        ((samples[i + 3] & 0xff) << 24);
    final hr = samples[i + 5] & 0xff;
    if (hr < 20 || hr > 250) continue;
    final dt =
        DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000, isUtc: true);
    final date =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    result[date] = hr;
  }
  return result;
}
