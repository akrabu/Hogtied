import Foundation
@preconcurrency import UserNotifications
import HogCore

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var permission: NotificationPermission = .notRequested
    private var requestFailure: String?
    var statusChanged: ((String) -> Void)?
    var openActivity: ((UUID?) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func refresh() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permission = .authorized
            requestFailure = nil
            statusChanged?("Notifications allowed")
        case .denied:
            permission = .denied
            statusChanged?("Notifications are off. Logging continues; enable Hogtied in System Settings → Notifications.")
        default:
            permission = .notRequested
            statusChanged?(requestFailure ?? "Notification permission is requested when alerts are enabled.")
        }
    }

    func requestIfNeeded() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                requestFailure = granted ? nil : "Notifications were not enabled. Logging continues; review Hogtied in System Settings → Notifications."
            } catch {
                requestFailure = "Notification permission could not be requested; logging continues. \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    func deliver(_ entry: ActivityEntry, enabled: Bool) {
        guard NotificationPolicy.shouldDeliver(alertsEnabled: enabled, permission: permission) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hogtied: \(entry.app)"
        content.body = "\(MemoryText.format(entry.bytes)) exceeds your \(MemoryText.format(entry.limitBytes ?? 1_000_000_000)) limit. Open Activity to watch this process."
        content.userInfo = ["activityID": entry.id.uuidString]
        let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)
        Task {
            do { try await center.add(request) }
            catch { statusChanged?("Notification delivery failed; the alert was logged. \(error.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["activityID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in self?.openActivity?(id) }
        completionHandler()
    }
}
