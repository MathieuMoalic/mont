import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode, Platform;

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kDebugMode;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart' as api;
import '../auth.dart' as auth;
import '../watch_map_install.dart' as watch_map_install;

/// Runs a BLE relay session when the debug trigger file exists.
///
/// The trigger (`ble_auto.json` in the app documents dir) is created via
/// `adb shell run-as`, so this can only happen on debug builds and is the
/// entry point for unattended, hardware-in-the-loop debugging. The file is
/// consumed on launch; the app then continues to start normally.
/// Fired when a background sync session completes (app-open sync) so
/// listeners such as the Morning tab can reload.
final ValueNotifier<DateTime> lastSyncCompleted = ValueNotifier(
  DateTime.fromMillisecondsSinceEpoch(0),
);

Future<void> autoSyncIfTriggered() async {
  if (!kDebugMode) return;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final trigger = File('${dir.path}/ble_auto.json');
    if (!await trigger.exists()) return;

    Map<String, dynamic> cfg = {};
    try {
      cfg = jsonDecode(await trigger.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // malformed trigger: run with defaults
    }
    await trigger.delete();

    // Map install: build tiles on the backend from a GPX stored in the app
    // documents dir, then auto-transfer them over the watch hotspot + FTP.
    final mapInstall = cfg['map_install'] as Map<String, dynamic>?;
    if (mapInstall != null) {
      _mapInstallRunning = true;
      unawaited(_triggeredMapInstall(mapInstall, dir.path));
      return;
    }

    final timeoutSecs = (cfg['timeout_s'] as num?)?.toInt() ?? 240;
    final controls = (cfg['controls'] as List?)
        ?.whereType<Map<String, dynamic>>()
        .toList();
    Map<String, dynamic> outcome;
    if (controls != null && controls.isNotEmpty) {
      // Watch-control session (Wi-Fi hotspot / FTP) instead of a sync.
      // Block app-open syncs for the whole session: the GATT link serves
      // one session at a time, and a held session outlives its actions
      // (the flag clears in the relay session's _finish).
      _watchBusy = true;
      if (cfg['hold'] == true) {
        outcome = await startHeldWatchTransfer(
          actions: controls,
          timeout: Duration(seconds: timeoutSecs),
        );
      } else {
        _watchBusy = false;
        outcome = await runTransferSession(
          actions: controls,
          timeout: Duration(seconds: timeoutSecs),
        );
      }
    } else {
      outcome = await runRelaySession(
        timeout: Duration(seconds: timeoutSecs),
        source: 'adb',
      );
    }

    await File(
      '${dir.path}/ble_last_result.json',
    ).writeAsString(jsonEncode(outcome));
    // Grep targets for the adb debug loop.
    // ignore: avoid_print
    print('BLE_SYNC_RESULT: ${outcome['status']} reason=${outcome['reason']}');
    if (outcome['controls_results'] != null) {
      // ignore: avoid_print
      print('BLE_CONTROLS_RESULT: ${jsonEncode(outcome['controls_results'])}');
    }
  } catch (e) {
    // ignore: avoid_print
    print('BLE_SYNC_RESULT: fail reason=exception error=$e');
  }
}

/// Manual sync for the debug tab: connects to the watch through the backend
/// and returns a one-line outcome.
Future<String> startManualSync() async {
  final outcome = await runRelaySession(
    timeout: const Duration(minutes: 20),
    source: 'manual',
  );
  await _writeLastResult(outcome);
  return '${outcome['status']} (${outcome['reason']}, phase: ${outcome['phase']}, '
      'notify frames: ${outcome['notify_frames']})';
}

