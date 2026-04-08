import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/views/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Mock PackageInfo platform channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getAll') {
          return <String, dynamic>{
            'appName': 'mont',
            'packageName': 'eu.matmoa.mont',
            'version': '0.4.8',
            'buildNumber': '1',
          };
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      null,
    );
  });

  group('SettingsScreen', () {
    testWidgets('renders app bar with title', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('renders charts section header', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Charts'), findsOneWidget);
    });

    testWidgets('renders smoothing slider', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('renders smoothing label', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Smoothing (k points)'), findsOneWidget);
    });

    testWidgets('shows default smoothing value', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      // Default is 5
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('slider can be moved', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);

      // Drag slider to change value
      await tester.drag(slider, const Offset(100, 0));
      await tester.pumpAndSettle();

      // Value should have changed from 5
      // The exact value depends on slider width, but it should not crash
    });

    testWidgets('shows help text for smoothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      // Should show averaging help text for default value of 5
      expect(
        find.text('Each point is the average of 5 consecutive measurements'),
        findsOneWidget,
      );
    });

    testWidgets('loads saved smoothing value', (tester) async {
      SharedPreferences.setMockInitialValues({kSmoothingKey: 10});

      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('shows no smoothing text when value is 1', (tester) async {
      SharedPreferences.setMockInitialValues({kSmoothingKey: 1});

      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('No smoothing — raw data'), findsOneWidget);
    });
  });

  group('Settings constants', () {
    test('kSmoothingDefault is 5', () {
      expect(kSmoothingDefault, 5);
    });

    test('kSmoothingKey is correct', () {
      expect(kSmoothingKey, 'chart_smoothing');
    });
  });
}
