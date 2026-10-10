package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Bundle
import java.io.File

class BloomLargeSquareWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.getBooleanExtra("bloomAccountReset", false)) {
            BloomWidgetRefresh.cancelForSignOut(context)
            val ids = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS) ?: intArrayOf()
            BloomWidgetImageUpdate.forget(context, ids)
            return
        }
        if (intent.getBooleanExtra(BLOOM_CAROUSEL_ALARM_EXTRA, false)) {
            BloomCarouselSchedule.applyLatestDueEntry(context, intent)
        }
        val internalRefresh = intent.getBooleanExtra(BloomWidgetImageUpdate.CONTENT_ONLY_EXTRA, false) ||
            intent.getBooleanExtra(BLOOM_CAROUSEL_ALARM_EXTRA, false)
        if (intent.action == AppWidgetManager.ACTION_APPWIDGET_UPDATE && internalRefresh) {
            val ids = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS)
            if (ids != null) updateContent(context, AppWidgetManager.getInstance(context), ids)
        } else {
            // The host may have discarded its view even when the image did
            // not change. A genuine host request must restore a full snapshot.
            super.onReceive(context, intent)
        }
        if (intent.getBooleanExtra(BLOOM_CAROUSEL_REFILL_EXTRA, false)) {
            // Refill is independent of rendering: unchanged pixels skip the
            // launcher update, while WorkManager still prepares the next batch.
            try { BloomWidgetRefresh.enqueueRecovery(context) } catch (_: Exception) { }
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        updateContent(context, manager, ids, forceFull = true)
    }

    fun updateContent(context: Context, manager: AppWidgetManager, ids: IntArray, forceFull: Boolean = false) {
        BloomCarouselSchedule.applyLatestDueEntryIfCarousel(context)
        val path = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
            .getString("mobileLocalLargeSquarePath", null)
            ?: File(context.filesDir, "widget-cache/mobile-local-largeSquare.png").absolutePath
        try { BloomWidgetRefresh.enqueueIfNeeded(context, path) } catch (_: Exception) { }
        BloomWidgetImageUpdate.update(context, manager, ids, path, R.layout.widget_large_square, 280, 280, forceFull)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        updateContent(context, manager, intArrayOf(id), forceFull = true)
    }

    override fun onRestored(context: Context, oldIds: IntArray, newIds: IntArray) {
        BloomWidgetImageUpdate.forget(context, oldIds + newIds)
        updateContent(context, AppWidgetManager.getInstance(context), newIds, forceFull = true)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        BloomWidgetImageUpdate.forget(context, ids)
    }
}
