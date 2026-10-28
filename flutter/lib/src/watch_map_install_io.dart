import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform, kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'ble/ble_relay_io.dart' as ble_relay;
import 'platform/watch_wifi.dart';

/// Installs a built map ZIP onto the watch:
///
/// extract tiles → start the watch hotspot + FTP over BLE (held session) →
/// join the watch's Wi-Fi from the phone → FTP-upload every tile to
/// `/mnt/data/map/res/scl/` → stop hotspot + FTP and release the watch.
///
/// Throws with a user-presentable message on the first failing step; the
/// caller surfaces it. [onLog] receives progress lines for the UI.
class WatchMapInstaller {
  /// The watch only keeps the hotspot up while our BLE link is alive, and
  /// ColorOS bounces the phone off no-internet networks — so the join uses
  /// an app-held network and the session is held until Stop.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> installFromZip({
    required Uint8List zipBytes,
    required String ssid,
    required String password,
    required void Function(String line) log,
  }) async {
    final tempDir = await _extractTiles(zipBytes, log);

    log('Starting watch hotspot & FTP (watch connect ~20 s)…');
    final outcome = await ble_relay.startHeldWatchTransfer(
      actions: [
        {'k': 'hotspot_start', 'ssid': ssid, 'password': password},
        {'k': 'ftp_start', 'root_dir': '/mnt/data'},
      ],
    );
    final (host, port, user) = _parseFtpOutcome(outcome);
    log('Watch FTP up at $host:$port (user $user)');

    String? netId;
    String? ftpId;
    try {
      log('Joining the watch Wi-Fi — confirm the connection if asked…');
      netId = await WatchWifi.join(ssid: ssid, password: password);
      log('Connected to "$ssid"');

      // OEM Wi-Fi assistants drop no-internet hotspots seconds after joining;
      // the native side re-requests the network on loss, so retry the whole
      // FTP phase a few times to ride out a drop.
      const mapsDir = '/mnt/data/map/res/scl';
      const attempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= attempts; attempt++) {
        try {
          if (attempt > 1) {
            log('Retrying FTP (attempt $attempt/$attempts)…');
            await Future<void>.delayed(const Duration(seconds: 3));
          }
          ftpId = await WatchWifi.ftpConnect(
            netId: netId,
            host: host,
            port: port,
            user: user,
            password: '',
          );
          await WatchWifi.ftpMkdirs(ftpId: ftpId, path: mapsDir);

          final entries = tempDir
              .listSync(recursive: true)
              .whereType<File>()
              .toList();
          var done = 0;
          for (final file in entries) {
            done += 1;
            final name = file.path
                .substring(tempDir.path.length + 1)
                .replaceAll('\\', '/');
            log('Uploading $name ($done/${entries.length})…');
            await WatchWifi.ftpUpload(
              ftpId: ftpId,
              localPath: file.path,
              remotePath: '$mapsDir/$name',
            );
          }
          log('Uploaded ${entries.length} tiles ✓');
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          log('FTP attempt $attempt failed: $e');
          if (ftpId != null) {
            try {
              await WatchWifi.ftpClose(ftpId);
            } catch (_) {}
            ftpId = null;
          }
        }
      }
      if (lastError != null) {
        throw Exception(
          'FTP transfer failed after $attempts attempts: $lastError. '
          'If it keeps failing, disable mobile data during the transfer.',
        );
      }

      // Self-verify: list the remote tile dir so the log proves what's there.
      final listed = await WatchWifi.ftpList(ftpId: ftpId!, path: mapsDir);
      log('Watch $mapsDir now contains: ${listed.join(', ')}');
    } catch (e) {
      await _cleanup(netId: netId, ftpId: ftpId, log: log);
      rethrow;
    }

    log('Stopping FTP & hotspot, releasing the watch…');
    await _cleanup(netId: netId, ftpId: ftpId, log: log);
  }

  static Future<Directory> _extractTiles(
    Uint8List zipBytes,
    void Function(String) log,
  ) async {
    log('Extracting tiles…');
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/map_install');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final file = File('${dir.path}/${entry.name}');
      await file.create(recursive: true);
      await file.writeAsBytes(entry.content as List<int>);
    }
    log('Tiles ready');
    return dir;
  }

  static (String, int, String) _parseFtpOutcome(Map<String, dynamic> outcome) {
    final results =
        (outcome['controls_results'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const [];
    for (final r in results) {
      if (r['status'] != 'ok') {
        throw Exception(
          '${r['action'] ?? 'action'} failed: ${r['error'] ?? r['status'] ?? 'unknown'}',
        );
      }
      final address = r['address'] as String?;
      if (address != null) {
        var host = address.startsWith('ftp://')
            ? address.substring(6)
            : address;
        var port = 21;
        final sep = host.lastIndexOf(':');
        if (sep > 0) {
          port =
              int.tryParse(host.substring(sep + 1).replaceAll('/', '')) ?? 21;
          host = host.substring(0, sep);
        }
        return (host, port, r['username'] as String? ?? 'anonymous');
      }
    }
    throw Exception('Watch did not report an FTP address');
  }

  /// Best-effort cleanup: close FTP, stop hotspot + FTP over the held BLE
  /// link, then release the watch and the Wi-Fi network.
  static Future<void> _cleanup({
    required String? netId,
    required String? ftpId,
    required void Function(String) log,
  }) async {
    try {
      if (ftpId != null) await WatchWifi.ftpClose(ftpId);
    } catch (_) {}
    try {
      final transfer = ble_relay.activeWatchTransfer;
      if (transfer != null && transfer.isAlive) {
        await transfer.release([
          {'k': 'ftp_stop'},
          {'k': 'hotspot_stop'},
        ]);
        log('Watch hotspot and FTP stopped');
      }
    } catch (e) {
      log(
        'Watch release failed: $e (the hotspot also goes down on the 15 min cap)',
      );
    }
    try {
      if (netId != null) await WatchWifi.leave(netId);
    } catch (_) {}
  }
}
