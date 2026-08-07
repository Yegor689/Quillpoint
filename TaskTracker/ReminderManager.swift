import Foundation
import UserNotifications
import OSLog

private let log = Logger(subsystem: "co.TaskTracker", category: "ReminderManager")

@Observable
final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
    static let markDoneActionID   = "MARK_DONE"
    static let snoozeActionID     = "SNOOZE_1H"
    static let categoryID         = "TASK_REMINDER"
    static let taskIDKey          = "taskID"

    private(set) var authorized = false

    /// Read at schedule/present time so the notification-sound preference is always current.
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategory()
        refreshAuthStatus()
    }

    // MARK: - Permission

    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                log.info("[ReminderManager] requestAuthorization error: \(error)")
            }
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .denied:
            authorized = false
            log.info("[ReminderManager] status=denied — open System Settings > Notifications > Quillpoint to re-enable")
        @unknown default:
            refreshAuthStatus()
        }
    }

    private func refreshAuthStatus() {
        _Concurrency.Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = settings.authorizationStatus
            let statusStr: String
            switch status {
            case .notDetermined: statusStr = "notDetermined"
            case .denied:        statusStr = "denied"
            case .authorized:    statusStr = "authorized"
            case .provisional:   statusStr = "provisional"
            case .ephemeral:     statusStr = "ephemeral"
            @unknown default:    statusStr = "unknown(\(status.rawValue))"
            }
            log.info("[ReminderManager] startup authorizationStatus=\(statusStr, privacy: .public)")
            await MainActor.run { authorized = status == .authorized }
        }
    }

    private func registerCategory() {
        let markDone = UNNotificationAction(
            identifier: Self.markDoneActionID,
            title: "Mark Done",
            options: [.foreground]
        )
        // Snooze reschedules the reminder later (by the user's chosen duration); no need to
        // foreground the app. The exact interval is applied when the action is handled.
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionID,
            title: "Snooze",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [markDone, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Schedule / Cancel

    func schedule(task: Task) {
        guard let date = task.reminderDate, date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = task.plainTitle.isEmpty ? "Task Reminder" : task.plainTitle
        content.body  = task.plainDesc.isEmpty  ? "" : task.plainDesc
        content.sound = settings.reminderSound ? .default : nil
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.taskIDKey: task.id.uuidString]

        // Fire at the exact chosen instant. A time-interval trigger avoids the
        // minute-truncation pitfall of UNCalendarNotificationTrigger, where a
        // reminder set within the current minute wouldn't fire until that minute recurs.
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("[ReminderManager] schedule failed: \(error.localizedDescription, privacy: .public)") }
            else { log.info("[ReminderManager] scheduled reminder for \(date, privacy: .public)") }
        }
    }

    func cancel(taskID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [taskID.uuidString])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [taskID.uuidString])
    }

    /// Re-registers every future reminder at launch so the app — not the system's pending
    /// queue — is the source of truth. Pending notifications normally persist across
    /// quits, but they can be dropped (OS resets, the 64-pending limit, a notification-DB
    /// wipe); without this a dropped reminder would silently never fire. `add` with the
    /// same identifier replaces any existing request, so re-scheduling is idempotent and
    /// safe to run every launch. Past-due reminders are pruned separately before this runs.
    func rescheduleAll(_ tasks: [Task]) {
        for task in tasks where (task.reminderDate ?? .distantPast) > Date() {
            schedule(task: task)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Bring app to front when notification is tapped
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let idStr = userInfo[Self.taskIDKey] as? String {
            switch response.actionIdentifier {
            case Self.markDoneActionID:
                NotificationCenter.default.post(name: .markTaskDone, object: idStr)
            case Self.snoozeActionID:
                NotificationCenter.default.post(name: .snoozeReminder, object: idStr)
            default:
                break
            }
        }
        completionHandler()
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The reminder has now fired; clear it so the UI doesn't keep showing a past date,
        // and surface an in-app toast carrying the task title.
        if let idStr = notification.request.content.userInfo[Self.taskIDKey] as? String {
            NotificationCenter.default.post(
                name: .reminderFired,
                object: idStr,
                userInfo: ["title": notification.request.content.title]
            )
        }
        completionHandler(settings.reminderSound ? [.banner, .sound] : [.banner])
    }
}

extension Notification.Name {
    static let markTaskDone   = Notification.Name("markTaskDone")
    static let reminderFired  = Notification.Name("reminderFired")
    static let snoozeReminder = Notification.Name("snoozeReminder")
}
