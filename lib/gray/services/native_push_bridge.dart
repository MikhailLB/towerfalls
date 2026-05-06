import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads cold-start push URLs that SceneDelegate captured before any Dart
/// code was alive.
///
/// ## Why this exists
///
/// On iOS 13+ apps that declare `UIApplicationSceneManifest` (every modern
/// Flutter iOS template, this app included), a notification tap that
/// launches the app from killed state is delivered to the SceneDelegate via
/// `connectionOptions.notificationResponse` — NOT to the AppDelegate's
/// `launchOptions[remoteNotification]`. Firebase Messaging's swizzle only
/// reads `launchOptions`, so `getInitialMessage()` returns null in that
/// case and the URL embedded in the push is silently lost.
///
/// `SceneDelegate.swift` works around this by extracting the URL from
/// `notificationResponse.notification.request.content.userInfo` and writing
/// it into `UserDefaults.standard` under
/// `flutter.tf_gray_native_cold_start_url`.
///
/// The `flutter.` prefix is critical: the Flutter `shared_preferences`
/// plugin on iOS namespaces every SharedPreferences key under that prefix,
/// so writing it from Swift via `UserDefaults.set(_:forKey:)` is exactly
/// equivalent to `SharedPreferences.setString('tf_gray_native_cold_start_url', ...)`
/// from Dart. Reading it back works the same way.
///
/// This avoids any MethodChannel timing race — UserDefaults is durable across
/// the launch → Dart-runtime handover, and SharedPreferences is the very
/// first plugin that resolves on bootstrap.
class NativePushBridge {
  static const String _key = 'tf_gray_native_cold_start_url';

  /// Returns the URL captured by [SceneDelegate] on cold-start tap (if any)
  /// and atomically clears it from UserDefaults so it isn't replayed on the
  /// next launch. Safe to call on any platform — returns null on non-iOS.
  static Future<String?> consumeColdStartUrl() async {
    if (!Platform.isIOS) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) {
        debugPrint('[TF.NATIVE] consumeColdStartUrl -> null');
        return null;
      }
      // Atomic-ish: remove BEFORE returning so a future launch never replays
      // a stale tap, even if the caller crashes after this point.
      await prefs.remove(_key);
      debugPrint('[TF.NATIVE] consumeColdStartUrl -> $raw');
      return raw.trim();
    } catch (err) {
      debugPrint('[TF.NATIVE] consumeColdStartUrl failed: $err');
      return null;
    }
  }
}
