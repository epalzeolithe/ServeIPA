import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// Notifications locales du client (voir `NotificationKind`).
nonisolated final class ClientNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ClientNotifications()

    /// À appeler au lancement, pour que les notifications s'affichent aussi quand l'app est au premier plan.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ne sollicite l'utilisateur que la première fois.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ kind: NotificationKind, id: String, title: String, body: String) {
        guard kind.isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

#if os(iOS)
/// Vérification en arrière-plan des compilations attendues et des nouveautés du serveur. iOS décide du moment : la notification peut
/// arriver longtemps après la fin, ou seulement au retour dans l'app.
nonisolated enum JobRefresh {
    /// Déclaré dans Configuration/Client-Info.plist.
    static let identifier = "serveipa.jobs"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
