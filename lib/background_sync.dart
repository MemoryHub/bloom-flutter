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
/// In carousel mode the 15-minute worker is deliberately cancelled (see
/// [configureBackgroundSync]) and the only thing that keeps the widget moving is
/// the native exact-alarm chain. Nothing in that chain retries: when a refill
/// fails — commuting out of Wi-Fi range, a photo that times out, a sleeping
/// phone — the chain is simply not extended, its last alarm fires, and the
/// widget then sits on the same photo **forever**, with no alarm left anywhere
/// and no periodic task to notice. That is not a rare state: it is what a normal
/// commute produces.
///
/// So every failed sync arms a one-off retry a couple of minutes out, with a
/// network constraint so it waits for connectivity to come back. WorkManager
/// de-duplicates by unique name, so a queue of failures cannot pile up.
const bloomRetrySyncTask = 'com.bloom.bloom.retrySync';

Future<void> _armRetry() async {
  if (!Platform.isAndroid) return;
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

Future<void> initializeBackgroundSync() async {
  await Workmanager().initialize(_backgroundCallback);
  if (Platform.isIOS) return;
  await configureBackgroundSync(await DisplayPreferences().read());
}

Future<void> configureBackgroundSync(BloomDisplaySettings settings) async {
  if (!Platform.isAndroid) return;
  // Carousel has its own exact-alarm refill chain. Keeping the generic
  // periodic worker as well creates two Flutter isolates that race for the
  // same carousel-sync.lock; a replacement/cancellation can then strand that
  // lock and leave every later widget refresh showing the old batch.
  if (settings.mode == BloomDisplayMode.carousel) {
    await Workmanager().cancelByUniqueName(bloomDailySyncTask);
    return;
  }
  await Workmanager().registerPeriodicTask(
    bloomDailySyncTask,
    bloomDailySyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 5),
  );
}

/// Stops the generic periodic worker.
///
/// The other half of switching the widget off — [DisplayPreferences
/// .clearRemoteSchedule] stops the carousel's exact-alarm chain, this stops the
/// 15-minute worker. Both have to go: leaving either armed means the device keeps
/// waking and (in the worker's case) keeps calling the server for a widget the
/// user has switched off.
Future<void> disableBackgroundSync() async {
  if (!Platform.isAndroid) return;
  await Workmanager().cancelByUniqueName(bloomDailySyncTask);
  // The retry is part of the same promise: a widget the user switched off must
  // not keep waking the phone to refill itself.
  await Workmanager().cancelByUniqueName(bloomRetrySyncTask);
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
      final settings = await DisplayPreferences().read();
      debugPrint('[BloomSync] mode=${settings.mode.name}');
      stage = 'sync-content';
      // ⚠️ 推荐【不能】改走轮播引擎。
      //
      // 接口是一套（同一批端点、同一份设置），但推荐有自己的**推荐算法** ——
      // 由服务器实现（按天出推荐，不是把轮播计划的间隔调慢）。曾经试过让
      // 推荐复用 syncCarousel，结果是: 推荐的节奏被换成"作息 + 间隔"的格子，
      // 当前格 12 小时不变 → 照片不换；切回轮播时作息又被推荐值覆盖 →
      // 变成半天一次。所以两条路必须各自保留。
      final daily =
          settings.mode == BloomDisplayMode.carousel
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
          mode:
              settings.mode == BloomDisplayMode.carousel
                  ? 'carousel'
                  : 'recommend',
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
