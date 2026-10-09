import UserNotifications

final class BridgeNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    var onHandoffResponse: ((String) -> Void)?
    var onFileResponse: ((String) -> Void)?
    var onPhoneNotificationResponse: ((String) -> Void)?
    var onPhoneNotificationOpen: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        if action == UNNotificationDefaultActionIdentifier || action == "bridge.open" {
            let metadata = response.notification.request.content.userInfo
            if category == "bridge.link", let id = metadata["handoffID"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onHandoffResponse?(id); completionHandler() }; return
            }
            if category == "bridge.file", let id = metadata["transferID"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onFileResponse?(id); completionHandler() }; return
            }
        }
        guard response.notification.request.content.categoryIdentifier == "bridge.phone",
              let key = response.notification.request.content.userInfo["phoneKey"] as? String,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == UNNotificationDismissActionIdentifier else {
            completionHandler(); return
        }
        DispatchQueue.main.async { [weak self] in
            if action == UNNotificationDefaultActionIdentifier { self?.onPhoneNotificationOpen?(key) }
            else { self?.onPhoneNotificationResponse?(key) }
            completionHandler()
        }
    }
}
