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

  ThemeData _theme(Brightness b) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange, brightness: b),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mont',
      themeMode: ThemeMode.dark,
      theme: _theme(Brightness.light),
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
