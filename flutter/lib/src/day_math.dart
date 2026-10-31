// DST-safe civil-day arithmetic.
//
// `DateTime.add`/`subtract` with `Duration(days: n)` step in absolute 24h
// blocks, so crossing a DST change leaves the result an hour off local
// midnight. Downstream comparisons against midnight day-keys then silently
// fail (after a fall-back a calendar cell renders as 23:00 the previous
// civil day). These helpers step whole civil days instead.

/// Local midnight of the civil day [days] away from the day of [d].
DateTime dayOffset(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);

/// Number of civil days from the day of [a] to the day of [b].
int civilDaysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
