package com.bloom.bloom

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

object BloomRoundedBitmap {
    fun create(source: Bitmap, context: Context, targetWidth: Int = source.width, targetHeight: Int = source.height): Bitmap {
        val scale = maxOf(targetWidth.toFloat() / source.width, targetHeight.toFloat() / source.height)
        val scaledWidth = (source.width * scale).toInt()
        val scaledHeight = (source.height * scale).toInt()
        val scaled = if (scaledWidth != source.width || scaledHeight != source.height) {
            Bitmap.createScaledBitmap(source, scaledWidth, scaledHeight, true)
        } else source
        val left = ((scaled.width - targetWidth) / 2).coerceAtLeast(0)
        val top = ((scaled.height - targetHeight) / 2).coerceAtLeast(0)
        val cropped = if (scaled.width != targetWidth || scaled.height != targetHeight) {
            Bitmap.createBitmap(scaled, left, top, targetWidth.coerceAtMost(scaled.width), targetHeight.coerceAtMost(scaled.height))
        } else scaled
        val rounded = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(rounded)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            shader = android.graphics.BitmapShader(
                cropped,
                android.graphics.Shader.TileMode.CLAMP,
                android.graphics.Shader.TileMode.CLAMP,
            )
        }
        // **The photo is what rounds the widget, so this radius is the design.**
        //
        // The card look comes from this cut: the photo's own rounded rect is the
        // widget's visible outline, and the cream background never shows because
        // the photo covers all of it. Two things must hold for that:
        //
        //   * the bitmap has to arrive at (about) the size of the view. It used
        //     to be shrunk by `MAX_BITMAP_PIXELS` and then scaled back up by
        //     `centerCrop`, which magnified this radius with it — 18dp came out
        //     near 22dp, past the radius the launcher clips the widget to, and the
        //     cream leaked through as the white wedge in the corners;
        //   * this radius must stay *under* that launcher radius. Capping it by
        //     the platform's `system_app_widget_background_radius` was tried and
        //     was wrong: MIUI reports a value far smaller than this design, so the
        //     corners all but disappeared. 16dp is the design's 18dp minus a
        //     deliberate 2dp of headroom for the small scaling a widget resize can
        //     still introduce.
        // The design's own arc — the app's home-page card is 27 (logical px), and
        // this is that number on the widget. It stays safe because the *photo*
        // defines the widget's outline here: as long as the radius is no larger
        // than the background's, the photo covers the background completely and
        // no cream can show. The background is drawn at 28dp for exactly that
        // headroom.
        val radius = 27f * context.resources.displayMetrics.density
        canvas.drawRoundRect(RectF(0f, 0f, targetWidth.toFloat(), targetHeight.toFloat()), radius, radius, paint)
        if (cropped !== scaled) cropped.recycle()
        if (scaled !== source) scaled.recycle()
        return rounded
    }
}
