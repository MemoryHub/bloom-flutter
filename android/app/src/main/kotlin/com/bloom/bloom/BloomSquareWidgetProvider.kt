package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import java.io.File

class BloomSquareWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.getBooleanExtra(BLOOM_CAROUSEL_ALARM_EXTRA, false)) {
            BloomCarouselSchedule.applyLatestDueEntry(context, intent)
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val path = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
            .getString("mobileLocalSquarePath", null)
            ?: File(context.filesDir, "widget-cache/mobile-local-square.png").absolutePath
        try { BloomWidgetRefresh.enqueueIfNeeded(context, path) } catch (_: Exception) { }
        ids.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.widget_square)
            BloomWidgetClick.bind(context, views)
            BitmapFactory.decodeFile(path)?.let {
                val (width, height) = BloomWidgetSize.pixels(context, manager, id, 180, 180)
                views.setImageViewBitmap(R.id.widget_image, BloomRoundedBitmap.create(it, context, width, height))
                views.setViewVisibility(R.id.widget_placeholder, View.GONE)
            }
            manager.updateAppWidget(id, views)
        }
    }
}
