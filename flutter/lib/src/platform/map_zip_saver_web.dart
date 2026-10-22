// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'dart:typed_data';

/// Downloads the map ZIP through the browser (blob + anchor click).
Future<void> saveMapZip(Uint8List bytes, String filename) async {
  final blob = html.Blob([bytes], 'application/zip');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
}
