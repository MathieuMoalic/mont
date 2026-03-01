import 'package:flutter/material.dart';

/// Placeholder home shell — add tabs/navigation as features are built.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mont')),
      body: const Center(child: Text('Welcome to Mont')),
    );
  }
}
