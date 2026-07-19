import 'package:flutter/material.dart';
import 'views/calories_screen.dart';
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

  static const _screens = [
    WorkoutsScreen(),
    CaloriesScreen(),
    HealthScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('e2e-home-screen'),
      body: _screens[_tab],
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('e2e-primary-navigation'),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.fitness_center, key: ValueKey('e2e-nav-workouts')),
            label: 'Workouts',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.restaurant_outlined,
              key: ValueKey('e2e-nav-calories'),
            ),
            label: 'Calories',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.monitor_heart_outlined,
              key: ValueKey('e2e-nav-health'),
            ),
            label: 'Health',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.settings_outlined,
              key: ValueKey('e2e-nav-settings'),
            ),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
