/// Watch map install orchestration (build → hotspot → FTP upload), gated to
/// platforms that support it (Android). The real implementation lives in
/// `watch_map_install_io.dart`.
library;

export 'watch_map_install_stub.dart'
    if (dart.library.io) 'watch_map_install_io.dart';
