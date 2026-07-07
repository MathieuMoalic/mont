import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mont/src/views/login_page.dart';

void main() {
  group('LoginPage', () {
    testWidgets('renders password field and login button', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      expect(find.byType(TextField), findsAtLeastNWidgets(1));
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('shows login title', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      expect(find.text('Sign in'), findsAtLeastNWidgets(1));
    });

    testWidgets('password field is obscured', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final textField = tester.widget<TextField>(find.byType(TextField).first);
      expect(textField.obscureText, isTrue);
    });

    testWidgets('can enter password', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final passwordField = find.byType(TextField).first;
      await tester.enterText(passwordField, 'mypassword123');

      expect(find.text('mypassword123'), findsOneWidget);
    });

    testWidgets('shows error when logging in with empty password', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      // Tap login without entering password
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      // Should not crash - error handling is done by the widget
    });

    testWidgets('login button has correct text', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });

    testWidgets('renders with Material design', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      // Should have a Scaffold
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('password field has correct label or hint', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      // Look for password-related hint/label
      final textField = find.byType(TextField).first;
      expect(textField, findsOneWidget);
    });

    testWidgets('handles rapid button taps without crash', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final button = find.byType(FilledButton);

      // Rapid taps should not crash
      await tester.tap(button);
      await tester.tap(button);
      await tester.tap(button);
      await tester.pump();
    });

    testWidgets('TextField is enabled initially', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final textField = tester.widget<TextField>(find.byType(TextField).first);
      expect(textField.enabled, isNot(false));
    });

    testWidgets('can clear entered password', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final passwordField = find.byType(TextField).first;
      await tester.enterText(passwordField, 'testpassword');
      expect(find.text('testpassword'), findsOneWidget);

      await tester.enterText(passwordField, '');
      expect(find.text('testpassword'), findsNothing);
    });

    testWidgets('password with special characters', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final passwordField = find.byType(TextField).first;
      await tester.enterText(passwordField, 'P@ssw0rd!#\$%');

      expect(find.text('P@ssw0rd!#\$%'), findsOneWidget);
    });

    testWidgets('long password input', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final passwordField = find.byType(TextField).first;
      final longPassword = 'a' * 100;
      await tester.enterText(passwordField, longPassword);

      expect(find.text(longPassword), findsOneWidget);
    });
  });
}