/// Automatically syncs the watch when the app is opened. Runs in the
/// background (the UI is already up); skipped when the last sync attempt was
/// less than 10 minutes ago, on non-BLE platforms, or when not logged in.
Future<void> autoSyncOnAppOpen() async {
  if (!kDebugMode && !Platform.isAndroid && !Platform.isIOS) return;
  if (_mapInstallRunning || _watchBusy) return; // watch is busy
  if (auth.Auth.refreshToken == null || auth.Auth.refreshToken!.isEmpty) {
    return;
  }
  try {
    final dir = await getApplicationDocumentsDirectory();
    final resultFile = File('${dir.path}/ble_last_result.json');
    if (await resultFile.exists()) {
      final last =
          jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
      final finished = DateTime.tryParse(last['finished_at'] as String? ?? '');
      if (finished != null &&
          DateTime.now().difference(finished) < const Duration(minutes: 10)) {
        return;
      }
    }
    final outcome = await runRelaySession(
      timeout: const Duration(minutes: 20),
      source: 'app_open',
    );
    await _writeLastResult(outcome);
    lastSyncCompleted.value = DateTime.now();
    // Grep target for the adb debug loop.
    // ignore: avoid_print
    print('BLE_SYNC_RESULT: ${outcome['status']} reason=${outcome['reason']}');
  } catch (e) {
    // ignore: avoid_print
    print('BLE_SYNC_RESULT: fail reason=exception error=$e');
  }
}

/// Debug trigger for the fully automated map install: builds tiles on the
/// backend from a GPX stored in the app documents dir, then transfers them
/// over the watch hotspot + FTP (held BLE session, Wi-Fi join, upload).
/// Trigger JSON: `{"map_install": {"gpx": "test.gpx", "ssid": "…",
/// "password": "…", "style": "cheetah-topo"}}`.
Future<void> _triggeredMapInstall(
  Map<String, dynamic> cfg,
  String docsPath,
) async {
  // Log to stdout (logcat) AND a file — the main logcat buffer rotates fast
  // under BLE debug spam, so the file is the reliable record.
  final logFile = File('$docsPath/map_install.log');
  void log(String msg) {
    // Grep target for the adb debug loop.
    // ignore: avoid_print
    print('MAP_INSTALL: $msg');
    try {
      logFile.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  try {
    final gpxName = (cfg['gpx'] as String?) ?? 'test.gpx';
    final ssid = (cfg['ssid'] as String?) ?? 'mont-hotspot';
    final password = (cfg['password'] as String?) ?? 'transfer123';
    final style = (cfg['style'] as String?) ?? 'cheetah-topo';

    final gpxBytes = await File('$docsPath/$gpxName').readAsBytes();
    log('GPX loaded (${gpxBytes.length} bytes), building tiles…');

    final jobId = await api.startMapJob(gpxBytes, gpxName, style: style);
    Map<String, dynamic> job;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      job = await api.getMapJob(jobId);
      for (final line in (job['logs'] as List? ?? const [])) {
        log('build | $line');
      }
      final status = (job['status'] ?? '') as String;
      if (status == 'done') {
        log('Build done');
        break;
      }
      if (status == 'error') {
        throw Exception('Build failed: ${job['error'] ?? 'unknown'}');
      }
    }

    final zipBytes = await api.downloadMapZip(jobId);
    log('ZIP downloaded (${zipBytes.length} bytes)');

    await watch_map_install.WatchMapInstaller.installFromZip(
      zipBytes: zipBytes,
      ssid: ssid,
      password: password,
      log: log,
    );
    // Grep target for the adb debug loop.
    // ignore: avoid_print
    print('MAP_RESULT: ok');
  } catch (e) {
    // Grep target for the adb debug loop.
    // ignore: avoid_print
    print('MAP_RESULT: fail error=$e');
  }
}

Future<void> _writeLastResult(Map<String, dynamic> outcome) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    await File(
      '${dir.path}/ble_last_result.json',
    ).writeAsString(jsonEncode(outcome));
  } catch (_) {}
}

