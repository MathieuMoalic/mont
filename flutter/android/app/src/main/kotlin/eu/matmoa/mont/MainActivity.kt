package eu.matmoa.mont

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        io.flutter.plugin.common.MethodChannel(messenger, "mont/watch_wifi")
            .setMethodCallHandler(WatchWifiPlugin(applicationContext))
    }
}
