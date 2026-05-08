import 'package:flutter/material.dart';
import 'dart:convert';

import 'platform/kv_store.dart' as kv;

/// Centralized color palette for Mont app.
/// Change these values to update colors globally.
class MontColors {
  MontColors._();
  static const _kMuscleColorOverridesKey = 'exercise_muscle_group_colors';

  // ─── Core palette ───────────────────────────────────────────────────────────
  static const background = Color(0xFF121217);
  static const surface = Color(0xFF1A1B22);
  static const surfaceLight = Color(0xFF252630);

  // Primary accent (lavender)
  static const primary = Color(0xFFC4B5FD);
  static const secondary = Color(0xFF818CF8);
  static const tertiary = Color(0xFFE9D5FF);

  // Text colors
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFFA1A1AA);

  // Semantic colors
  static const error = Color(0xFFFF6B6B);
  static const success = Color(0xFF4ADE80);
  static const warning = Color(0xFFFBBF24);

  // ─── Muscle group colors (soft pastels) ──────────────────────────────────────
  static const Map<String, Color> muscleGroupColors = {
    'Chest': Color(0xFF4A3548), // soft rose
    'Back': Color(0xFF354850), // soft teal
    'Shoulders': Color(0xFF4A4535), // soft amber
    'Biceps': Color(0xFF3A4838), // soft green
    'Triceps': Color(0xFF453550), // soft purple
    'Core': Color(0xFF503540), // soft coral
    'Quads': Color(0xFF354055), // soft blue
    'Hamstrings': Color(0xFF484838), // soft olive
    'Glutes': Color(0xFF4D3545), // soft magenta
    'Calves': Color(0xFF354845), // soft cyan
    'Full Body': Color(0xFF3D3D50), // soft indigo
    'Cardio': Color(0xFF504038), // soft orange
  };

  static final Map<String, Color> _muscleColorOverrides = {};

  static Map<String, Color> get muscleColorOverrides =>
      Map.unmodifiable(_muscleColorOverrides);

  static void applyMuscleColorOverrides(Map<String, Color> overrides) {
    _muscleColorOverrides
      ..clear()
      ..addAll(overrides);
  }

  static Future<void> loadCustomMuscleColors() async {
    final raw = await kv.getString(_kMuscleColorOverridesKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _muscleColorOverrides
        ..clear()
        ..addEntries(
          decoded.entries
              .where((e) => e.key.trim().isNotEmpty && e.value is String)
              .map((e) {
                final color = colorFromHex(e.value as String) ?? surface;
                return MapEntry(e.key.trim(), color);
              }),
        );
    } catch (_) {
      _muscleColorOverrides.clear();
    }
  }

  static Future<void> saveCustomMuscleColors(
    Map<String, Color> overrides,
  ) async {
    final payload = overrides.map((k, v) => MapEntry(k, colorToHex(v)));
    await kv.setString(_kMuscleColorOverridesKey, jsonEncode(payload));
  }

  /// Get color for a muscle group, with fallback to surface color
  static Color getMuscleColor(String? muscleGroup) {
    if (muscleGroup == null) return surface;
    final override = _muscleColorOverrides[muscleGroup];
    if (override != null) return override;
    return muscleGroupColors[muscleGroup] ?? surface;
  }

  /// Get a slightly lighter version for borders/accents
  static Color getMuscleAccent(String? muscleGroup) {
    final base = getMuscleColor(muscleGroup);
    return Color.lerp(base, textSecondary, 0.15) ?? base;
  }

  static String colorToHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

  static Color? colorFromHex(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '');
    final normalized = cleaned.length == 6 ? 'ff$cleaned' : cleaned;
    final value = int.tryParse(normalized, radix: 16);
    if (value == null) return null;
    return Color(value);
  }
}

/// Build the app theme using the centralized palette
ThemeData buildMontTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.dark(
      primary: MontColors.primary,
      secondary: MontColors.secondary,
      tertiary: MontColors.tertiary,
      surface: MontColors.surface,
      onPrimary: MontColors.background,
      onSecondary: MontColors.background,
      onSurface: MontColors.textPrimary,
      error: MontColors.error,
      outline: MontColors.textSecondary,
    ),
    scaffoldBackgroundColor: MontColors.background,
    cardColor: MontColors.surface,
    dividerColor: MontColors.textSecondary.withValues(alpha: 0.2),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: MontColors.textPrimary),
      bodyMedium: TextStyle(color: MontColors.textPrimary),
      bodySmall: TextStyle(color: MontColors.textSecondary),
      titleLarge: TextStyle(color: MontColors.textPrimary),
      titleMedium: TextStyle(color: MontColors.textPrimary),
      titleSmall: TextStyle(color: MontColors.textSecondary),
    ),
  );
}
