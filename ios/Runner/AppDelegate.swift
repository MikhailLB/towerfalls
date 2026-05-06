import FirebaseMessaging
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register all Flutter plugins (including firebase_messaging) eagerly so
    // that FCM can install its UNUserNotificationCenterDelegate swizzle before
    // any notification taps are delivered. With FlutterImplicitEngineDelegate
    // the plugin registration was deferred (lazy), which caused the swizzle to
    // arrive too late and notification tap callbacks were silently dropped.
    GeneratedPluginRegistrant.register(with: self)

    // FirebaseAppDelegateProxyEnabled=YES in Info.plist means Firebase
    // Messaging swizzles AppDelegate methods automatically (APNs token
    // forwarding, didReceiveRemoteNotification, etc.).  No manual calls to
    // FirebaseApp.configure(), registerForRemoteNotifications(), or
    // Messaging.messaging().apnsToken are needed.
    //
    // Cold-start push URLs (from killed-app taps) are captured by
    // SceneDelegate.scene(_:willConnectTo:options:) and persisted into
    // UserDefaults under a `flutter.`-prefixed key, so the Dart side
    // reads them through SharedPreferences without any MethodChannel
    // registration. See SceneDelegate.swift / native_push_bridge.dart for
    // the reasoning.

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
