import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'views/calories_screen.dart';
import 'views/debug_screen.dart';
import 'views/health_screen.dart';
import 'views/settings_screen.dart';
import 'views/workouts_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static List<Widget> get _screens => [
    const WorkoutsScreen(),
    const CaloriesScreen(),
    const HealthScreen(),
    const SettingsScreen(),
    // Temporary BLE-import inspection tab; removed once the import is trusted.
    if (kDebugMode) const DebugScreen(),
  ];

  List<NavigationDestination> get _destinations => const [
    NavigationDestination(
      icon: Icon(Icons.fitness_center, key: ValueKey('e2e-nav-workouts')),
      label: 'Workouts',
    ),
    NavigationDestination(
      icon: Icon(Icons.restaurant_outlined, key: ValueKey('e2e-nav-calories')),
      label: 'Calories',
    ),
    NavigationDestination(
      icon: Icon(Icons.monitor_heart_outlined, key: ValueKey('e2e-nav-health')),
      label: 'Health',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined, key: ValueKey('e2e-nav-settings')),
      label: 'Settings',
    ),
    if (kDebugMode)
      NavigationDestination(
        icon: Icon(Icons.bug_report_outlined),
        label: 'Debug',
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = _screens;
    final destinations = _destinations;
    if (_tab >= screens.length) {
      _tab = 0;
    }
    return Scaffold(
      key: const ValueKey('e2e-home-screen'),
      body: screens[_tab],
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('e2e-primary-navigation'),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: destinations,
      ),
    );
  }
}
