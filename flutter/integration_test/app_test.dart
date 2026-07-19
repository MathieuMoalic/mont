import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mont/main.dart' as app;
import 'package:mont/src/auth.dart';

const _password = String.fromEnvironment(
  'E2E_TEST_PASSWORD',
  defaultValue: 'e2e-password',
);

const _backendUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:6001',
);

Future<void> _waitForCondition(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await tester.pump(step);
  }
  throw TestFailure('Timed out waiting for: $description');
}

Future<void> _waitForFinder(
  WidgetTester tester,
  Finder finder, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
}) async {
  await _waitForCondition(
    tester,
    () => finder.evaluate().isNotEmpty,
    description: description,
    timeout: timeout,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> loginAndOpenHome(WidgetTester tester) async {
    await Auth.logout();
    await app.bootstrapAndRunApp();
    await tester.pump();

    final passwordField = find.byKey(const ValueKey('e2e-login-password'));
    final submitButton = find.byKey(const ValueKey('e2e-login-submit'));
    final serverUrlInput = find.byKey(const ValueKey('e2e-server-url-input'));
    final serverUrlSave = find.byKey(const ValueKey('e2e-server-url-save'));
    final homeScreen = find.byKey(const ValueKey('e2e-home-screen'));
    final caloriesNav = find.byKey(const ValueKey('e2e-nav-calories'));
    final caloriesScreen = find.byKey(const ValueKey('e2e-calories-screen'));

    await _waitForFinder(
      tester,
      passwordField,
      description: 'login password input',
    );

    await tester.enterText(passwordField, _password);
    await tester.tap(submitButton);
    await tester.pump();

    await _waitForCondition(
      tester,
      () =>
          homeScreen.evaluate().isNotEmpty ||
          serverUrlSave.evaluate().isNotEmpty,
      description: 'either home screen or server-url verification dialog',
    );

    if (serverUrlSave.evaluate().isNotEmpty) {
      await _waitForFinder(
        tester,
        serverUrlInput,
        description: 'server-url input field',
      );
      await tester.enterText(serverUrlInput, _backendUrl);
      await tester.tap(serverUrlSave);
      await tester.pump();
    }

    await _waitForFinder(
      tester,
      homeScreen,
      description: 'home screen after authentication',
    );

    await _waitForFinder(
      tester,
      caloriesNav,
      description: 'calories navigation destination',
    );
    await tester.tap(caloriesNav);
    await tester.pump();

    await _waitForFinder(tester, homeScreen, description: 'home screen');
  }

  testWidgets('logs in and opens calories tab', (tester) async {
    await loginAndOpenHome(tester);

    final caloriesNav = find.byKey(const ValueKey('e2e-nav-calories'));
    final caloriesScreen = find.byKey(const ValueKey('e2e-calories-screen'));
    await tester.tap(caloriesNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      caloriesScreen,
      description: 'calories screen',
    );
  });

  testWidgets('navigates across all primary tabs', (tester) async {
    await loginAndOpenHome(tester);

    final workoutsNav = find.byKey(const ValueKey('e2e-nav-workouts'));
    final caloriesNav = find.byKey(const ValueKey('e2e-nav-calories'));
    final healthNav = find.byKey(const ValueKey('e2e-nav-health'));
    final settingsNav = find.byKey(const ValueKey('e2e-nav-settings'));
    final caloriesScreen = find.byKey(const ValueKey('e2e-calories-screen'));

    await tester.tap(caloriesNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      caloriesScreen,
      description: 'calories screen after selecting calories tab',
    );

    await tester.tap(healthNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      find.text('Health'),
      description: 'health tab title',
    );

    await tester.tap(settingsNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      find.text('Settings'),
      description: 'settings tab title',
    );

    await tester.tap(workoutsNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      find.text('Workouts'),
      description: 'workouts tab title',
    );
  });

  testWidgets('opens create meal UI from add-meal dialog', (tester) async {
    await loginAndOpenHome(tester);

    final caloriesNav = find.byKey(const ValueKey('e2e-nav-calories'));
    await tester.tap(caloriesNav);
    await tester.pump();
    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-calories-screen')),
      description: 'calories screen',
    );

    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-add-meal-morning')),
      description: 'add meal button for morning section',
    );
    await tester.tap(find.byKey(const ValueKey('e2e-add-meal-morning')));
    await tester.pump();

    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-meal-search-add-new')),
      description: 'add new meal button in meal search dialog',
    );
    await tester.tap(find.byKey(const ValueKey('e2e-meal-search-add-new')));
    await tester.pump();

    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-meal-editor-name')),
      description: 'create meal name field',
    );

    await tester.enterText(
      find.byKey(const ValueKey('e2e-meal-editor-name')),
      'E2E Meal',
    );
    await tester.tap(find.byKey(const ValueKey('e2e-meal-editor-cancel')));
    await tester.pump();

    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-meal-log-cancel')),
      description: 'meal log dialog cancel button',
    );
    await tester.tap(find.byKey(const ValueKey('e2e-meal-log-cancel')));
    await tester.pump();

    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('e2e-calories-screen')),
      description: 'return to calories screen after closing dialogs',
    );
  });
}
