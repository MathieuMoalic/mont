import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Saves the map ZIP via the platform save dialog (Android SAF / desktop).
///
/// A null return means the user cancelled the dialog.
Future<void> saveMapZip(Uint8List bytes, String filename) async {
  await FilePicker.platform.saveFile(fileName: filename, bytes: bytes);
}
