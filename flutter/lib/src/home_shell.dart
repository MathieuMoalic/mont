import 'package:flutter/material.dart';
import 'views/calories_screen.dart';
import 'views/health_screen.dart';
import 'views/morning_screen.dart';
import 'views/settings_screen.dart';
import 'views/workouts_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _healthTab = 3;

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.wb_twilight_outlined, key: ValueKey('e2e-nav-morning')),
      label: 'Morning',
    ),
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
  ];

  @override
  Widget build(BuildContext context) {
    // IndexedStack keeps every tab's state alive (e.g. the Morning tab's
    // selected day) instead of rebuilding from scratch on each switch.
    return Scaffold(
      key: const ValueKey('e2e-home-screen'),
      body: IndexedStack(
        index: _tab,
        children: [
          MorningScreen(onWeightSaved: () => setState(() => _tab = _healthTab)),
          const WorkoutsScreen(),
          const CaloriesScreen(),
          const HealthScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('e2e-primary-navigation'),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: _destinations,
      ),
    );
  }
}
