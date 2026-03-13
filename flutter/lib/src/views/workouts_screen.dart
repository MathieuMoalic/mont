import 'package:flutter/material.dart';

import '../api.dart' as api;
import '../auth.dart';
import '../models.dart';
import 'active_workout_screen.dart';
import 'exercise_history_screen.dart';
import 'login_page.dart';
import 'workout_heatmap_screen.dart';

class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});

  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  List<WorkoutSummary>? _workouts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final workouts = await api.listWorkouts();
      if (mounted) setState(() { _workouts = workouts; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _startWorkout() async {
    try {
      final summary = await api.createWorkout();
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ActiveWorkoutScreen(workoutId: summary.id)),
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _logout() async {
    await Auth.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    }
  }

  String _duration(WorkoutSummary w) {
    if (w.finishedAt == null) return 'In progress';
    final d = w.finishedAt!.difference(w.startedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  String _formatDate(DateTime utc) {
    final d = utc.toLocal();
    final now = DateTime.now();
    final h = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final time = '$h:$min';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'Today, $time';
    }
    final yest = now.subtract(const Duration(days: 1));
    if (d.year == yest.year && d.month == yest.month && d.day == yest.day) {
      return 'Yesterday, $time';
    }
    return '${d.day}/${d.month}/${d.year}, $time';
  }

  Future<void> _deleteWorkout(int id) async {
    try {
      await api.deleteWorkout(id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mont'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Exercise history',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const ExerciseHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.grid_view),
            tooltip: 'Workout heatmap',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const WorkoutHeatmapScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startWorkout,
        icon: const Icon(Icons.add),
        label: const Text('Start Workout'),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error: $_error'),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_workouts == null) return const Center(child: CircularProgressIndicator());
    if (_workouts!.isEmpty) {
      return const Center(
        child: Text(
          'No workouts yet.\nTap + to start your first workout!',
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: _workouts!.length,
        itemBuilder: (ctx, i) {
          final w = _workouts![i];
          return Dismissible(
            key: ValueKey(w.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Theme.of(context).colorScheme.error,
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            confirmDismiss: (_) => showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Delete workout?'),
                content: const Text('This cannot be undone.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete')),
                ],
              ),
            ),
            onDismissed: (_) => _deleteWorkout(w.id),
            child: ListTile(
            leading: CircleAvatar(
              child: Icon(w.isActive ? Icons.fitness_center : Icons.check),
            ),
            title: Text(_formatDate(w.startedAt)),
            subtitle: Text(
              '${w.setCount} set${w.setCount == 1 ? '' : 's'} · ${_duration(w)}',
            ),
            onTap: () async {
              await Navigator.push<void>(
                ctx,
                MaterialPageRoute(
                  builder: (_) => ActiveWorkoutScreen(workoutId: w.id),
                ),
              );
              _load();
            },
          ),
          );
        },
      ),
    );
  }
}
