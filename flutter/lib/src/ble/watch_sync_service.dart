// Top-level BLE watch sync service for the Amazfit Cheetah Pro.
//
// Usage:
//   final service = WatchSyncService();
//   service.addListener(() => setState((){}));
//   await service.sync();

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart' as api;
import 'activity_list.dart';
import 'auth.dart';
import 'chunked_protocol.dart';
import 'file_transfer.dart';
import 'settings.dart';

enum SyncStatus { idle, requestingPermissions, scanning, connecting, authenticating, syncing, done, error }

class WatchSyncService {
  WatchSyncService();

  SyncStatus _status = SyncStatus.idle;
  String _message = '';
  int _syncedCount = 0;
  String? _lastError;

  SyncStatus get status => _status;
  String get message => _message;
  int get syncedCount => _syncedCount;
  String? get lastError => _lastError;
  bool get isRunning => _status != SyncStatus.idle &&
      _status != SyncStatus.done &&
      _status != SyncStatus.error;

  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify(SyncStatus status, String message) {
    _status = status;
    _message = message;
    for (final l in _listeners) {
      l();
    }
  }

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
  }

  /// Run a full sync cycle. Reads device key and remote ID from stored settings.
  Future<void> sync() async {
    _cancelled = false;
    _syncedCount = 0;
    _lastError = null;

    try {
      await _sync();
    } catch (e) {
      _lastError = e.toString();
      _notify(SyncStatus.error, 'Error: $e');
    }
  }

  Future<void> _sync() async {
    // ── 1. Load stored settings ──────────────────────────────────────────────
    final keyHex = await loadDeviceKeyHex();
    if (keyHex == null || keyHex.isEmpty) {
      throw Exception('Device key not configured. Go to Settings to add your watch key.');
    }
    final deviceKeyBytes = Uint8List.fromList(hexToBytes(keyHex));

    // ── 2. Request BLE permissions ───────────────────────────────────────────
    _notify(SyncStatus.requestingPermissions, 'Requesting permissions…');
    await _requestBlePermissions();
    if (_cancelled) return;

    // ── 3. Find the device ───────────────────────────────────────────────────
    final BluetoothDevice device = await _findDevice();
    if (_cancelled) return;

    // ── 4. Connect ───────────────────────────────────────────────────────────
    _notify(SyncStatus.connecting, 'Connecting to ${device.advName}…');
    await device.connect(timeout: const Duration(seconds: 15));
    if (_cancelled) {
      await device.disconnect();
      return;
    }

    try {
      await _runSession(device, deviceKeyBytes);
    } finally {
      await device.disconnect();
    }
  }

  Future<void> _requestBlePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    for (final entry in statuses.entries) {
      if (!entry.value.isGranted) {
        throw Exception('Permission ${entry.key} denied. Please grant it in system settings.');
      }
    }
  }

  Future<BluetoothDevice> _findDevice() async {
    // Try reconnecting to previously paired device first.
    final savedId = await loadDeviceRemoteId();
    if (savedId != null) {
      final connected = FlutterBluePlus.connectedDevices;
      for (final d in connected) {
        if (d.remoteId.str == savedId) return d;
      }
      // Not currently connected but we know the ID — return a handle directly.
      return BluetoothDevice(remoteId: DeviceIdentifier(savedId));
    }

    // Scan for the watch by service UUID.
    _notify(SyncStatus.scanning, 'Scanning for Amazfit Cheetah Pro…');
    final Completer<BluetoothDevice> found = Completer();
    StreamSubscription<List<ScanResult>>? sub;

    sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.advertisementData.serviceUuids
                .any((u) => u.str.toLowerCase() == BleUuids.service) ||
            r.advertisementData.advName.toLowerCase().contains('cheetah')) {
          if (!found.isCompleted) found.complete(r.device);
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(BleUuids.service)],
      timeout: const Duration(seconds: 20),
    );

    try {
      final device = await found.future.timeout(const Duration(seconds: 22));
      await saveDeviceRemoteId(device.remoteId.str);
      return device;
    } on TimeoutException {
      throw Exception('Watch not found. Make sure Bluetooth is on and the watch is nearby.');
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _runSession(BluetoothDevice device, Uint8List deviceKey) async {
    // ── Discover services ────────────────────────────────────────────────────
    final services = await device.discoverServices();
    BluetoothCharacteristic? authChar;
    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? notifyChar;

    for (final s in services) {
      if (s.uuid.str.toLowerCase() != BleUuids.service) continue;
      for (final c in s.characteristics) {
        final uuid = c.uuid.str.toLowerCase();
        if (uuid == BleUuids.auth) authChar = c;
        if (uuid == BleUuids.chunkedWrite) writeChar = c;
        if (uuid == BleUuids.chunkedNotify) notifyChar = c;
      }
    }

    if (authChar == null || writeChar == null || notifyChar == null) {
      throw Exception('Required BLE characteristics not found. Is this the right device?');
    }

    // ── Subscribe to notifications ───────────────────────────────────────────
    await notifyChar.setNotifyValue(true);
    await authChar.setNotifyValue(true);

    // ── Auth handshake ───────────────────────────────────────────────────────
    _notify(SyncStatus.authenticating, 'Authenticating…');
    await _authenticate(authChar, deviceKey);
    if (_cancelled) return;

    // ── Sync activities ──────────────────────────────────────────────────────
    _notify(SyncStatus.syncing, 'Fetching activity list…');
    await _syncActivities(writeChar, notifyChar);
  }

  Future<void> _authenticate(BluetoothCharacteristic authChar, Uint8List deviceKey) async {
    // Send challenge request
    await authChar.write(buildAuthRequest(), withoutResponse: false);

    // Wait for nonce notification
    Uint8List? nonce;
    await for (final value in authChar.onValueReceived.timeout(const Duration(seconds: 10))) {
      final bytes = Uint8List.fromList(value);
      nonce = parseAuthNonce(bytes);
      if (nonce != null) break;
      if (isAuthSuccess(bytes)) return; // Already authed (some firmwares skip nonce)
    }

    if (nonce == null) throw Exception('Auth timed out waiting for challenge from watch.');

    // Send encrypted response
    final response = buildAuthResponsePayload(nonce, deviceKey);
    await authChar.write(response, withoutResponse: false);

    // Wait for success
    await for (final value in authChar.onValueReceived.timeout(const Duration(seconds: 10))) {
      if (isAuthSuccess(Uint8List.fromList(value))) return;
    }
    throw Exception('Authentication failed. Check that the device key is correct.');
  }

  Future<void> _syncActivities(
    BluetoothCharacteristic writeChar,
    BluetoothCharacteristic notifyChar,
  ) async {
    int seq = 0;

    Future<Uint8List> receiveChunked() async {
      final reader = ChunkedReader();
      await for (final value in notifyChar.onValueReceived.timeout(const Duration(seconds: 30))) {
        if (reader.feed(Uint8List.fromList(value))) return reader.take();
      }
      throw Exception('Chunked receive timed out.');
    }

    Future<void> sendChunked(List<Uint8List> packets) async {
      for (final p in packets) {
        await writeChar.write(p, withoutResponse: true);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      seq++;
    }

    // Request activity list (up to 50 recent activities)
    await sendChunked(buildActivityListRequest(50, seq));
    final listPayload = await receiveChunked();
    final activities = parseActivityListResponse(listPayload);

    if (activities.isEmpty) {
      _notify(SyncStatus.done, 'No new activities found.');
      return;
    }

    _notify(SyncStatus.syncing, 'Found ${activities.length} activities. Downloading…');

    for (int i = 0; i < activities.length; i++) {
      if (_cancelled) return;
      final activity = activities[i];
      _notify(SyncStatus.syncing, 'Downloading activity ${i + 1}/${activities.length}…');

      // Request FIT file
      await sendChunked(buildFileRequest(activity.fileId, seq));
      final fitBytes = await receiveChunked();

      // Upload to backend
      try {
        await api.importFit(fitBytes);
        _syncedCount++;
      } catch (e) {
        // Non-fatal: log and continue (e.g. duplicate already imported)
        _notify(SyncStatus.syncing, 'Skipped activity ${i + 1}: $e');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    _notify(SyncStatus.done, 'Synced $_syncedCount/${activities.length} activities.');
  }
}
