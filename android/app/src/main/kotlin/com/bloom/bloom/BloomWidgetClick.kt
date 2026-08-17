package com.bloom.bloom

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

object BloomWidgetClick {
    fun bind(context: Context, views: RemoteViews) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = android.net.Uri.parse("bloom://today")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            1001,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_image, pendingIntent)
        views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
    }
}
