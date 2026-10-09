import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'core/api/bloom_api_client.dart';
import 'core/storage/daily_content_repository.dart';
import 'core/storage/device_identity_repository.dart';
import 'core/storage/display_preferences.dart';
import 'platform/widget_bridge.dart';

const bloomDailySyncTask = 'com.bloom.bloom.dailySync';

/// **Never let the chain die.**
///
/// 安卓的轮播模式故意取消了 15 分钟周期任务（见 [configureBackgroundSync]），
/// 那时唯一让小组件继续往前走的就是原生精确闹钟链。而那条链**自己不重试**：
/// 一次补货失败（走出 Wi-Fi、照片超时、手机休眠）它就少一环，最后一颗闹钟烧完
/// 之后小组件永远停在同一张照片上——没有任何闹钟、也没有周期任务会来发现这件事。
/// 这不是罕见状态，一次正常通勤就能造出来。
///
/// iOS 那边更极端：根本没有闹钟链，周期任务**就是**补货本身。
///
/// 所以每次失败的同步都补排一个 2 分钟后的 one-off，并带网络约束，好让它等到
/// 联网恢复再跑。WorkManager 按唯一名去重，失败不会堆积。
const bloomRetrySyncTask = 'com.bloom.bloom.retrySync';

/// 失败补一次：**两端都要**。
///
/// 补货链没有别的东西兜底：一次拉取失败（走进隧道、照片超时、手机休眠）如果
/// 就这么算了，链就少一环。iOS 上更是完全没有精确闹钟链，后台任务能被系统
/// 唤醒一次不容易，失败必须自己再排一次。
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

/// 安排（或撤销）周期性后台同步。
///
/// 两端的取舍**故意不同**，因为两端的补货机制本来就不同：
///
/// * 安卓有独立于 App 的精确闹钟链（下一格前 3 分钟唤醒 Dart 跑批）。再叠一个
///   周期 worker 就是两个 Flutter isolate 抢同一把 `carousel-sync.lock`，一次
///   替换/取消会把锁留在原地，之后每次刷新都读到旧批次。所以安卓在轮播模式下
///   **取消**周期任务。
/// * iOS 没有闹钟链，App 不在前台时唯一可能发生的补货就是系统施舍的
///   `BGAppRefreshTask`。这条路径**必须存在**——取消它等于把补货彻底关掉。但它
///   的**注册与提交由 AppDelegate 负责**（`initialize` 仍然要在这里调用，它才是
///   存回调句柄的那一步）。理由见下面 `Platform.isIOS` 分支里的实测记录。
///   而且 iOS 上不存在"两个 isolate 抢锁"：这条路径是唯一的写入者。
///
/// 一句话：安卓那边周期任务是多余的，iOS 这边周期任务是唯一的那条路。
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
/// **两端都要停。** 这条以前只对安卓生效——而 iOS 恰恰是那个"不停就会一直
/// 联网"的端（周期任务现在是它唯一的补货路径）。开关是用户的承诺，不能只在
/// 一半的设备上兑现。
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
      stage = 'device-status';
      final status = await api.status(credentials);
      debugPrint(
        '[BloomSync] device status paired=${status.paired} '
        'hasAssets=${status.hasAssets}',
      );
      if (!status.paired || !status.hasAssets) return true;
      final repository = DailyContentRepository(api: api);
      stage = 'read-settings';
      final preferences = DisplayPreferences();
      // Selections may be sent from a different family member's phone.
      // Refresh this phone's own server record before choosing the pipeline.
      final settings =
          await preferences.readServer(
            credentials: credentials,
            target: BloomApiClient.settingsTargetMobile,
            api: api,
          ) ??
          await preferences.readLocal();
      await preferences.cacheLocal(settings);
      debugPrint('[BloomSync] mode=${settings.mode.name}');
      stage = 'sync-content';
      // Private daily recommendation keeps the existing daily path. Art uses
      // scheduled snapshots in either ranking mode, without changing settings.
      final daily =
          settings.usesScheduledPlan
              ? await repository.syncCarousel(credentials, settings)
              : await repository.sync(credentials);
      stage = 'read-rendered-cache';
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
          originalPhotoPath: await repository.originalPhotoPath(),
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
