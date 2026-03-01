import 'package:flutter/material.dart';

import '../models.dart';
import 'run_detail_screen.dart';

class RunCalendarScreen extends StatefulWidget {
  final List<RunSummary> runs;
  const RunCalendarScreen({super.key, required this.runs});

  @override
  State<RunCalendarScreen> createState() => _RunCalendarScreenState();
}

class _RunCalendarScreenState extends State<RunCalendarScreen> {
  // Map: local date (yyyy-MM-dd) → list of runs
  late Map<String, List<RunSummary>> _byDay;
  late DateTime _focusMonth;

  @override
  void initState() {
    super.initState();
    _buildIndex();
    // Start at the month of the most recent run, or today
    if (widget.runs.isNotEmpty) {
      final latest = widget.runs.first.startedAt.toLocal();
      _focusMonth = DateTime(latest.year, latest.month);
    } else {
      final now = DateTime.now();
      _focusMonth = DateTime(now.year, now.month);
    }
  }

  void _buildIndex() {
    _byDay = {};
    for (final r in widget.runs) {
      final d = r.startedAt.toLocal();
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      _byDay.putIfAbsent(key, () => []).add(r);
    }
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _monthLabel(DateTime m) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[m.month - 1]} ${m.year}';
  }

  void _prevMonth() =>
      setState(() => _focusMonth = DateTime(_focusMonth.year, _focusMonth.month - 1));

  void _nextMonth() =>
      setState(() => _focusMonth = DateTime(_focusMonth.year, _focusMonth.month + 1));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run calendar')),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                // Month navigation header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(icon: const Icon(Icons.chevron_left), onPressed: _prevMonth),
                    Text(_monthLabel(_focusMonth),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    IconButton(icon: const Icon(Icons.chevron_right), onPressed: _nextMonth),
                  ],
                ),
                // Day-of-week header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']
                        .map((d) => Expanded(
                              child: Center(
                                child: Text(d,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.grey)),
                              ),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(height: 4),
                // Calendar grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _buildGrid(context),
                ),
                const Divider(),
              ],
            ),
          ),
          // Run list for this month
          _buildMonthSliver(context),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final firstDay = DateTime(_focusMonth.year, _focusMonth.month, 1);
    // weekday: 1=Mon … 7=Sun; offset to grid column 0=Mon
    final startOffset = firstDay.weekday - 1;
    final daysInMonth =
        DateTime(_focusMonth.year, _focusMonth.month + 1, 0).day;

    final cells = <Widget>[];
    // Leading empty cells
    for (var i = 0; i < startOffset; i++) {
      cells.add(const SizedBox.shrink());
    }

    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_focusMonth.year, _focusMonth.month, day);
      final key = _dayKey(date);
      final runs = _byDay[key];
      final hasRun = runs != null && runs.isNotEmpty;

      final totalKm = hasRun
          ? runs!.fold<double>(0, (s, r) => s + r.distanceM / 1000)
          : 0.0;

      final isToday = _isToday(date);
      final color = hasRun
          ? Theme.of(context).colorScheme.primary
          : Colors.transparent;
      final textColor = hasRun
          ? Theme.of(context).colorScheme.onPrimary
          : Theme.of(context).textTheme.bodyMedium?.color;

      cells.add(
        GestureDetector(
          onTap: hasRun
              ? () => _onDayTap(context, date, runs!)
              : null,
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isToday
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
            ),
            child: AspectRatio(
              aspectRatio: 1,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$day',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              hasRun ? FontWeight.bold : FontWeight.normal,
                          color: textColor),
                    ),
                    if (hasRun)
                      Text(
                        '${totalKm.toStringAsFixed(0)}k',
                        style: TextStyle(fontSize: 8, color: textColor),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 7,
      childAspectRatio: 1,
      children: cells,
    );
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  void _onDayTap(BuildContext context, DateTime date, List<RunSummary> runs) {
    if (runs.length == 1) {
      Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => RunDetailScreen(runId: runs.first.id)),
      );
    } else {
      // Multiple runs on same day — show a bottom sheet to pick
      showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => ListView.builder(
          shrinkWrap: true,
          itemCount: runs.length,
          itemBuilder: (_, i) {
            final r = runs[i];
            final km = (r.distanceM / 1000).toStringAsFixed(2);
            return ListTile(
              title: Text('$km km'),
              subtitle: Text(_fmtTime(r.startedAt.toLocal())),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => RunDetailScreen(runId: r.id)),
                );
              },
            );
          },
        ),
      );
    }
  }

  Widget _buildMonthSliver(BuildContext context) {
    final monthRuns = widget.runs
        .where((r) {
          final d = r.startedAt.toLocal();
          return d.year == _focusMonth.year && d.month == _focusMonth.month;
        })
        .toList();

    if (monthRuns.isEmpty) {
      return SliverToBoxAdapter(
        child: const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('No runs this month')),
        ),
      );
    }

    return SliverList.builder(
      itemCount: monthRuns.length,
      itemBuilder: (ctx, i) {
        final r = monthRuns[i];
        final d = r.startedAt.toLocal();
        final km = (r.distanceM / 1000).toStringAsFixed(2);
        return ListTile(
          leading: CircleAvatar(
            child: Text('${d.day}', style: const TextStyle(fontSize: 13)),
          ),
          title: Text('$km km'),
          subtitle: Text(_fmtTime(d)),
          onTap: () => Navigator.push<void>(
            ctx,
            MaterialPageRoute(builder: (_) => RunDetailScreen(runId: r.id)),
          ),
        );
      },
    );
  }

  String _fmtTime(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
