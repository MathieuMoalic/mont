import 'package:flutter/services.dart';

/// Android-side helper for the watch map transfer: joins the watch's Wi-Fi
/// hotspot as an app-held network (survives the phone's "no internet"
/// auto-switch) and runs FTP transfers bound to that network.
///
/// Android only — calling these elsewhere throws [MissingPluginException];
/// callers must guard.
class WatchWifi {
  static const _channel = MethodChannel('mont/watch_wifi');

  /// Joins the hotspot; the system may show a confirmation dialog. Returns
  /// a network id to pass to the FTP calls.
  static Future<String> join({
    required String ssid,
    required String password,
  }) async {
    return await _channel.invokeMethod<String>('join', {
          'ssid': ssid,
          'password': password,
        })
        as String;
  }

  /// Releases the held network (phone returns to its normal Wi-Fi).
  static Future<void> leave(String netId) async {
    await _channel.invokeMethod<void>('leave', {'netId': netId});
  }

  static Future<String> ftpConnect({
    required String netId,
    required String host,
    required int port,
    required String user,
    required String password,
  }) async {
    return await _channel.invokeMethod<String>('ftpConnect', {
          'netId': netId,
          'host': host,
          'port': port,
          'user': user,
          'password': password,
        })
        as String;
  }

  /// Creates [path] including missing parent directories.
  static Future<void> ftpMkdirs({
    required String ftpId,
    required String path,
  }) async {
    await _channel.invokeMethod<void>('ftpMkdirs', {
      'ftpId': ftpId,
      'path': path,
    });
  }

  /// Uploads one file; returns the bytes sent.
  static Future<int> ftpUpload({
    required String ftpId,
    required String localPath,
    required String remotePath,
  }) async {
    return await _channel.invokeMethod<int>('ftpUpload', {
          'ftpId': ftpId,
          'localPath': localPath,
          'remotePath': remotePath,
        })
        as int;
  }

  /// Lists a remote directory as `"name size"` lines (size −1 for dirs).
  static Future<List<String>> ftpList({
    required String ftpId,
    required String path,
  }) async {
    final entries = await _channel.invokeMethod<List<dynamic>>('ftpList', {
      'ftpId': ftpId,
      'path': path,
    });
    return (entries ?? const []).map((e) => e.toString()).toList();
  }

  static Future<void> ftpClose(String ftpId) async {
    await _channel.invokeMethod<void>('ftpClose', {'ftpId': ftpId});
  }
}
