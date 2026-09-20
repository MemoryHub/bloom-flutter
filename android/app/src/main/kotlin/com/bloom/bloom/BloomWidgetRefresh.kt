package com.bloom.bloom

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.WM

/** Requests the already-initialized Flutter background isolate to sync once.
 * The App must have been opened at least once so Workmanager has a callback
 * handle and the device credentials have been created.
 */
object BloomWidgetRefresh {
    private const val TAG = "BloomWidgetRefresh"
    private const val UNIQUE_WORK = "com.bloom.bloom.widgetInstallSync"
    private const val UNIQUE_RECOVERY_WORK = "com.bloom.bloom.widgetRecoverySync"
    private const val DART_TASK = "com.bloom.bloom.dailySync"

    fun enqueueIfNeeded(context: Context, cachePath: String?) {
        if (cachePath != null && java.io.File(cachePath).exists()) return
        enqueue(
            context = context,
            uniqueName = UNIQUE_WORK,
            existingWorkPolicy = ExistingWorkPolicy.KEEP,
            initialDelaySeconds = 0,
        )
    }

    /**
     * Keeps a network-constrained recovery job behind the direct refill.
     * When the refill fires offline the job waits for validated connectivity;
     * when the process is killed midway it survives and retries the batch.
     */
    fun enqueueRecovery(context: Context, initialDelaySeconds: Long = 0) {
        enqueue(
            context = context,
            uniqueName = UNIQUE_RECOVERY_WORK,
            // A second refill alarm must not cancel a download/render already
            // in progress. Cancellation destroys the Flutter isolate before
            // its finally block can remove carousel-sync.lock.
            existingWorkPolicy = ExistingWorkPolicy.KEEP,
            initialDelaySeconds = initialDelaySeconds,
        )
    }

    fun enqueueRecoveryAfterRestart(context: Context) {
        enqueue(
            context = context,
            uniqueName = UNIQUE_RECOVERY_WORK,
            // The old app process is already gone after package replacement
            // or boot, so replacing a persisted RETRY chain is safe here.
            existingWorkPolicy = ExistingWorkPolicy.REPLACE,
            initialDelaySeconds = 0,
        )
    }

    fun prepareCarouselRecoveryAfterRestart(context: Context) {
        val mode = context
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.bloom.display_mode", null)
        Log.i(TAG, "Preparing carousel recovery after restart mode=$mode")
        if (mode != "carousel") return

        // Carousel refill alarms replace the generic 15-minute worker. The
        // two schedules running together were the source of overlapping Dart
        // isolates and the permanently stranded sync lock.
        WorkManager.getInstance(context).cancelUniqueWork(DART_TASK)

        // Package replacement and boot guarantee that no previous Bloom
        // process is still the legitimate owner of this file.
        val staleLock = java.io.File(context.filesDir, "widget-cache/carousel-sync.lock")
        if (staleLock.exists() && !staleLock.delete()) {
            Log.w(TAG, "Unable to remove stale carousel sync lock")
        }
    }

    fun cancelRecovery(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_RECOVERY_WORK)
    }

    private fun enqueue(
        context: Context,
        uniqueName: String,
        existingWorkPolicy: ExistingWorkPolicy,
        initialDelaySeconds: Long,
    ) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        WM.enqueueOneOffTask(
            context = context,
            uniqueName = uniqueName,
            dartTask = DART_TASK,
            existingWorkPolicy = existingWorkPolicy,
            initialDelaySeconds = initialDelaySeconds,
            constraintsConfig = constraints,
            // Carousel refill is time-sensitive and is initiated by an exact
            // widget alarm. Expedited work receives a temporary execution
            // exemption so HyperOS does not freeze the process and tear down
            // its sockets a few seconds after the app moves to background.
            outOfQuotaPolicy = OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST,
            backoffPolicyConfig = null,
        )
    }
}
