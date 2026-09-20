import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'core/api/bloom_api_client.dart';
import 'core/storage/daily_content_repository.dart';
import 'core/storage/device_identity_repository.dart';
import 'core/storage/display_preferences.dart';
import 'platform/widget_bridge.dart';

const bloomDailySyncTask = 'com.bloom.bloom.dailySync';

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
                  : 'recommendation',
        );
      }
      debugPrint(
        '[BloomSync] completed recommendation=${daily.recommendationId}',
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('[BloomSync] failed at stage=$stage: $error');
      debugPrintStack(stackTrace: stackTrace);
      // Keep the previous successful cache and let WorkManager retry later.
      return false;
    }
  });
}