/// Connects to the backend relay WebSocket and relays GATT traffic until the
/// backend shuts the session down or the timeout expires. `source` records
/// what triggered the sync (shown in the Settings sync history).
Future<Map<String, dynamic>> runRelaySession({
  required Duration timeout,
  String source = 'sync',
}) async {
  final refreshed = await auth.Auth.tryRefresh();
  if (!refreshed || auth.Auth.token == null) {
    return {'status': 'fail', 'reason': 'no_auth'};
  }
  final wsBase = api.baseUrl.replaceFirst('http', 'ws');
  final wsUrl = '$wsBase/ble/ws?token=${auth.Auth.token}&source=$source';
  final session = _RelaySession(wsUrl, timeout);
  return session.run();
}

/// Runs a watch-control session: connects to the watch and executes the
/// given actions (Wi-Fi hotspot / FTP server toggles) via the backend. The
/// returned outcome carries `controls_results` — one entry per action, with
/// the FTP `address`/`username` on a successful FTP start.
///
/// With `hold: true` the session stays connected afterwards (the watch drops
/// the hotspot when the BLE link goes down); call [releaseWatchTransfer] on
/// the returned handle to run the stop actions and release the watch.
Future<Map<String, dynamic>> runTransferSession({
  required List<Map<String, dynamic>> actions,
  Duration timeout = const Duration(seconds: 150),
}) async {
  final refreshed = await auth.Auth.tryRefresh();
  if (!refreshed || auth.Auth.token == null) {
    return {'status': 'fail', 'reason': 'no_auth'};
  }
  final wsBase = api.baseUrl.replaceFirst('http', 'ws');
  final wsUrl = '$wsBase/ble/ws?token=${auth.Auth.token}&source=transfer';
  final session = _RelaySession(wsUrl, timeout, controls: actions);
  return session.run();
}

/// A live held transfer session (hotspot + FTP running on the watch).
/// [release] runs the given stop actions on the same link and releases the
/// watch. The handle dies if the session times out or the socket drops.
class ActiveWatchTransfer {
  final _RelaySession _session;

  ActiveWatchTransfer._(this._session);

  /// Whether the underlying session is still alive.
  bool get isAlive => !_session.finished;

  Future<Map<String, dynamic>> release(List<Map<String, dynamic>> actions) {
    return _session.runMore(actions, release: true);
  }
}

/// Starts a held transfer session: runs `actions` (typically hotspot_start +
/// ftp_start) and keeps the watch connected so the hotspot stays up — the
/// watch tears the hotspot down when the BLE link drops, so the session is
/// held open (max 15 min) until [ActiveWatchTransfer.release] is called.
///
/// Resolves with the outcome of the start actions (carrying the FTP
/// `address`/`username`) as soon as the watch confirms them.
Future<Map<String, dynamic>> startHeldWatchTransfer({
  required List<Map<String, dynamic>> actions,
  Duration timeout = const Duration(minutes: 15),
}) async {
  final refreshed = await auth.Auth.tryRefresh();
  if (!refreshed || auth.Auth.token == null) {
    return {'status': 'fail', 'reason': 'no_auth'};
  }
  final wsBase = api.baseUrl.replaceFirst('http', 'ws');
  final wsUrl = '$wsBase/ble/ws?token=${auth.Auth.token}&source=transfer';
  final session = _RelaySession(wsUrl, timeout, controls: actions, hold: true);
  activeWatchTransfer = ActiveWatchTransfer._(session);
  unawaited(
    session.run().catchError(
      (Object _) => <String, dynamic>{'status': 'fail', 'reason': 'exception'},
    ),
  );
  return session.firstResult.future;
}

/// The live held transfer session, if any (survives screen navigation).
ActiveWatchTransfer? activeWatchTransfer;

/// Set while the adb-triggered map install runs (blocks app-open syncs).
bool _mapInstallRunning = false;

/// Set while any adb-triggered watch session (controls/transfer) runs —
/// the GATT link serves one session at a time.
bool _watchBusy = false;

class _RelaySession {
  final String wsUrl;
  final Duration timeout;

  /// Non-empty: watch-control session — actions run by the backend after
  /// connecting; with [hold] the session stays open for further runs.
  final List<Map<String, dynamic>> controls;
  final bool hold;

