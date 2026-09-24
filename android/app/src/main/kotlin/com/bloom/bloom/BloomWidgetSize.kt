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
        // **`MIN_*` is the size the widget *is*; `MAX_*` is the largest it may
        // become.** Reading MAX first made the bitmap bigger than the view, and
        // `centerCrop` then scaled it back down — which scaled the rounded corners
        // baked into it by the same factor, so a 27dp design arrived on the wall as
        // roughly 16dp and the corners looked pointed. The bitmap is meant to land
        // 1:1 on the view; MIN is what the launcher reports for that.
        val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0).takeIf { it > 0 }
            ?: fallbackWidthDp
        val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
            .takeIf { it > 0 }
            ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0).takeIf { it > 0 }
            ?: fallbackHeightDp
        // No pixel floor: forcing the bitmap up to the fallback size only makes
        // `centerCrop` scale it again, which is what shrinks the corners.
        var width = (widthDp * density).toInt().coerceAtLeast(1)
        var height = (heightDp * density).toInt().coerceAtLeast(1)
        val pixels = width.toLong() * height.toLong()
        if (pixels > MAX_BITMAP_PIXELS) {
            val scale = sqrt(MAX_BITMAP_PIXELS.toDouble() / pixels.toDouble())
            width = (width * scale).toInt().coerceAtLeast(1)
            height = (height * scale).toInt().coerceAtLeast(1)
        }
        return Pair(width, height)
    }
}
