// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Prompts the user to pick a GPX file and returns its bytes + filename,
/// or null if cancelled.
Future<({List<int> bytes, String name})?> pickGpxFile() async {
  final input = html.FileUploadInputElement()..accept = '.gpx';
  input.click();
  await input.onChange.first;
  final file = input.files?.first;
  if (file == null) return null;
  final reader = html.FileReader()..readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  final bytes = (reader.result as List<dynamic>).cast<int>();
  return (bytes: bytes, name: file.name);
}