  WebSocketChannel? _ws;
  BluetoothDevice? _device;
  final List<StreamSubscription<dynamic>> _subs = [];
  final Map<String, bool> _scanSeen = {}; // mac -> hasName
  Timer? _deadline;
  Timer? _flushTimer;
  Completer<Map<String, dynamic>>? _done;
  List<Map<String, dynamic>>? _controlsResults;
  Completer<Map<String, dynamic>>? _runMoreDone;

  final List<Map<String, dynamic>> _pendingNotify = [];
  Future<void> _handling = Future.value();

  bool _finished = false;
  bool _disconnectRequested = false;
  String _phase = 'starting';
  String? _deviceMac;
  int _notifyFrames = 0;
  int _notifyBytes = 0;
  int _framesSent = 0;

  _RelaySession(
    this.wsUrl,
    this.timeout, {
    this.controls = const [],
    this.hold = false,
  });

  /// Held sessions: resolves with the first `controls_result` while the
  /// session keeps running.
  final Completer<Map<String, dynamic>> firstResult =
      Completer<Map<String, dynamic>>();

  /// Whether the session has ended (timeout, socket loss, release).
  bool get finished => _finished;

  Future<Map<String, dynamic>> run() async {
    _done = Completer<Map<String, dynamic>>();
    try {
      final ws = WebSocketChannel.connect(Uri.parse(wsUrl));
      _ws = ws;
      await ws.ready.timeout(const Duration(seconds: 15));
      _log('ws connected to $wsUrl');

      ws.stream.listen(
        (frame) {
          final text = frame is String
              ? frame
              : utf8.decode(frame as List<int>);
          _onServerFrame(text);
        },
        onDone: () => _finish(ok: false, reason: 'ws_closed_by_server'),
        onError: (Object e) => _finish(ok: false, reason: 'ws_error:$e'),
      );

      _sendEvent({
        'k': 'hello',
        'platform': Platform.operatingSystem,
        if (controls.isNotEmpty) ...{'controls': controls, 'hold': hold},
      });

      _subs.add(FlutterBluePlus.scanResults.listen(_onScanResults));
      _deadline = Timer(timeout, () => _finish(ok: false, reason: 'timeout'));

      return await _done!.future;
    } catch (e) {
      _log('run() failed: $e');
      return {
        'status': 'fail',
        'reason': 'exception',
        'error': '$e',
        'phase': _phase,
      };
    } finally {
      await _cleanup();
    }
  }

  // ── server frames ─────────────────────────────────────────────────────────

  void _onServerFrame(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      _log('unparseable server frame: $text');
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    // Serialize command handling to preserve order.
    _handling = _handling.then(
      (_) => _handleCommand(decoded),
      onError: (Object e) => _log('command handler error: $e'),
    );
  }

