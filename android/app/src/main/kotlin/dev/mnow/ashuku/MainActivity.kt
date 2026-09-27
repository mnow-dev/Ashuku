package dev.mnow.ashuku

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private lateinit var engine: VideoEngine
    private lateinit var library: MediaLibrary
    private val io = Executors.newSingleThreadExecutor()
    private val thumbnailPool = Executors.newFixedThreadPool(3)
    private var permissionResult: MethodChannel.Result? = null

    /** A video shared into the app that Dart hasn't picked up yet. */
    private var incomingUri: Uri? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) incomingUri = sharedVideoUri(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedVideoUri(intent)?.let {
            incomingUri = it
            channel.invokeMethod("incomingShare", null)
        }
    }

    private fun sharedVideoUri(intent: Intent?): Uri? {
        if (intent?.action != Intent.ACTION_SEND) return null
        return IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = VideoEngine(applicationContext)
        library = MediaLibrary(applicationContext)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ashuku/video")
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("NATIVE", e.message, e.toString())
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> background(result) { engine.probe(call.argument<String>("path")!!) }
            "thumbnails" -> background(result) {
                engine.thumbnails(
                    call.argument<String>("path")!!,
                    call.argument<Int>("count")!!,
                    call.argument<Int>("height")!!,
                )
            }
            "compress" -> compress(call, result)
            "cancel" -> result.success(engine.cancel())
            "saveToGallery" -> background(result) { engine.saveToGallery(call.argument<String>("path")!!) }
            "share" -> result.success(
                share(
                    call.argument<List<String>>("paths")!!,
                    call.argument<String>("package"),
                    call.argument<String>("activity"),
                ),
            )
            "canSendMultiple" -> result.success(
                canSendMultiple(call.argument<String>("package")!!, call.argument<String>("activity")),
            )
            "mediaAccess" -> result.success(mediaAccess())
            "requestMediaAccess" -> requestMediaAccess(result)
            "openAppSettings" -> {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
                )
                result.success(null)
            }
            "albums" -> background(result) { library.albums() }
            "videos" -> background(result) { library.videos(call.argument<Number>("bucketId")?.toLong()) }
            "libraryThumbnail" -> background(result, thumbnailPool) {
                library.thumbnail(call.argument<Number>("id")!!.toLong(), call.argument<Int>("size")!!)
            }
            "libraryPath" -> background(result) {
                library.readablePath(call.argument<Number>("id")!!.toLong(), engine::importUri)
            }
            "installedPackages" -> {
                val packages = call.argument<List<String>>("packages")!!
                result.success(packages.filter { isInstalled(it) })
            }
            "consumeIncomingShare" -> {
                val uri = incomingUri
                incomingUri = null
                if (uri == null) result.success(null) else background(result) { engine.importUri(uri) }
            }
            "cleanup" -> {
                engine.cleanup()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun compress(call: MethodCall, result: MethodChannel.Result) {
        val request = CompressRequest(
            path = call.argument<String>("path")!!,
            startMs = call.argument<Number>("startMs")!!.toLong(),
            endMs = call.argument<Number>("endMs")!!.toLong(),
            width = call.argument<Int>("width")!!,
            height = call.argument<Int>("height")!!,
            videoBitrate = call.argument<Int>("videoBitrate")!!,
            audioBitrate = call.argument<Int>("audioBitrate")!!,
            targetFps = call.argument<Number>("targetFps")!!.toDouble(),
            sourceFps = call.argument<Number>("sourceFps")!!.toDouble(),
            mute = call.argument<Boolean>("mute")!!,
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        engine.compress(
            request,
            onProgress = { channel.invokeMethod("progress", it) },
            onDone = {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(it)
            },
            onError = { code, message ->
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.error(code, message, null)
            },
        )
    }

    /**
     * Sends [paths] to [targetActivity] in [targetPackage] if it can take them, else anywhere in
     * [targetPackage], else via the system chooser. Returns true if it went straight to the app.
     */
    private fun share(paths: List<String>, targetPackage: String?, targetActivity: String?): Boolean {
        val uris = paths.map { FileProvider.getUriForFile(this, "$packageName.share", File(it)) }
        val multiple = uris.size > 1
        val send = Intent(if (multiple) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
            type = "video/mp4"
            if (multiple) {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            } else {
                putExtra(Intent.EXTRA_STREAM, uris[0])
            }
            clipData = ClipData.newRawUri(null, uris[0]).apply {
                uris.drop(1).forEach { addItem(ClipData.Item(it)) }
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val direct = buildList {
            // An explicit component bypasses intent filters, so only target an activity that
            // declares it handles this action (Instagram's DM handler takes one video only).
            if (targetPackage != null && targetActivity != null &&
                handlers(send.action!!, targetPackage).contains(targetActivity)
            ) {
                add(Intent(send).setClassName(targetPackage, targetActivity))
            }
            if (targetPackage != null) add(Intent(send).setPackage(targetPackage))
        }
        for (intent in direct) {
            try {
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
            } catch (_: SecurityException) {
            }
        }
        startActivity(Intent.createChooser(send, null))
        return false
    }

    private fun canSendMultiple(targetPackage: String, targetActivity: String?): Boolean {
        val handlers = handlers(Intent.ACTION_SEND_MULTIPLE, targetPackage)
        return if (targetActivity != null) handlers.contains(targetActivity) else handlers.isNotEmpty()
    }

    /** Activity class names in [pkg] that handle [action] for MP4 video. */
    private fun handlers(action: String, pkg: String): Set<String> {
        val query = Intent(action).setType("video/mp4").setPackage(pkg)
        return packageManager.queryIntentActivities(query, 0).map { it.activityInfo.name }.toSet()
    }

    private val mediaPermissions: Array<String>
        get() = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** "full", "partial" (Android 14+ "selected videos only") or "denied". */
    private fun mediaAccess(): String = when {
        granted(mediaPermissions[0]) -> "full"
        Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
        else -> "denied"
    }

    private fun requestMediaAccess(result: MethodChannel.Result) {
        permissionResult?.success(mediaAccess())
        permissionResult = result
        requestPermissions(mediaPermissions, MEDIA_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA_PERMISSION_REQUEST) return
        var access = mediaAccess()
        // Once the user has denied twice, Android stops showing the dialog; send them to Settings.
        if (access == "denied" && !shouldShowRequestPermissionRationale(mediaPermissions[0])) access = "blocked"
        permissionResult?.success(access)
        permissionResult = null
    }

    private fun isInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: Exception) {
        false
    }

    private fun <T> background(
        result: MethodChannel.Result,
        executor: java.util.concurrent.Executor = io,
        work: () -> T,
    ) {
        executor.execute {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("NATIVE", e.message, e.toString()) }
            }
        }
    }

    override fun onDestroy() {
        engine.cancel()
        io.shutdown()
        thumbnailPool.shutdown()
        super.onDestroy()
    }

    private companion object {
        const val MEDIA_PERMISSION_REQUEST = 7301
    }
}
