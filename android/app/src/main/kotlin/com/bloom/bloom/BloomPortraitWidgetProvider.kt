package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.graphics.BitmapFactory
import android.view.View
import java.io.File

class BloomPortraitWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.getBooleanExtra(BLOOM_CAROUSEL_REFILL_EXTRA, false)) {
            BloomCarouselSchedule.applyLatestDueEntry(context, intent)
            super.onReceive(context, intent)
            // Keep the AppWidget broadcast short. Network and Flutter work
            // belongs to WorkManager; holding goAsync while a headless Flutter
            // engine performs I/O can trigger MIUI's 60-second broadcast ANR.
            try { BloomWidgetRefresh.enqueueRecovery(context) } catch (_: Exception) { }
            return
        }
        if (intent.getBooleanExtra(BLOOM_CAROUSEL_ALARM_EXTRA, false)) {
            BloomCarouselSchedule.applyLatestDueEntry(context, intent)
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
        val path = prefs.getString("mobileLocalPortraitPath", null)
            ?: File(context.filesDir, "widget-cache/mobile-local-portrait.png").absolutePath
        try {
            BloomWidgetRefresh.enqueueIfNeeded(context, path)
        } catch (_: Exception) {
            // The app may not have been opened yet, so Workmanager may not
            // have a Dart callback handle. Keep the widget receiver alive.
        }
        ids.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.widget_portrait)
            BloomWidgetClick.bind(context, views)
            BitmapFactory.decodeFile(File(path).absolutePath)?.let {
                val (width, height) = BloomWidgetSize.pixels(context, manager, id, 180, 300)
                views.setImageViewBitmap(R.id.widget_image, BloomRoundedBitmap.create(it, context, width, height))
                views.setViewVisibility(R.id.widget_placeholder, View.GONE)
            }
            manager.updateAppWidget(id, views)
        }
    }
}
