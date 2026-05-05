import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// Notification Service Extension that lets iOS render rich (image-attached)
/// pushes even when the host app is backgrounded or killed.
///
/// Without this extension iOS ignores `notification.image` (or
/// `apns.fcm_options.image`) for our FCM payloads — picture only appears when
/// the Dart isolate is alive and our `_onForeground` handler builds a local
/// notification. By calling `Messaging.serviceExtension().populateNotificationContent`
/// we hand decoding off to FirebaseMessaging, which downloads the image and
/// attaches it to the system-displayed notification automatically.
///
/// IMPORTANT: APS payload sent from the backend MUST contain
/// `"mutable-content": 1` — otherwise iOS will not invoke this extension and
/// the picture stays invisible in background mode.
class NotificationService: UNNotificationServiceExtension {
  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent =
      request.content.mutableCopy() as? UNMutableNotificationContent

    guard let bestAttemptContent = bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    #if canImport(FirebaseMessaging)
    Messaging.serviceExtension().populateNotificationContent(
      bestAttemptContent,
      withContentHandler: contentHandler
    )
    #else
    contentHandler(bestAttemptContent)
    #endif
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler = contentHandler,
       let bestAttemptContent = bestAttemptContent {
      contentHandler(bestAttemptContent)
    }
  }
}
