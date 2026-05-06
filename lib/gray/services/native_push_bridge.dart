import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin bridge to the native iOS SceneDelegate that captures cold-start push
/// taps which Firebase swizzle silently drops on scene-based apps.
///
/// Background: On iOS 13+ apps that declare `UIApplicationSceneManifest` (i.e.
/// every modern Flutter iOS template), a notification tap that launches the
/// app from killed state is delivered to the SceneDelegate via
/// `connectionOptions.notificationResponse` — NOT to the AppDelegate's
/// `launchOptions[remoteNotification]`. Firebase Messaging's swizzle only
/// reads launchOptions, so `getInitialMessage()` returns null in that case
/// and the URL embedded in the push is silently lost.
///
/// SceneDelegate.swift writes the URL into `UserDefaults` under
/// [_coldStartUrlKey]; this class reads + clears it. Independent of FCM init,
/// APNs availability, or any timeout race.
class NativePushBridge {
  static const MethodChannel _channel =
      MethodChannel('tower_falls/gray/native_push');

  /// Returns the URL captured by [SceneDelegate] on cold-start tap (if any)
  /// and atomically clears it from UserDefaults. Safe to call on platforms
  /// other than iOS — returns null without invoking the channel.
  static Future<String?> consumeColdStartUrl() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMethod<String?>('consumeColdStartUrl');
      if (raw == null || raw.isEmpty) {
        debugPrint('[TF.NATIVE] consumeColdStartUrl -> null');
        return null;
      }
      debugPrint('[TF.NATIVE] consumeColdStartUrl -> $raw');
      return raw;
    } on PlatformException catch (err) {
      debugPrint('[TF.NATIVE] consumeColdStartUrl PlatformException: $err');
      return null;
    } catch (err) {
      debugPrint('[TF.NATIVE] consumeColdStartUrl failed: $err');
      return null;
    }
  }
}
