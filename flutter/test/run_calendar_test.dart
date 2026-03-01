import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/models.dart';
import 'package:mont/src/views/run_calendar_screen.dart';

/// Minimal RunSummary with just the fields we need.
RunSummary _run({required DateTime startedAt, double distanceM = 5000}) =>
    RunSummary(
      id: startedAt.millisecondsSinceEpoch,
      startedAt: startedAt,
      durationS: 1800,
      distanceM: distanceM,
    );

void main() {
  group('RunCalendarScreen', () {
    testWidgets('shows month label', (tester) async {
      final runs = [_run(startedAt: DateTime.utc(2025, 6, 10))];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      expect(find.text('June 2025'), findsOneWidget);
    });

    testWidgets('shows day-of-week headers', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: []),
      ));
      await tester.pump();
      for (final d in ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']) {
        expect(find.text(d), findsOneWidget);
      }
    });

    testWidgets('shows "No runs this month" when empty', (tester) async {
      // Pick a historic month with no runs
      final runs = <RunSummary>[];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      // Scroll down to make sure the empty-state message is visible
      await tester.scrollUntilVisible(
        find.text('No runs this month'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('No runs this month'), findsOneWidget);
    });

    testWidgets('navigates to previous month', (tester) async {
      final runs = [_run(startedAt: DateTime.utc(2025, 6, 15))];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      expect(find.text('June 2025'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.text('May 2025'), findsOneWidget);
    });

    testWidgets('navigates to next month', (tester) async {
      final runs = [_run(startedAt: DateTime.utc(2025, 6, 15))];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(find.text('July 2025'), findsOneWidget);
    });

    testWidgets('shows run km in calendar cell', (tester) async {
      final runs = [_run(startedAt: DateTime.utc(2025, 6, 15), distanceM: 10000)];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      // Calendar cell shows rounded km with 'k' suffix
      expect(find.text('10k'), findsOneWidget);
    });

    testWidgets('wraps month correctly crossing year boundary', (tester) async {
      final runs = [_run(startedAt: DateTime.utc(2025, 1, 5))];
      await tester.pumpWidget(MaterialApp(
        home: RunCalendarScreen(runs: runs),
      ));
      await tester.pump();
      expect(find.text('January 2025'), findsOneWidget);

      // Go back one month → December 2024
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.text('December 2024'), findsOneWidget);
    });
  });
}
