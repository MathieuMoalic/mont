package eu.matmoa.mont

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import java.io.FileInputStream
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Joins the watch's Wi-Fi hotspot (app-held network, so it survives the
 * phone's "no internet" auto-switch) and runs FTP transfers bound to it.
 *
 * The hotspot has no uplink: sockets must be bound to this specific network
 * (via `network.socketFactory`) or they route out the default network and
 * never reach the watch.
 */
class WatchWifiPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    private data class HeldNetwork(
        val network: Network,
        val callback: ConnectivityManager.NetworkCallback,
        val ssid: String,
        val password: String,
    )

    private val networks = ConcurrentHashMap<String, HeldNetwork>()
    private val ftpClients = ConcurrentHashMap<String, FTPClient>()
    private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var netSeq = 0
    private var ftpSeq = 0
    /// Set by `leave` — stops the onLost auto-rejoin loop.
    @Volatile private var wifiReleased = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "join" -> join(call, result)
            "leave" -> leave(call, result)
            // FTP calls block on network I/O — run them off the main thread.
            "ftpConnect", "ftpMkdirs", "ftpUpload", "ftpList", "ftpClose" -> executor.execute {
                try {
                    when (call.method) {
                        "ftpConnect" -> ftpConnect(call, result)
                        "ftpMkdirs" -> ftpMkdirs(call, result)
                        "ftpUpload" -> ftpUpload(call, result)
                        "ftpList" -> ftpList(call, result)
                        else -> ftpClose(call, result)
                    }
                } catch (e: Exception) {
                    mainHandler.post {
                        result.error("ftp", e.message ?: "$e", null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun cm(): ConnectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    /// Joins the hotspot. The system may show a confirmation dialog; the
    /// future resolves when the network is available (or times out — the
    /// system fires `onUnavailable` after its own 90 s timeout).
    private fun join(call: MethodCall, result: MethodChannel.Result) {
        val ssid = call.argument<String>("ssid") ?: run { result.error("args", "missing ssid", null); return }
        val password = call.argument<String>("password") ?: run { result.error("args", "missing password", null); return }
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        netSeq += 1
        val id = "net_$netSeq"
        wifiReleased = false
        val answered = AtomicBoolean(false)
        // ColorOS/OEM "Wi-Fi assistant" disconnects no-internet networks
        // seconds after joining — re-request the same network on loss so the
        // transfer window stays usable.
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                networks[id] = HeldNetwork(network, this, ssid, password)
                runOnMain { if (!answered.getAndSet(true)) result.success(id) }
            }

            override fun onLost(network: Network) {
                networks.remove(id)
                rejoin(id, ssid, password)
            }

            override fun onUnavailable() {
                runOnMain {
                    if (!answered.getAndSet(true)) {
                        result.error("unavailable", "Could not connect to $ssid (timeout)", null)
                    }
                }
            }
        }
        // Long timeout: on ColorOS the request routes through a system
        // "Open with" chooser and then the Wi-Fi settings page — the user
        // needs time to tap through both.
        cm().requestNetwork(request, callback, 240_000)
    }

    private fun runOnMain(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    /// Re-requests the hotspot network after an OEM assistant drops it.
    private fun rejoin(originalId: String, ssid: String, password: String) {
        if (wifiReleased) return
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Rejoin stores under the ORIGINAL id so the Dart side keeps
                // a stable handle even across OEM-forced drops.
                networks[originalId] = HeldNetwork(network, this, ssid, password)
            }

            override fun onLost(network: Network) {
                rejoin(originalId, ssid, password)
            }
        }
        // Bounded window per rejoin; the loop keeps going while the session
        // lives (leave() sets wifiReleased to stop it).
        cm().requestNetwork(request, callback, 120_000)
    }

    private fun leave(call: MethodCall, result: MethodChannel.Result) {
        wifiReleased = true
        val netId = call.argument<String>("netId")
        val held = netId?.let { networks.remove(it) }
        if (held != null) {
            try {
                cm().unregisterNetworkCallback(held.callback)
            } catch (_: Exception) {}
        }
        result.success(null)
    }

    private fun ftpFor(call: MethodCall): FTPClient? {
        val ftpId = call.argument<String>("ftpId") ?: return null
        return ftpClients[ftpId]
    }

    private fun ftpConnect(call: MethodCall, result: MethodChannel.Result) {
        val netId = call.argument<String>("netId")
        val host = call.argument<String>("host") ?: run { result.error("args", "missing host", null); return }
        val port = call.argument<Number>("port")?.toInt() ?: 21
        val user = call.argument<String>("user") ?: "anonymous"
        val pass = call.argument<String>("password") ?: ""
        val network = netId?.let { networks[it]?.network }
        if (network == null) {
            result.error("no_network", "Wi-Fi network not held — join first", null)
            return
        }
        try {
            val client = FTPClient()
            // Commons Net exposes only a setter — Kotlin property syntax
            // doesn't resolve, hence the explicit call.
            client.setSocketFactory(network.socketFactory)
            client.connectTimeout = 20_000
            client.connect(host, port)
            // Must come after connect — Commons Net 3.11 NPEs on a null socket.
            client.soTimeout = 30_000
            val reply = client.login(user, pass)
            if (!reply) {
                val code = client.replyCode
                client.disconnect()
                result.error("login", "FTP login failed (reply $code)", null)
                return
            }
            client.setFileType(FTP.BINARY_FILE_TYPE)
            client.enterLocalPassiveMode()
            ftpSeq += 1
            val id = "ftp_$ftpSeq"
            ftpClients[id] = client
            result.success(id)
        } catch (e: Exception) {
            result.error("connect", e.message ?: "FTP connect failed", null)
        }
    }

    /// Creates `remoteDir` including missing parents (MKD per component).
    private fun ftpMkdirs(call: MethodCall, result: MethodChannel.Result) {
        val client = ftpFor(call)
        val remoteDir = call.argument<String>("path") ?: run { result.error("args", "missing path", null); return }
        if (client == null) {
            result.error("no_client", "FTP client not connected", null)
            return
        }
        try {
            var cwd = ""
            for (part in remoteDir.split("/").filter { it.isNotEmpty() }) {
                cwd += "/$part"
                if (client.changeWorkingDirectory(cwd)) continue
                if (!client.makeDirectory(cwd) && !client.changeWorkingDirectory(cwd)) {
                    result.error("mkdir", "MKD $cwd failed (reply ${client.replyCode})", null)
                    return
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("mkdir", e.message ?: "mkdirs failed", null)
        }
    }

    /// Uploads one file; on a passive-mode failure retries once in active
    /// mode (the watch's FreeRTOS FTP server supports both).
    private fun ftpUpload(call: MethodCall, result: MethodChannel.Result) {
        val client = ftpFor(call)
        val localPath = call.argument<String>("localPath")
            ?: run { result.error("args", "missing localPath", null); return }
        val remotePath = call.argument<String>("remotePath")
            ?: run { result.error("args", "missing remotePath", null); return }
        if (client == null) {
            result.error("no_client", "FTP client not connected", null)
            return
        }
        val file = java.io.File(localPath)
        if (!file.exists()) {
            result.error("args", "local file missing: $localPath", null)
            return
        }
        try {
            FileInputStream(file).use { input ->
                if (!client.storeFile(remotePath, input)) {
                    throw java.io.IOException("STOR failed (reply ${client.replyCode})")
                }
            }
            result.success(file.length())
        } catch (e: SocketTimeoutException) {
            // Passive data connection failed — retry once in active mode.
            try {
                client.enterLocalActiveMode()
                FileInputStream(file).use { input ->
                    if (!client.storeFile(remotePath, input)) {
                        throw java.io.IOException("STOR failed (reply ${client.replyCode})")
                    }
                }
                client.enterLocalPassiveMode()
                result.success(file.length())
            } catch (e2: Exception) {
                client.enterLocalPassiveMode()
                result.error("upload", e2.message ?: "upload failed", null)
            }
        } catch (e: Exception) {
            result.error("upload", e.message ?: "upload failed", null)
        }
    }

    /// Lists a remote directory: returns `"name size"` lines.
    private fun ftpList(call: MethodCall, result: MethodChannel.Result) {
        val client = ftpFor(call)
        val remoteDir = call.argument<String>("path") ?: run { result.error("args", "missing path", null); return }
        if (client == null) {
            result.error("no_client", "FTP client not connected", null)
            return
        }
        try {
            if (!client.changeWorkingDirectory(remoteDir)) {
                result.error("list", "CWD $remoteDir failed (reply ${client.replyCode})", null)
                return
            }
            val entries = client.listFiles()
            val lines = entries.filterNotNull().map { entry ->
                val size = if (entry.isDirectory) -1 else entry.size
                "${entry.name} $size"
            }
            result.success(lines)
        } catch (e: Exception) {
            result.error("list", e.message ?: "LIST failed", null)
        }
    }

    private fun ftpClose(call: MethodCall, result: MethodChannel.Result) {
        val ftpId = call.argument<String>("ftpId")
        val client = ftpId?.let { ftpClients.remove(it) }
        if (client != null) {
            try {
                client.logout()
            } catch (_: Exception) {}
            try {
                client.disconnect()
            } catch (_: Exception) {}
        }
        result.success(null)
    }
}
