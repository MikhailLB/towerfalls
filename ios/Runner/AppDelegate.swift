import FirebaseMessaging
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// MethodChannel name used by `lib/gray/services/native_push_bridge.dart`
  /// to consume cold-start push URLs that SceneDelegate captured before any
  /// Dart code was running.
  static let nativePushChannelName = "tower_falls/gray/native_push"

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

    // Wire up the native-push MethodChannel BEFORE returning so that Dart's
    // RuntimeCache.bootstrap() can call `consumeColdStartUrl()` on the very
    // first frame and reliably pick up any URL captured by SceneDelegate.
    if let controller = window?.rootViewController as? FlutterViewController {
      registerNativePushChannel(messenger: controller.binaryMessenger)
    } else {
      // Scene-based apps: the rootViewController is not yet attached at this
      // point; register the channel as soon as the first scene connects.
      // We hook into UIScene.didActivateNotification so we don't have to
      // subclass FlutterSceneDelegate further.
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onSceneDidActivate(_:)),
        name: UIScene.didActivateNotification,
        object: nil
      )
    }

    // FirebaseAppDelegateProxyEnabled=YES in Info.plist means Firebase
    // Messaging swizzles AppDelegate methods automatically (APNs token
    // forwarding, didReceiveRemoteNotification, etc.).  No manual calls to
    // FirebaseApp.configure(), registerForRemoteNotifications(), or
    // Messaging.messaging().apnsToken are needed.

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func onSceneDidActivate(_ notification: Notification) {
    guard
      let scene = notification.object as? UIWindowScene,
      let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
      let controller = window.rootViewController as? FlutterViewController
    else {
      return
    }
    registerNativePushChannel(messenger: controller.binaryMessenger)
    NotificationCenter.default.removeObserver(
      self,
      name: UIScene.didActivateNotification,
      object: nil
    )
  }

  private var nativePushChannel: FlutterMethodChannel?

  private func registerNativePushChannel(messenger: FlutterBinaryMessenger) {
    if nativePushChannel != nil { return }
    let channel = FlutterMethodChannel(
      name: AppDelegate.nativePushChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "consumeColdStartUrl":
        let defaults = UserDefaults.standard
        let key = SceneDelegate.coldStartUrlKey
        let value = defaults.string(forKey: key)
        if value != nil {
          defaults.removeObject(forKey: key)
          defaults.synchronize()
        }
        NSLog("[TF.NATIVE] consumeColdStartUrl -> \(value ?? "nil")")
        result(value)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativePushChannel = channel
  }
}
