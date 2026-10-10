package com.bloom.bloom

import android.content.Context
import android.util.Log
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
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
    private const val MISSING_CACHE_PROBE_AT = "missingCacheProbeAt"
    private const val MISSING_CACHE_PROBE_EPOCH = "missingCacheProbeEpoch"

    @Synchronized
    fun enqueueIfNeeded(context: Context, cachePath: String?) {
        if (cachePath != null && java.io.File(cachePath).exists()) return
        val prefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
        if (prefs.getBoolean("accountSignedOut", false)) return
        val epoch = try {
            org.json.JSONObject(java.io.File(context.filesDir, "widget-cache/content-sync-epoch.json").readText())
                .optString("token", "")
        } catch (_: Exception) { "" }
        val now = System.currentTimeMillis()
        val previous = if (prefs.contains(MISSING_CACHE_PROBE_AT)) prefs.getLong(MISSING_CACHE_PROBE_AT, 0) else null
        if (!shouldRequestMissingWidgetCache(now, previous, epoch != prefs.getString(MISSING_CACHE_PROBE_EPOCH, null))) return
        // An empty library completes successfully without producing an image.
        // Its content refresh must not immediately start another finished job.
        // Persist before enqueueing so other widget sizes/process restarts share
        // the same bound. Settings/account changes may request immediately;
        // scheduled refills and foreground sync never pass through this gate.
        prefs.edit().putLong(MISSING_CACHE_PROBE_AT, now).putString(MISSING_CACHE_PROBE_EPOCH, epoch).commit()
        try {
            enqueue(
                context = context,
                uniqueName = UNIQUE_WORK,
                existingWorkPolicy = ExistingWorkPolicy.KEEP,
                initialDelaySeconds = 0,
            )
        } catch (error: Exception) {
            prefs.edit().remove(MISSING_CACHE_PROBE_AT).remove(MISSING_CACHE_PROBE_EPOCH).commit()
            throw error
        }
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
        // AppWidgetService loses its cached RemoteViews at reboot. Invalidate
        // image stamps so the first content push supplies a complete view.
        val widgetPrefs = context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE)
        val editor = widgetPrefs.edit()
        widgetPrefs.all.keys.filter { it.startsWith("renderedWidget:") }.forEach { editor.remove(it) }
        editor.apply()
        Log.i(TAG, "Preparing carousel recovery after restart mode=$mode")
        if (mode != "carousel" && !context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.bloom.scheduled_plan", false)) return

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

    fun cancelForSignOut(context: Context) {
        val manager = WorkManager.getInstance(context)
        manager.cancelUniqueWork(UNIQUE_WORK)
        manager.cancelUniqueWork(UNIQUE_RECOVERY_WORK)
    }

    private fun enqueue(
        context: Context,
        uniqueName: String,
        existingWorkPolicy: ExistingWorkPolicy,
        initialDelaySeconds: Long,
    ) {
        if (context.getSharedPreferences("bloom_widget", Context.MODE_PRIVATE).getBoolean("accountSignedOut", false)) return
        // A swipe-away can interrupt Flutter before its finally blocks run.
        // Recover only owners that the OS explicitly reports as terminated;
        // a live/unknown owner still protects its batch and image preparation.
        val lockNames = Regex("(?:carousel-sync|carousel-state|content-sync-epoch|photo-prepare-[0-9]+)\\.lock")
        java.io.File(context.filesDir, "widget-cache").listFiles()?.filter {
            lockNames.matches(it.name)
        }?.forEach { file ->
            if (reclaimTerminatedCarouselOwner(file) { pid ->
                try {
                    Os.kill(pid, 0)
                    false
                } catch (error: ErrnoException) {
                    error.errno == OsConstants.ESRCH
                }
            }) Log.i(TAG, "Recovered interrupted carousel owner: ${file.name}")
        }
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

internal fun shouldRequestMissingWidgetCache(now: Long, previous: Long?, contextChanged: Boolean): Boolean =
    contextChanged || previous == null || now < previous || now - previous >= 5 * 60_000L

internal fun reclaimTerminatedCarouselOwner(file: java.io.File, hasExited: (Int) -> Boolean): Boolean {
    return try {
        val owner = file.readText()
        val pid = owner.substringBefore(':').toIntOrNull() ?: return false
        pid > 0 && hasExited(pid) && file.readText() == owner && file.delete()
    } catch (_: Exception) {
        false
    }
}
