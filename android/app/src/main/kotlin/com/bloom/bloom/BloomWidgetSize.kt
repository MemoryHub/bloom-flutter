package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.content.Context
import kotlin.math.sqrt

object BloomWidgetSize {
    private const val MAX_BITMAP_PIXELS = 220_000

    fun pixels(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        fallbackWidthDp: Int,
        fallbackHeightDp: Int,
    ): Pair<Int, Int> {
        val options = manager.getAppWidgetOptions(id)
        val density = context.resources.displayMetrics.density
        val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0).takeIf { it > 0 }
            ?: fallbackWidthDp
        val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0).takeIf { it > 0 }
            ?: fallbackHeightDp
        var width = (widthDp * density).toInt().coerceAtLeast(fallbackWidthDp)
        var height = (heightDp * density).toInt().coerceAtLeast(fallbackHeightDp)
        val pixels = width.toLong() * height.toLong()
        if (pixels > MAX_BITMAP_PIXELS) {
            val scale = sqrt(MAX_BITMAP_PIXELS.toDouble() / pixels.toDouble())
            width = (width * scale).toInt().coerceAtLeast(1)
            height = (height * scale).toInt().coerceAtLeast(1)
        }
        return Pair(width, height)
    }
}
