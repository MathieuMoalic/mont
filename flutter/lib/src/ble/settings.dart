// Persistent storage for watch pairing settings.

import 'package:shared_preferences/shared_preferences.dart';

const String _kDeviceKeyHex = 'ble_device_key_hex';
const String _kDeviceRemoteId = 'ble_device_remote_id';

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

/// Convert a hex string (e.g. "deadbeef...") to bytes.
/// Throws [FormatException] if the string is not valid hex or not 32 chars (16 bytes).
List<int> hexToBytes(String hex) {
  final cleaned = hex.replaceAll(' ', '').toLowerCase();
  if (cleaned.length != 32) {
    throw FormatException('Device key must be 32 hex chars (16 bytes), got ${cleaned.length}');
  }
  return List.generate(16, (i) => int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16));
}
