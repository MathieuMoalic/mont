/// Stub for platforms without the map installer (web, tests).
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform, kIsWeb;

class WatchMapInstaller {
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> installFromZip({
    required Uint8List zipBytes,
    required String ssid,
    required String password,
    required void Function(String line) log,
  }) async =>
      throw UnsupportedError('Map install not supported on this platform');
}
