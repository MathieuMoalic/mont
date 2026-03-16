// Persistent storage for watch pairing settings.

import 'package:shared_preferences/shared_preferences.dart';

const String _kDeviceKeyHex = 'ble_device_key_hex';
const String _kDeviceRemoteId = 'ble_device_remote_id';
const String _kLastHealthSyncTime = 'ble_last_health_sync_time';

/// Load the stored 16-byte device key as a hex string, or null if not set.
Future<String?> loadDeviceKeyHex() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kDeviceKeyHex);
}

/// Save the device key hex string.
Future<void> saveDeviceKeyHex(String hex) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kDeviceKeyHex, hex.toLowerCase().replaceAll(' ', ''));
}

/// Load the previously connected device remote ID (MAC address), or null.
Future<String?> loadDeviceRemoteId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kDeviceRemoteId);
}

/// Save the remote ID of the paired device so we can reconnect without scanning.
Future<void> saveDeviceRemoteId(String remoteId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kDeviceRemoteId, remoteId);
}

/// Clear all BLE pairing data.
Future<void> clearBleSettings() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kDeviceKeyHex);
  await prefs.remove(_kDeviceRemoteId);
}

/// Load the timestamp of the last successfully synced health sample, or null.
Future<DateTime?> loadLastHealthSyncTime() async {
  final prefs = await SharedPreferences.getInstance();
  final ms = prefs.getInt(_kLastHealthSyncTime);
  if (ms == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Persist the timestamp of the last successfully synced health sample.
Future<void> saveLastHealthSyncTime(DateTime t) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kLastHealthSyncTime, t.toUtc().millisecondsSinceEpoch);
}

/// Clear the stored health sync timestamp so the next sync fetches from scratch.
Future<void> clearLastHealthSyncTime() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kLastHealthSyncTime);
}

/// Convert a hex string (e.g. "deadbeef...") to bytes.
/// Throws [FormatException] if the string is not valid hex or not 32 chars (16 bytes).
List<int> hexToBytes(String hex) {
  final cleaned = hex.replaceAll(' ', '').toLowerCase().replaceFirst(RegExp(r'^0x'), '');
  if (cleaned.length != 32) {
    throw FormatException('Device key must be 32 hex chars (16 bytes), got ${cleaned.length}');
  }
  return List.generate(16, (i) => int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16));
}
