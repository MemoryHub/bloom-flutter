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
        val radius = 18f * context.resources.displayMetrics.density
        canvas.drawRoundRect(RectF(0f, 0f, targetWidth.toFloat(), targetHeight.toFloat()), radius, radius, paint)
        if (cropped !== scaled) cropped.recycle()
        if (scaled !== source) scaled.recycle()
        return rounded
    }
}
