# Bloom BLE provisioning bridge

Android/iOS Flutter method channel using Espressif Security1. Wi-Fi credentials and PoP are passed in memory; bridge logging and persistence are disabled. `bloom-setup` carries device-scoped, nonce-bound server authorization. The bridge never uses the stock unauthenticated configuration endpoint.

- Android: API 23+, Java 11; Android 12+ Bluetooth scan/connect permission, earlier systems location permission. Official SDK source and provenance: `vendor/android/UPSTREAM.txt`.
- iOS: iOS 14+, Swift 5; Bluetooth usage descriptions in the host app. Official SDK source and provenance: `ios/Vendor/UPSTREAM.txt`. Vendor files reside within the local podspec root so CocoaPods includes them in its compile sources.
- SwiftProtobuf 1.22.0 is pinned to Apple's official Git revision in the host Podfile. See `ios/Podfile.lock` for reproducible dependency resolution.

Methods: `scan`, `connect`, `networks`, `data`, `disconnect`, `settings`. Only one operation runs at a time. Generation checks prevent callbacks from completing later operations. Android connection events also include their emitting device/transport instance, so delayed disconnects from an earlier connection are ignored.

For the host event identity regression, configure a JDK with `JAVA_HOME` or `java`/`javac` on PATH, then run:

```sh
python3 packages/bloom_provision/tool/test_connection_events.py
```

Native builds and mocked Flutter tests do not substitute for physical Bluetooth permission, scanning, session, Wi-Fi coexistence or energy testing on both platforms.
