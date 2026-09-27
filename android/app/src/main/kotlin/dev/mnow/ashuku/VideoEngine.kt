package dev.mnow.ashuku

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Parameters for a single export, as sent from Dart. */
data class CompressRequest(
    val path: String,
    val startMs: Long,
    val endMs: Long,
    val width: Int,
    val height: Int,
    val videoBitrate: Int,
    val audioBitrate: Int,
    val targetFps: Double,
    val sourceFps: Double,
    val mute: Boolean,
)

/** Video probing, thumbnails, and Media3 Transformer exports. Must be used from the main thread. */
@UnstableApi
class VideoEngine(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var transformer: Transformer? = null
    private var progressPoller: Runnable? = null
    private var onCancelled: (() -> Unit)? = null

    val outDir: File get() = File(context.cacheDir, "ashuku_out").apply { mkdirs() }
    private val inDir: File get() = File(context.cacheDir, "ashuku_in").apply { mkdirs() }

    fun probe(path: String): Map<String, Any?> {
        val file = File(path)
        val retriever = MediaMetadataRetriever()
        val info = HashMap<String, Any?>()
        try {
            retriever.setDataSource(path)
            fun key(k: Int) = retriever.extractMetadata(k)
            val w = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val durationMs = key(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val frameCount = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toLongOrNull()
            val transfer = if (android.os.Build.VERSION.SDK_INT >= 30) {
                key(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)?.toIntOrNull()
            } else null
            val swap = rotation % 180 != 0
            info["path"] = path
            info["name"] = file.name
            info["width"] = if (swap) h else w
            info["height"] = if (swap) w else h
            info["rotation"] = rotation
            info["durationMs"] = durationMs
            info["bitrate"] = key(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
            info["hasAudio"] = key(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            info["hasVideo"] = key(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            info["isHdr"] = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                transfer == MediaFormat.COLOR_TRANSFER_HLG
            info["sizeBytes"] = file.length()
            if (frameCount != null && durationMs > 0) {
                info["fps"] = frameCount * 1000.0 / durationMs
            }
        } finally {
            retriever.release()
        }

        // The container's declared frame rate is more reliable than frameCount / duration.
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    info["videoMime"] = mime
                    if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        val fps = format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble()
                        if (fps != null && fps > 0) info["fps"] = fps
                    }
                } else if (mime.startsWith("audio/")) {
                    info["audioMime"] = mime
                }
            }
        } catch (_: Exception) {
        } finally {
            extractor.release()
        }
        return info
    }

    /** Evenly spaced JPEG thumbnails for the trim strip. */
    fun thumbnails(path: String, count: Int, maxHeight: Int): List<ByteArray> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationUs =
                (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            val frames = ArrayList<ByteArray>(count)
            for (i in 0 until count) {
                val timeUs = durationUs * (2 * i + 1) / (2 * count)
                val bitmap = retriever.getScaledFrameAtTime(
                    timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxHeight * 2, maxHeight,
                ) ?: continue
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 70, out)
                bitmap.recycle()
                frames.add(out.toByteArray())
            }
            return frames
        } finally {
            retriever.release()
        }
    }

    fun compress(
        request: CompressRequest,
        onProgress: (Double) -> Unit,
        onDone: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
    ) {
        cancel()
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val output = File(outDir, "ashuku_$stamp.mp4")
        output.delete()

        val clipping = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(request.startMs)
            .apply { if (request.endMs > 0) setEndPositionMs(request.endMs) }
            .build()
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(File(request.path)))
            .setClippingConfiguration(clipping)
            .build()

        val videoEffects = mutableListOf<Effect>()
        if (request.targetFps > 0 && request.sourceFps > request.targetFps + 1) {
            videoEffects += FrameDropEffect.createDefaultFrameDropEffect(request.targetFps.toFloat())
        }
        // Dimensions are in display orientation; Transformer handles source rotation itself.
        videoEffects += Presentation.createForWidthAndHeight(
            request.width, request.height, Presentation.LAYOUT_SCALE_TO_FIT,
        )

        val edited = EditedMediaItem.Builder(mediaItem)
            .setRemoveAudio(request.mute)
            .setEffects(Effects(listOf(), videoEffects))
            .build()
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
            // Chat apps choke on 10-bit HDR; tone-map Pixel HDR recordings to plain SDR.
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()

        val encoderFactory = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder().setBitrate(request.videoBitrate).build(),
            )
            .apply {
                if (request.audioBitrate > 0) {
                    setRequestedAudioEncoderSettings(
                        AudioEncoderSettings.Builder().setBitrate(request.audioBitrate).build(),
                    )
                }
            }
            .setEnableFallback(true)
            .build()

        val t = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoderFactory)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    stopPolling()
                    transformer = null
                    onCancelled = null
                    val result = probe(output.absolutePath).toMutableMap()
                    result["averageVideoBitrate"] = exportResult.averageVideoBitrate
                    result["averageAudioBitrate"] = exportResult.averageAudioBitrate
                    onDone(result)
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    stopPolling()
                    transformer = null
                    onCancelled = null
                    output.delete()
                    onError(exportException.errorCodeName, exportException.message)
                }
            })
            .build()
        transformer = t
        // Transformer doesn't notify listeners on cancel(), so settle the request here.
        onCancelled = {
            output.delete()
            onError("CANCELLED", "Export cancelled")
        }
        t.start(composition, output.absolutePath)

        val holder = ProgressHolder()
        val poller = object : Runnable {
            override fun run() {
                if (transformer !== t) return
                if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                    onProgress(holder.progress / 100.0)
                }
                mainHandler.postDelayed(this, 200)
            }
        }
        progressPoller = poller
        mainHandler.post(poller)
    }

    /** Cancels a running export. Returns true if one was running. */
    fun cancel(): Boolean {
        val t = transformer ?: return false
        stopPolling()
        transformer = null
        t.cancel()
        onCancelled?.invoke()
        onCancelled = null
        return true
    }

    private fun stopPolling() {
        progressPoller?.let { mainHandler.removeCallbacks(it) }
        progressPoller = null
    }

    /** Copies the file into Movies/Ashuku so it shows up in Photos. Returns the content URI. */
    fun saveToGallery(path: String): String {
        val file = File(path)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/Ashuku")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: error("MediaStore insert failed")
        try {
            resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    /** Copies a shared content:// video into our cache so every API can read it by path. */
    fun importUri(uri: Uri): String {
        val resolver = context.contentResolver
        var name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: uri.lastPathSegment ?: "shared_video.mp4"
        name = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val target = File(inDir, "${System.currentTimeMillis()}_$name")
        resolver.openInputStream(uri)!!.use { input -> target.outputStream().use { input.copyTo(it) } }
        return target.absolutePath
    }

    /** Deletes files left over from previous sessions. */
    fun cleanup() {
        if (transformer != null) return
        inDir.listFiles()?.forEach { it.delete() }
        outDir.listFiles()?.forEach { it.delete() }
    }
}
