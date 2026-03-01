import 'package:flutter/material.dart';
import 'views/workouts_screen.dart';

/// Top-level shell shown after login.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) => const WorkoutsScreen();
}
