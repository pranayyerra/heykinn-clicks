import Foundation
import UserNotifications

/// The one kind of notification the app posts: a silent summary after a large
/// piece of background work, so somebody who was not watching learns it
/// happened without being told about every photo.
enum QuietNotifier {
    static func post(title: String, body: String) {
        // The notification centre asserts it is running inside an app bundle.
        // `swift run` and the test runner are not, and crashing there to say
        // "done" would be a poor trade.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
        }
    }
}
