import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'src/api.dart' as api;
import 'src/platform_io.dart'
    if (dart.library.html) 'src/platform_stub.dart'
    as plat;
import 'src/theme.dart';

import 'src/views/login_page.dart';
import 'src/auth.dart';
import 'src/home_shell.dart';
import 'src/platform/ble_relay.dart' as ble;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  await bootstrapAndRunApp();
}

Future<void> bootstrapAndRunApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await api.initApi();
  await MontColors.loadCustomMuscleColors();
  await Auth.init();

  // Debug-only: run an unattended BLE relay session if the adb trigger file
  // exists. Consumes the trigger, then the app continues to start normally.
  await ble.autoSyncIfTriggered();

  // Set up auth failure callback to redirect to login
  api.onAuthFailure = () {
    Auth.logout();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  };

  if (!kIsWeb && plat.isDesktop) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Colors.transparent,
    );
    windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MontApp());

  // Sync the watch in the background after the UI is up (skipped when the
  // last attempt is recent or the user isn't logged in).
  if (Auth.token != null || Auth.refreshToken != null) {
    unawaited(ble.autoSyncOnAppOpen());
  }
}

class MontApp extends StatelessWidget {
  const MontApp({super.key});

  Widget _initialHome() =>
      Auth.token == null ? const LoginPage() : const HomeShell();

  @override
  Widget build(BuildContext context) {
    final theme = buildMontTheme();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Mont',
      themeMode: ThemeMode.dark,
      theme: theme,
      darkTheme: theme,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', 'GB'), Locale('en', 'US')],
      home: _initialHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}