  Future<void> _handleCommand(Map<String, dynamic> cmd) async {
    final id = (cmd['id'] as num?)?.toInt() ?? 0;
    final k = cmd['k'] as String?;
    try {
      switch (k) {
        case 'scan_start':
          await _ensurePermissions();
          _scanSeen.clear();
          await FlutterBluePlus.stopScan();
          await FlutterBluePlus.startScan(
            timeout: null,
            continuousUpdates: true,
          );
          _phase = 'scanning';
          _ack(id, true);
        case 'scan_stop':
          await FlutterBluePlus.stopScan();
          _ack(id, true);
        case 'connect':
          await _connect(cmd['mac'] as String);
          _ack(id, true);
        case 'disconnect_device':
          _disconnectRequested = true;
          await _disconnectDevice();
          _ack(id, true);
        case 'subscribe':
          await _subscribe(cmd['char_uuid'] as String);
          _ack(id, true);
        case 'request_mtu':
          final mtu = (cmd['mtu'] as num).toInt();
          final negotiated = await _requireDevice().requestMtu(mtu);
          _sendEvent({'k': 'mtu', 'mtu': negotiated});
          _ack(id, true);
        case 'write':
          await _write(
            cmd['char_uuid'] as String,
            base64Decode(cmd['data'] as String),
            withoutResponse: cmd['without_response'] == true,
          );
          _ack(id, true);
        case 'controls_result':
          _controlsResults = (cmd['results'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          final result = {
            'status': 'ok',
            'reason': 'controls_done',
            'controls_results': _controlsResults,
          };
          if (hold) {
            // Held session: the watch stays connected. The first result
            // resolves the caller; later ones resolve `runMore` calls.
            if (!firstResult.isCompleted) {
              firstResult.complete(result);
            } else if (_runMoreDone != null && !_runMoreDone!.isCompleted) {
              _runMoreDone!.complete(result);
            }
          } else {
            _finish(ok: true, reason: 'controls_done');
          }
        case 'shutdown':
          _finish(ok: true, reason: 'shutdown:${cmd['reason'] ?? ''}');
        default:
          _log('unknown command: $k');
          _ack(id, false, error: 'unknown command');
      }
    } catch (e) {
      _log('command $k failed: $e');
      _ack(id, false, error: '$e');
    }
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  // ── GATT ──────────────────────────────────────────────────────────────────

  Future<void> _connect(String mac) async {
    await _disconnectDevice();
    await FlutterBluePlus.stopScan();
    _disconnectRequested = false;
    final device = BluetoothDevice.fromId(mac);
    _deviceMac = mac;
    _phase = 'connecting';

    // The stream emits the current (disconnected) state immediately; only
    // react to disconnections once the connection has been established.
    var established = false;
    _subs.add(
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            established &&
            !_finished) {
          if (_disconnectRequested) {
            // The backend asked for this release; the shutdown command will
            // end the session with an ok status.
            return;
          }
          _sendEvent({'k': 'disconnected', 'reason': 'gatt_disconnected'});
          _finish(ok: false, reason: 'device_disconnected');
        }
      }),
    );

    await device.connect(autoConnect: false, mtu: null);
    established = true;
    _device = device;
    _phase = 'connected';

    device.cancelWhenDisconnected(
      device.mtu.listen((mtu) => _sendEvent({'k': 'mtu', 'mtu': mtu})),
    );

    _sendEvent({'k': 'connected', 'mtu': null});

    final services = await device.discoverServices();
    _sendEvent({
      'k': 'services',
      'services': [
        for (final s in services)
          {
            'uuid': s.uuid.str,
            'characteristics': [
              for (final c in s.characteristics)
                {
                  'uuid': c.uuid.str,
                  'read': c.properties.read,
                  'write': c.properties.write,
                  'write_without_response': c.properties.writeWithoutResponse,
                  'notify': c.properties.notify,
                  'indicate': c.properties.indicate,
                },
            ],
          },
      ],
    });
  }

  Future<void> _subscribe(String charUuid) async {
    final char = _findCharacteristic(charUuid);
    if (char == null) {
      throw StateError('characteristic not found: $charUuid');
    }
    await char.setNotifyValue(true);
    final sub = char.onValueReceived.listen((value) {
      _pendingNotify.add({'char_uuid': charUuid, 'data': base64Encode(value)});
      _notifyFrames += 1;
      _notifyBytes += value.length;
    });
    _device?.cancelWhenDisconnected(sub);
    _subs.add(sub);
    _phase = 'subscribed';
    _ensureFlushTimer();
  }

  Future<void> _write(
    String charUuid,
    List<int> data, {
    required bool withoutResponse,
  }) async {
    final char = _findCharacteristic(charUuid);
    if (char == null) {
      throw StateError('characteristic not found: $charUuid');
    }
    // Honor the requested mode when the characteristic supports it; otherwise
    // fall back to the other mode. Characteristics with no advertised write
    // properties (e.g. the Huami auth char, which is indicate-only in its
    // property bits but still accepts writes) get a plain with-response write.
    final useWithoutResponse = withoutResponse
        ? (char.properties.writeWithoutResponse || !char.properties.write)
        : (!char.properties.write && char.properties.writeWithoutResponse);
    await char.write(data, withoutResponse: useWithoutResponse);
  }

