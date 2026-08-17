package com.bloom.bloom

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import dev.fluttercommunity.workmanager.WM

/** Requests the already-initialized Flutter background isolate to sync once.
 * The App must have been opened at least once so Workmanager has a callback
 * handle and the device credentials have been created.
 */
object BloomWidgetRefresh {
    private const val UNIQUE_WORK = "com.bloom.bloom.widgetInstallSync"
    private const val DART_TASK = "com.bloom.bloom.dailySync"

    fun enqueueIfNeeded(context: Context, cachePath: String?) {
        if (cachePath != null && java.io.File(cachePath).exists()) return
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        WM.enqueueOneOffTask(
            context = context,
            uniqueName = UNIQUE_WORK,
            dartTask = DART_TASK,
            existingWorkPolicy = ExistingWorkPolicy.KEEP,
            constraintsConfig = constraints,
            backoffPolicyConfig = null,
        )
    }
}
