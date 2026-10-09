import Foundation

enum NotificationReplyPolicy {
    static let maxBytes = 4096
    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0") && text.utf8.count <= maxBytes
    }
}
struct NotificationReplyOutcome {
    // nil means delivery outcome is unknown, never an instruction to retry.
    let accepted: Bool?
    let message: String
}