  BluetoothCharacteristic? _findCharacteristic(String uuid) {
    final wanted = uuid.toLowerCase();
    for (final s in _device?.servicesList ?? []) {
      for (final c in s.characteristics) {
        if (c.uuid.str.toLowerCase() == wanted) return c;
      }
    }
    return null;
  }

  BluetoothDevice _requireDevice() {
    final d = _device;
    if (d == null) throw StateError('no device connected');
    return d;
  }

  void _onScanResults(List<ScanResult> results) {
    // fbp re-emits the full result list continuously; forward each MAC once
    // (plus a refresh when a name shows up) so the relay stays quiet.
    for (final r in results) {
      final mac = r.device.remoteId.str;
      final name = r.advertisementData.advName;
      final seen = _scanSeen[mac];
      if (seen != null && (name.isEmpty || seen)) continue;
      _scanSeen[mac] = name.isNotEmpty;
      _sendEvent({
        'k': 'scan_result',
        'mac': mac,
        'name': name.isEmpty ? null : name,
        'rssi': r.rssi,
      });
    }
  }

  // ── plumbing ──────────────────────────────────────────────────────────────

  void _ensureFlushTimer() {
    if (_flushTimer != null) return;
    _flushTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_pendingNotify.isEmpty || _finished) return;
      final items = List<Map<String, dynamic>>.from(_pendingNotify);
      _pendingNotify.clear();
      _sendEvent({'k': 'notify_batch', 'items': items});
    });
  }

  Future<void> _disconnectDevice() async {
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
  }

  void _ack(int id, bool ok, {String? error}) {
    _sendEvent({
      'k': 'cmd_result',
      'id': id,
      'ok': ok,
      if (error != null) 'error': error,
    });
  }

  void _sendEvent(Map<String, dynamic> evt) {
    if (_finished) return;
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode({'t': 'evt', ...evt}));
      _framesSent += 1;
    } catch (e) {
      _log('send failed: $e');
    }
  }

  void _log(String msg) {
    debugPrint('$_tag: $msg');
    _sendEvent({'k': 'log', 'msg': msg});
  }

  void _finish({required bool ok, required String reason}) {
    if (_finished || _done == null || _done!.isCompleted) return;
    _finished = true;
    // A held session outlives its actions — release the watch-busy block
    // only when the BLE link itself is gone.
    _watchBusy = false;
    final outcome = {
      'status': ok ? 'ok' : 'fail',
      'reason': reason,
      'phase': _phase,
      'device': _deviceMac,
      'notify_frames': _notifyFrames,
      'notify_bytes': _notifyBytes,
      'frames_sent': _framesSent,
      if (_controlsResults != null) 'controls_results': _controlsResults,
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (hold && !firstResult.isCompleted) {
      // The session died before the actions finished — still resolve the
      // caller so the UI does not hang.
      firstResult.complete(outcome);
    }
    _done!.complete(outcome);
  }

  /// Held sessions: run more control actions on the live connection.
  /// With `release: true` the watch is released once they complete.
  Future<Map<String, dynamic>> runMore(
    List<Map<String, dynamic>> actions, {
    bool release = false,
  }) {
    if (_finished) {
      return Future.value({'status': 'fail', 'reason': 'session_ended'});
    }
    _runMoreDone = Completer<Map<String, dynamic>>();
    _sendEvent({'k': 'controls_run', 'actions': actions, 'release': release});
    return _runMoreDone!.future;
  }

  Future<void> _cleanup() async {
    _deadline?.cancel();
    _flushTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _disconnectDevice();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _ws?.sink.close();
    } catch (_) {}
  }

  static const _tag = 'MontBLE';
}
