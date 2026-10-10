import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'core/api/bloom_api_client.dart';
import 'core/storage/daily_content_repository.dart';
import 'core/storage/device_identity_repository.dart';
import 'core/storage/display_preferences.dart';
import 'core/storage/content_sync_epoch.dart';
import 'platform/widget_bridge.dart';

const bloomDailySyncTask = 'com.bloom.bloom.dailySync';

/// 同步失败后补排联网重试，保持 Android 的补货链及 iOS 宿主后台兜底。
/// iOS 小组件扩展另外通过后台 URLSession 补货，共用同一计划和批次锁。
const bloomRetrySyncTask = 'com.bloom.bloom.retrySync';

/// 网络恢复后再尝试；唯一任务名避免失败重试堆积。
Future<void> _armRetry() async {
  try {
    await Workmanager().registerOneOffTask(
      bloomRetrySyncTask,
      bloomDailySyncTask,
      initialDelay: const Duration(minutes: 2),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
    debugPrint('[BloomSync] retry armed for +2min');
  } catch (error) {
    debugPrint('[BloomSync] could not arm retry: $error');
  }
}

/// 这个 App 只发 iOS / 安卓。
///
/// 桌面与测试宿主上既没有闹钟链、也没有 `BGTaskScheduler`，workmanager 更没有
/// 对应实现——在那里调用后台任务只会撞上不存在的插件通道。那是环境的噪声，
/// 不是产品行为，所以先挡掉。
bool get _backgroundSyncSupported => Platform.isAndroid || Platform.isIOS;

/// 后台同步是**增强**，不是主流程：任何一步失败都必须安静退化，绝不能把启动
/// 或切模式打断。这个 App 只发 iOS / 安卓，但测试宿主是 macOS，workmanager 在
/// 那里没有实现，`MissingPluginException` 会直接抛出来。
Future<void> _guardBackgroundSync(
  String what,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    debugPrint('[BloomSync] $what failed: $error');
  }
}

Future<void> initializeBackgroundSync() async {
  await _guardBackgroundSync(
    'initialize',
    () => Workmanager().initialize(_backgroundCallback),
  );
  await configureBackgroundSync(await DisplayPreferences().read());
}

/// Android 计划模式用原生闹钟与恢复 worker 补货，避免叠加周期任务。
/// iOS 宿主 BGAppRefreshTask 由 AppDelegate 注册和续排，作为后台兜底；
/// 宿主不运行时，WidgetKit 扩展仍可独立补货。所有入口共用批次锁。
Future<void> configureBackgroundSync(BloomDisplaySettings settings) async {
  if (!_backgroundSyncSupported) return;
  final wantPeriodic = Platform.isIOS || !settings.usesScheduledPlan;
  if (!wantPeriodic) {
    await _guardBackgroundSync(
      'cancel periodic',
      () => Workmanager().cancelByUniqueName(bloomDailySyncTask),
    );
    return;
  }
  if (Platform.isIOS) {
    // **iOS 的首次提交交给 AppDelegate，这里不再注册。**
    //
    // 两个原因，都是 2026-09-30 真机实测出来的：
    //
    // 1. 这条通道的 `initialDelay` 默认是 `Duration.zero`，插件会把它变成
    //    `earliestBeginDate = 现在`。苹果的建议是至少提前几分钟——"现在"既可能
    //    被系统冷落，也会**覆盖掉** AppDelegate 那条带 15 分钟提前量的请求。
    // 2. 插件在 `submit` 失败时只 `logInfo` 一句就把 `result(true)` 回给 Dart，
    //    失败在任何一端都不可见；而且它的 `handlePeriodicTask` 在回调句柄查找
    //    失败时会**提前 return、连下一次都不续排**，链条会无声断掉。
    //
    // 现在 iOS 的后台任务生命周期（注册 handler、首次提交、续排、结果记录）全部
    // 由 AppDelegate 掌握，两端都能看得见。这里只需要 `initialize` 存好回调句柄
    // ——它在 [initializeBackgroundSync] 里已经调用过了。
    return;
  }
  await _guardBackgroundSync(
    'register periodic',
    () => Workmanager().registerPeriodicTask(
      bloomDailySyncTask,
      // 唯一名同时也是 iOS 的 BGTask 标识符，必须与 `AppDelegate` 里
      // `WorkmanagerPlugin.registerPeriodicTask` 的入参、以及 Info.plist 的
      // `BGTaskSchedulerPermittedIdentifiers` 三处一致。
      bloomDailySyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    ),
  );
}

