package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.BitmapFactory
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.security.MessageDigest

/** Metadata refill must not redraw the launcher. Publish only changed pixels,
 * and preserve the previous RemoteViews if a new image cannot be decoded. */
object BloomWidgetImageUpdate {
    const val CONTENT_ONLY_EXTRA = "bloomContentOnly"
    // A disk stamp survives the system/launcher losing RemoteViews. It is not
    // evidence that a newly started provider still has a published image.
    private val rendered = mutableMapOf<Int, String>()

    fun update(
        context: Context, manager: AppWidgetManager, ids: IntArray, path: String,
        layout: Int, fallbackWidth: Int, fallbackHeight: Int, forceFull: Boolean,
    ) {
        if (context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE).getBoolean("accountSignedOut", false)) {
            ids.forEach { id ->
                if (forceFull || rendered[id] != "signed-out") {
                    val views = RemoteViews(context.packageName, layout)
                    BloomWidgetClick.bind(context, views)
                    views.setTextViewText(R.id.widget_placeholder, "请登录 Bloom")
                    manager.updateAppWidget(id, views)
                    rendered[id] = "signed-out"
                }
            }
            return
        }
        val file = File(path)
        val bytes = try { file.readBytes() } catch (_: Exception) { return }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        var bitmap: android.graphics.Bitmap? = null
        ids.forEach { id ->
            val (width, height) = BloomWidgetSize.pixels(context, manager, id, fallbackWidth, fallbackHeight)
            val stamp = "$digest@$width:$height"
            val previous = rendered[id]
            if (!forceFull && previous == stamp) {
                Log.d("BloomWidgetImage", "unchanged id=$id; skip")
                return@forEach
            }
            if (bitmap == null) bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            val image = bitmap ?: return@forEach
            val views = RemoteViews(context.packageName, layout)
            BloomWidgetClick.bind(context, views)
            val rounded = BloomRoundedBitmap.create(image, context, width, height)
            views.setImageViewBitmap(R.id.widget_image, rounded)
            views.setViewVisibility(R.id.widget_placeholder, View.GONE)
            // Always publish a complete, image-filled snapshot when pixels
            // change. A partial update cannot restore a missing system view.
            manager.updateAppWidget(id, views)
            rendered[id] = stamp
            Log.i("BloomWidgetImage", "published id=$id full=true hostRequest=$forceFull")
            if (rounded !== image) rounded.recycle()
        }
        bitmap?.recycle()
    }

    fun forget(context: Context, ids: IntArray) {
        ids.forEach { rendered.remove(it) }
    }
}
