import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'src/api.dart' as api;
import 'src/platform_io.dart'
    if (dart.library.html) 'src/platform_stub.dart'
    as plat;

import 'src/views/login_page.dart';
import 'src/auth.dart';
import 'src/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await api.initApi();
  await Auth.init();

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
}

class MontApp extends StatelessWidget {
  const MontApp({super.key});

  Widget _initialHome() =>
      Auth.token == null ? const LoginPage() : const HomeShell();

  ThemeData _theme(Brightness b) {
    // Soft Neon Lavender theme (Purple Accent)
    const background = Color(0xFF121217);
    const surface = Color(0xFF1A1B22);
    const lavender = Color(0xFFC4B5FD);
    const indigo = Color(0xFF818CF8);
    const accent = Color(0xFFE9D5FF);
    const textPrimary = Color(0xFFF5F5F7);
    const textSecondary = Color(0xFFA1A1AA);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: lavender,
        secondary: indigo,
        tertiary: accent,
        surface: surface,
        background: background,
        onPrimary: background,
        onSecondary: background,
        onSurface: textPrimary,
        onBackground: textPrimary,
        error: Colors.redAccent,
        outline: textSecondary,
      ),
      scaffoldBackgroundColor: background,
      cardColor: surface,
      dividerColor: textSecondary.withValues(alpha: 0.2),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textPrimary),
        bodySmall: TextStyle(color: textSecondary),
        titleLarge: TextStyle(color: textPrimary),
        titleMedium: TextStyle(color: textPrimary),
        titleSmall: TextStyle(color: textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mont',
      themeMode: ThemeMode.dark,
      theme: _theme(Brightness.dark),
      darkTheme: _theme(Brightness.dark),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'GB'),
        Locale('en', 'US'),
      ],
      home: _initialHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}
