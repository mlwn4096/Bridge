import Foundation

enum ClipboardProtection {
    // Conservative heuristics, not a guarantee that every secret can be identified.
    static func reason(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, String)] = [
            (#"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#, "Private key"),
            (#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"#, "Possible API key"),
            (#"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|secret)\s*[:=]\s*\S+"#, "Possible credential"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "Possible authentication token"),
            (#"^\d{4,8}$"#, "Possible verification code")
        ]
        for (pattern, reason) in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil { return reason }
        }
        // Only whole clipboard values, to avoid treating numbers inside prose as cards.
        if trimmed.range(of: #"^[0-9 -]+$"#, options: .regularExpression) != nil {
            let digits = trimmed.compactMap { $0.wholeNumberValue }
            if (13...19).contains(digits.count), Set(digits).count > 1 {
                let sum = digits.reversed().enumerated().reduce(0) { sum, item in
                    let value = item.offset % 2 == 1 ? item.element * 2 : item.element
                    return sum + (value > 9 ? value - 9 : value)
                }
                if sum % 10 == 0 { return "Possible payment card" }
            }
        }
        return nil
    }
}
