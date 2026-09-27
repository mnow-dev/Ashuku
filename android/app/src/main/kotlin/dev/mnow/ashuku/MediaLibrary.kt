package dev.mnow.ashuku

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File

/** Read-only view of the device's videos through MediaStore. Call from a background thread. */
class MediaLibrary(private val context: Context) {
    private val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI

    /** Buckets (folders) that contain videos; the camera folder first, then by size. */
    fun albums(): List<Map<String, Any?>> {
        data class Album(val id: Long, val name: String, var count: Int, val isCamera: Boolean)
        val albums = LinkedHashMap<Long, Album>()
        val projection = arrayOf(
            MediaStore.Video.Media.BUCKET_ID,
            MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Video.Media.RELATIVE_PATH,
        )
        context.contentResolver.query(collection, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val album = albums.getOrPut(id) {
                    Album(
                        id = id,
                        name = c.getString(1) ?: "Videos",
                        count = 0,
                        isCamera = c.getString(2)?.startsWith("DCIM/Camera") == true,
                    )
                }
                album.count++
            }
        }
        return albums.values
            .sortedWith(compareByDescending<Album> { it.isCamera }.thenByDescending { it.count })
            .map { mapOf("id" to it.id, "name" to it.name, "count" to it.count, "isCamera" to it.isCamera) }
    }

    /** Videos in [bucketId] (or all), newest first. */
    fun videos(bucketId: Long?): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.ORIENTATION,
            MediaStore.Video.Media.DATE_TAKEN,
            MediaStore.Video.Media.DATE_ADDED,
        )
        val selection = bucketId?.let { "${MediaStore.Video.Media.BUCKET_ID}=?" }
        val args = bucketId?.let { arrayOf(it.toString()) }
        val order = "${MediaStore.Video.Media.DATE_TAKEN} DESC, ${MediaStore.Video.Media.DATE_ADDED} DESC"
        val videos = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(collection, projection, selection, args, order)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val rotated = c.getInt(6) % 180 != 0
                val w = c.getInt(4)
                val h = c.getInt(5)
                val taken = if (c.isNull(7)) c.getLong(8) * 1000 else c.getLong(7)
                videos.add(
                    mapOf(
                        "id" to id,
                        "uri" to ContentUris.withAppendedId(collection, id).toString(),
                        "name" to c.getString(1),
                        "durationMs" to c.getLong(2),
                        "sizeBytes" to c.getLong(3),
                        "width" to if (rotated) h else w,
                        "height" to if (rotated) w else h,
                        "dateTaken" to taken,
                    ),
                )
            }
        }
        return videos
    }

    fun thumbnail(id: Long, size: Int): ByteArray {
        val uri = ContentUris.withAppendedId(collection, id)
        val bitmap = context.contentResolver.loadThumbnail(uri, Size(size, size), null)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    /**
     * A file path for video [id]. With media permission the real file is usually readable
     * directly (no copy); otherwise it's copied into the cache with [import].
     */
    fun readablePath(id: Long, import: (android.net.Uri) -> String): String {
        val uri = ContentUris.withAppendedId(collection, id)
        @Suppress("DEPRECATION")
        val path = context.contentResolver.query(
            uri, arrayOf(MediaStore.Video.Media.DATA), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (path != null && File(path).canRead()) return path
        return import(uri)
    }
}
