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

// ignore: unused_import
import '../api.dart' as api;
import 'activity_list.dart';
import 'auth.dart';
import 'chunked_protocol.dart';
import 'settings.dart';
import 'sports_parser.dart';

enum SyncStatus { idle, requestingPermissions, scanning, connecting, authenticating, syncing, done, error }

class WatchSyncService {
  WatchSyncService();

  SyncStatus _status = SyncStatus.idle;
  String _message = '';
  int _syncedCount = 0;
  int _scannedCount = 0;
  String? _lastError;

  SyncStatus get status => _status;
  String get message => _message;
  int get syncedCount => _syncedCount;
  int get scannedCount => _scannedCount;
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
    _scannedCount = 0;
    _lastError = null;

    try {
      await _sync();
    } catch (e, st) {
      print('[BLE] sync error: $e\n$st');
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
    // Try reconnecting to previously saved device first.
    final savedId = await loadDeviceRemoteId();
    if (savedId != null) {
      final connected = FlutterBluePlus.connectedDevices;
      for (final d in connected) {
        if (d.remoteId.str == savedId) return d;
      }
      return BluetoothDevice(remoteId: DeviceIdentifier(savedId));
    }

    // Check already bonded (OS-paired) devices — fastest path.
    final bonded = await FlutterBluePlus.bondedDevices;
    for (final d in bonded) {
      final name = d.platformName.toLowerCase();
      if (name.contains('amazfit') || name.contains('cheetah')) {
        await saveDeviceRemoteId(d.remoteId.str);
        return d;
      }
    }

    // Fall back to scanning.
    _notify(SyncStatus.scanning, 'Scanning for Amazfit Cheetah Pro…');
    final Completer<BluetoothDevice> found = Completer();
    StreamSubscription<List<ScanResult>>? sub;

    sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.toLowerCase();
        final serviceMatch = r.advertisementData.serviceUuids
            .any((u) => u.str.toLowerCase() == BleUuids.service);
        if (serviceMatch || name.contains('amazfit') || name.contains('cheetah')) {
          if (!found.isCompleted) found.complete(r.device);
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));

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
    BluetoothCharacteristic? writeChar;   // 0x0016
    BluetoothCharacteristic? notifyChar;  // 0x0017
    BluetoothCharacteristic? dataChar;    // 0x0005 (raw data stream)

    for (final s in services) {
      for (final c in s.characteristics) {
        final uuid = c.uuid.str.toLowerCase();
        if (uuid == BleUuids.auth) authChar = c;
        if (uuid == BleUuids.chunkedWrite) writeChar = c;
        if (uuid == BleUuids.chunkedNotify) notifyChar = c;
        if (uuid == BleUuids.dataStream) dataChar = c;
      }
    }

    if (authChar == null || writeChar == null || notifyChar == null) {
      final found = services.map((s) => s.uuid.str).join(', ');
      throw Exception('Required BLE characteristics not found.\nServices: $found\nauthChar=$authChar writeChar=$writeChar notifyChar=$notifyChar');
    }

    // Subscribe to auth notifications.
    await authChar.setNotifyValue(true);
    // Subscribe to command responses (0x0017).
    await notifyChar.setNotifyValue(true);
    // Subscribe to raw data stream (0x0005) if present.
    if (dataChar != null) {
      await dataChar.setNotifyValue(true);
    }

    // Start buffering 0x0017 events immediately so we don't miss responses.
    final notifyEvents = <List<int>>[];
    Completer<void>? notifyWaiter;
    final notifySub = notifyChar.onValueReceived.listen((v) {
      notifyEvents.add(v);
      notifyWaiter?.complete();
      notifyWaiter = null;
    });

    // Buffer raw data stream events (0x0005).
    final dataEvents = <List<int>>[];
    Completer<void>? dataWaiter;
    StreamSubscription<List<int>>? dataSub;
    if (dataChar != null) {
      dataSub = dataChar.onValueReceived.listen((v) {
        dataEvents.add(v);
        dataWaiter?.complete();
        dataWaiter = null;
      });
    }

    // ── Auth handshake ───────────────────────────────────────────────────────
    _notify(SyncStatus.authenticating, 'Authenticating…');
    await _authenticate(authChar, deviceKey);
    if (_cancelled) {
      await notifySub.cancel();
      await dataSub?.cancel();
      return;
    }

