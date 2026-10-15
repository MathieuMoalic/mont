/// No-op stub for platforms without BLE support (web, tests).
///
/// The real implementation lives in `ble_relay_io.dart`.
library;

Future<void> autoSyncIfTriggered() async {}

Future<String> startManualSync() async =>
    throw UnsupportedError('BLE not supported on this platform');

Future<void> autoSyncOnAppOpen() async {}
