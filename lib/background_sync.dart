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
  await Workmanager().registerPeriodicTask(
    bloomDailySyncTask,
    bloomDailySyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 30),
  );
}

@pragma('vm:entry-point')
void _backgroundCallback() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final credentials = await DeviceIdentityRepository().read();
      if (credentials == null) return true;
      final api = BloomApiClient();
      final status = await api.status(credentials);
      if (!status.paired || !status.hasAssets) return true;
      final repository = DailyContentRepository(api: api);
      final settings = await DisplayPreferences().read();
      final daily =
          settings.mode == BloomDisplayMode.carousel
              ? await repository.syncCarousel(credentials, settings)
              : await repository.sync(credentials);
      final portrait = await repository.cached('portrait');
      final square = await repository.cached('square');
      final largeSquare = await repository.cached('largeSquare');
      if (portrait != null) {
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
      return true;
    } catch (_) {
      // Keep the previous successful cache and let WorkManager retry later.
      return false;
    }
  });
}
