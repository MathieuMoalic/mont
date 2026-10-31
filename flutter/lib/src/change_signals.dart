import 'package:flutter/foundation.dart';

/// Cross-tab reload signals. The home tabs live in an IndexedStack, so a
/// screen isn't reinitialised when shown again: writers bump a version after
/// changing shared data, and the owning screen reloads in response.
final ValueNotifier<int> healthDataVersion = ValueNotifier(0);
