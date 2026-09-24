package com.bloom.bloom

import android.appwidget.AppWidgetManager
import android.content.Context
import kotlin.math.sqrt

object BloomWidgetSize {
    /// **Big enough that the bitmap is not shrunk below the view it fills.**
    ///
    /// The old 220k ceiling did not just soften the photo: the view then scaled
    /// the bitmap back *up* to fill the widget, and everything baked into it —
    /// including the 18dp corner radius — was scaled up with it. At 0.81x the
    /// corners came out at ~22dp, past the radius the launcher clips widgets to,
    /// and the cream background showed through as a white wedge in the corners.
    /// A 4x2 widget at 3x density is ~1.0M pixels; this leaves room above that.
    private const val MAX_BITMAP_PIXELS = 1_200_000

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
        // The floor is a *dp* value, so it converts like the size above does;
        // comparing pixels against a bare dp number meant a nonsense minimum.
        var width =
            (widthDp * density).toInt().coerceAtLeast((fallbackWidthDp * density).toInt())
        var height =
            (heightDp * density).toInt().coerceAtLeast((fallbackHeightDp * density).toInt())
        val pixels = width.toLong() * height.toLong()
        if (pixels > MAX_BITMAP_PIXELS) {
            val scale = sqrt(MAX_BITMAP_PIXELS.toDouble() / pixels.toDouble())
            width = (width * scale).toInt().coerceAtLeast(1)
            height = (height * scale).toInt().coerceAtLeast(1)
        }
        return Pair(width, height)
    }
}
