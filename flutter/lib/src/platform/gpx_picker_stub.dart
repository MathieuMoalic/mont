import 'package:file_picker/file_picker.dart';

/// Prompts the user to pick a GPX file and returns its bytes + filename,
/// or null if cancelled.
Future<({List<int> bytes, String name})?> pickGpxFile() async {
  final result = await FilePicker.platform.pickFiles(withData: true);
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.first;
  if (file.bytes == null) return null;
  return (bytes: file.bytes!.toList(), name: file.name);
}