    // ── Sync activities ──────────────────────────────────────────────────────
    _notify(SyncStatus.syncing, 'Fetching activity list…');
    try {
      await _syncActivities(
        writeChar,
        notifyEvents,
        (w) => notifyWaiter = w,
        dataEvents,
        (w) => dataWaiter = w,
      );
    } finally {
      await notifySub.cancel();
      await dataSub?.cancel();
    }
  }

  Future<void> _authenticate(BluetoothCharacteristic authChar, Uint8List deviceKey) async {
    // Manual queue so no notification is ever dropped, regardless of timing.
    final events = <List<int>>[];
    Completer<void>? waiter;

    final sub = authChar.onValueReceived.listen((v) {
      events.add(v);
      waiter?.complete();
      waiter = null;
    });

    Future<Uint8List> next({Duration timeout = const Duration(seconds: 10)}) async {
      if (events.isNotEmpty) return Uint8List.fromList(events.removeAt(0));
      waiter = Completer<void>();
      await waiter!.future.timeout(timeout, onTimeout: () {
        throw Exception('Auth timed out waiting for watch response.');
      });
      return Uint8List.fromList(events.removeAt(0));
    }

    try {
      await authChar.write(buildAuthRequest(), withoutResponse: false);

      final resp1 = await next();
      print('[BLE] Auth response bytes: ${resp1.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      if (isAuthSuccess(resp1)) return;

      // ZeppOS 3.x: watch sends [10 01 03 ...] = "send me the encrypted key".
      // Older firmware: sends a 16-byte nonce.
      final Uint8List? nonce = isAuthSendKeyRequest(resp1) ? null : parseAuthNonce(resp1);

      final response = buildAuthResponsePayload(nonce, deviceKey);
      print('[BLE] Sending auth response: ${response.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      await authChar.write(response, withoutResponse: false);

      final resp2 = await next();
      print('[BLE] Auth result bytes: ${resp2.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      if (isAuthSuccess(resp2)) return;
      if (resp2.length >= 3 && resp2[0] == 0x10 && resp2[2] == 0x02) {
        throw Exception('Authentication failed — wrong device key.');
      }
      throw Exception('Unexpected auth response: ${resp2.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _syncActivities(
    BluetoothCharacteristic writeChar,
    List<List<int>> notifyEvents,
    void Function(Completer<void>?) setNotifyWaiter,
    List<List<int>> dataEvents,
    void Function(Completer<void>?) setDataWaiter,
  ) async {
    int seq = 0;

    Future<Uint8List> receiveResponse({Duration timeout = const Duration(seconds: 15)}) async {
      while (true) {
        if (notifyEvents.isNotEmpty) {
          return Uint8List.fromList(notifyEvents.removeAt(0));
        }
        final waiter = Completer<void>();
        setNotifyWaiter(waiter);
        await waiter.future.timeout(
          timeout,
          onTimeout: () => throw Exception('Timed out waiting for watch response (0x0017).'),
        );
      }
    }

    Future<void> send(Uint8List packet) async {
      print('[BLE] TX: ${packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      await writeChar.write(packet, withoutResponse: true);
      seq = (seq + 1) & 0xff;
    }

    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

    // Fetch all workouts in a loop. Each iteration gets the oldest remaining
    // workout. After ACK, re-request from (lastStart + 1 s) to advance.
    var sinceYear = 2000;
    var sinceMonth = 1;
    var sinceDay = 1;
    var sinceHour = 0;
    var sinceMin = 0;
    var sinceSec = 0;

    while (true) {
      if (_cancelled) return;

      // ── 1. Request next workout ───────────────────────────────────────────
      await send(buildSportsFetchRequest(
        seq,
        sinceYear: sinceYear, sinceMonth: sinceMonth, sinceDay: sinceDay,
        sinceHour: sinceHour, sinceMin: sinceMin, sinceSec: sinceSec,
      ));
      final rawResp = await receiveResponse();
      print('[BLE] RX: ${hex(rawResp)}');

      final (int ep, Uint8List payload) = decodeHuami2021(rawResp);
      print('[BLE] Decoded endpoint=0x${ep.toRadixString(16)} payload=${hex(payload)}');

      final fetchResp = parseFetchResponse(payload);
      if (fetchResp == null) {
        throw Exception('Unexpected fetch response: ${hex(payload)}');
      }
      print('[BLE] Fetch: count=${fetchResp.count} ts=${fetchResp.sinceTimestamp}');

      if (!fetchResp.hasData) break; // no more workouts

      // Show the date of the workout being downloaded.
      final ts = fetchResp.sinceTimestamp;
      final dateLabel = ts != null
          ? '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}'
          : '…';
      _scannedCount++;
      _notify(SyncStatus.syncing,
          'Scanning #$_scannedCount  ($dateLabel)\n'
          '$_syncedCount run(s) imported so far');

      // ── 2. Start transfer ─────────────────────────────────────────────────
      await send(buildStartTransfer(seq));

      // ── 3. Collect data on 0x0005 until transfer-complete on 0x0017 ──────
      final rawDataChunks = <List<int>>[];
      while (true) {
        while (dataEvents.isNotEmpty) {
          rawDataChunks.add(dataEvents.removeAt(0));
        }
        if (notifyEvents.isNotEmpty) {
          final packet = Uint8List.fromList(notifyEvents.removeAt(0));
          print('[BLE] RX: ${hex(packet)}');
          if (packet.length >= 11) {
            final (int ep2, Uint8List p2) = decodeHuami2021(packet);
            if (ep2 == BleEndpoints.huamiData && p2.length >= 2 && p2[0] == 0x10 && p2[1] == 0x02) {
              print('[BLE] Transfer complete. Chunks: ${rawDataChunks.length}');
              break;
            }
          }
          continue;
        }
        final waiter = Completer<void>();
        setDataWaiter(waiter);
        setNotifyWaiter(waiter);
        await waiter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw Exception('Timed out waiting for data transfer.'),
        );
      }

      // ── 4. ACK (keep on watch — safe to re-sync) ──────────────────────────
      await send(buildAckTransfer(seq, deleteFromWatch: false));
      final ackResp = await receiveResponse();
      print('[BLE] ACK response: ${hex(ackResp)}');

      // ── 5. Parse and upload ───────────────────────────────────────────────
      int totalBytes = rawDataChunks.fold(0, (s, c) => s + c.length);
      print('[BLE] Total raw data: $totalBytes B in ${rawDataChunks.length} chunks');

      final summary = parseSportsSummary(rawDataChunks);
      if (summary == null) {
        // Parsing failed — dump hex for diagnosis, then advance past this
        // workout using the timestamp the watch reported in the fetch response.
        final assembled = rawDataChunks
            .where((c) => c.length >= 2)
            .expand((c) => c.skip(1))
            .toList();
        print('[BLE] Parse failed. Raw assembled (${assembled.length} B): '
            '${assembled.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        // Fall back: advance 24 h past the reported workout timestamp so we
        // don't loop forever on an unparseable workout.
        final fallback = (fetchResp.sinceTimestamp ?? DateTime.now().toUtc())
            .add(const Duration(hours: 24));
        sinceYear  = fallback.year;
        sinceMonth = fallback.month;
        sinceDay   = fallback.day;
        sinceHour  = fallback.hour;
        sinceMin   = fallback.minute;
        sinceSec   = fallback.second;
      } else {
        print('[BLE] sport_type=${summary.sportType} start=${summary.startTime} '
            'dur=${summary.durationSeconds}s dist=${summary.distanceMeters}m '
            'avgHr=${summary.avgHr}');

        if (summary.isOutdoorRun) {
          final startedAt = summary.startTime.toIso8601String();
          await api.importBleSummary(
            startedAt: startedAt,
            durationSeconds: summary.durationSeconds,
            distanceMeters: summary.distanceMeters,
            avgHr: summary.avgHr,
            maxHr: summary.maxHr,
          );
          _syncedCount++;
        } else {
          print('[BLE] Skipping non-outdoor-run (sport_type=${summary.sportType})');
        }

        // Advance "since" past the END of this workout so the next fetch
        // request returns the following workout. Use at least 1 h to guard
        // against a zero/missing duration causing an infinite loop.
        final advanceSecs = summary.durationSeconds > 60
            ? summary.durationSeconds + 1
            : 3600;
        final next = summary.startTime.add(Duration(seconds: advanceSecs));
        sinceYear  = next.year;
        sinceMonth = next.month;
        sinceDay   = next.day;
        sinceHour  = next.hour;
        sinceMin   = next.minute;
        sinceSec   = next.second;
      }
    }

    if (_syncedCount == 0) {
      _notify(SyncStatus.done, 'No outdoor runs found on watch.');
    } else {
      _notify(SyncStatus.done, 'Synced $_syncedCount outdoor run(s).');
    }
  }
}
