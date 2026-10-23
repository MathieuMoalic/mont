/// No-op stub for platforms without BLE support (web, tests).
///
/// The real implementation lives in `ble_relay_io.dart`.
library;

Future<void> autoSyncIfTriggered() async {}

Future<String> startManualSync() async =>
    throw UnsupportedError('BLE not supported on this platform');

Future<void> autoSyncOnAppOpen() async {}

Future<Map<String, dynamic>> runTransferSession({
  required List<Map<String, dynamic>> actions,
}) async => throw UnsupportedError('BLE not supported on this platform');

class ActiveWatchTransfer {
  Future<Map<String, dynamic>> release(List<Map<String, dynamic>> actions) =>
      throw UnsupportedError('BLE not supported on this platform');

  bool get isAlive => false;
}

Future<Map<String, dynamic>> startHeldWatchTransfer({
  required List<Map<String, dynamic>> actions,
}) async => throw UnsupportedError('BLE not supported on this platform');

ActiveWatchTransfer? activeWatchTransfer;