/// Stops the background sync entirely.
///
/// The other half of switching the widget off — [DisplayPreferences
/// .clearRemoteSchedule] stops the carousel's exact-alarm chain on Android, this
/// stops the periodic worker. Both have to go: leaving either armed means the
/// device keeps waking and keeps calling the server for a widget the user has
/// switched off.
///
/// 两端都撤销宿主后台任务。Android 的原生轮播链由 clearRemoteSchedule 撤销。
Future<void> disableBackgroundSync() async {
  if (!_backgroundSyncSupported) return;
  await _guardBackgroundSync(
    'stop periodic',
    () => Workmanager().cancelByUniqueName(bloomDailySyncTask),
  );
  // The retry is part of the same promise: a widget the user switched off must
  // not keep waking the phone to refill itself.
  await _guardBackgroundSync(
    'stop retry',
    () => Workmanager().cancelByUniqueName(bloomRetrySyncTask),
  );
}

@pragma('vm:entry-point')
void _backgroundCallback() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    var stage = 'start';
    try {
      debugPrint('[BloomSync] task=$task started');
      stage = 'read-credentials';
      final credentials = await DeviceIdentityRepository().read();
      if (credentials == null) {
        debugPrint('[BloomSync] no credentials; skip');
        return true;
      }
      final api = BloomApiClient();
      final preferences = DisplayPreferences();
      if (!await preferences.readWidgetEnabled()) return true;
      final cachePath = await WidgetBridge().cacheDirectory();
      final beforeSettings =
          cachePath == null
              ? null
              : await ContentSyncEpoch.capture(Directory(cachePath));
      stage = 'device-status';
      final status = await api.status(credentials);
      debugPrint(
        '[BloomSync] device status paired=${status.paired} '
        'hasAssets=${status.hasAssets}',
      );
      if (!status.paired || !status.hasAssets) return true;
      final repository = DailyContentRepository(api: api);
      stage = 'read-settings';
      // Selections may be sent from a different family member's phone.
      // Refresh this phone's own server record before choosing the pipeline.
      final settings =
          await preferences.readServer(
            credentials: credentials,
            target: BloomApiClient.settingsTargetMobile,
            api: api,
          ) ??
          await preferences.readLocal();
      if (beforeSettings != null && !await beforeSettings.isCurrent()) {
        return true;
      }
      await preferences.cacheLocal(settings);
      final epoch =
          cachePath == null
              ? null
              : await ContentSyncEpoch.capture(Directory(cachePath));
      debugPrint('[BloomSync] mode=${settings.mode.name}');
      stage = 'sync-content';
      final daily = await repository.syncCarousel(credentials, settings);
      stage = 'read-rendered-cache';
      if (epoch != null && !await epoch.isCurrent()) return true;
      final portrait = await repository.cached('portrait');
      final square = await repository.cached('square');
      final largeSquare = await repository.cached('largeSquare');
      if (portrait != null) {
        stage = 'update-widget';
        await WidgetBridge().update(
          portraitPath: portrait.path,
          squarePath: square?.path ?? portrait.path,
          largeSquarePath: largeSquare?.path ?? portrait.path,
          date: daily.date,
          recommendationId: daily.recommendationId,
          originalPhotoPath: await repository.photoPathFor(
            daily.recommendationId,
          ),
          captionZh: daily.captionZh,
          captionEn: daily.captionEn,
          capturedDateText: daily.capturedDateText,
          locationText: daily.locationText,
          mode: settings.usesScheduledPlan ? 'carousel' : 'recommend',
        );
      }
      debugPrint(
        '[BloomSync] completed recommendation=${daily.recommendationId}',
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('[BloomSync] failed at stage=$stage: $error');
      debugPrintStack(stackTrace: stackTrace);
      // Keep the previous successful cache, and make sure something comes back
      // to try again — in carousel mode nothing else will.
      await _armRetry();
      return false;
    }
  });
}
