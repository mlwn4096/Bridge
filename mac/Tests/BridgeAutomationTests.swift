import Foundation

@main
struct BridgeAutomationTests {
    @MainActor static func main() throws {
        var rule = BridgeAutomationRule()
        precondition(!rule.matches(.phoneConnected, now: 100, lastRun: nil))
        rule.enabled = true
        precondition(rule.matches(.phoneConnected, now: 100, lastRun: nil))
        precondition(!rule.matches(.fileReceived, now: 100, lastRun: nil))
        precondition(!rule.matches(.phoneConnected, now: 159, lastRun: 100))
        precondition(rule.matches(.phoneConnected, now: 160, lastRun: 100))
        precondition(!rule.matches(.phoneConnected, now: 99, lastRun: 100))
        rule.cooldownSeconds = 59; precondition(!rule.isValid)
        rule.cooldownSeconds = .nan; precondition(!rule.isValid)
        rule.cooldownSeconds = 60; rule.action = .shortcut; precondition(!rule.isValid)
        for name in ["", "--help", "name\nother", "\u{0}", String(repeating: "x", count: 513)] {
            precondition(!BridgeAutomationRule.validShortcutName(name))
        }
        rule.shortcutName = "Prepare workspace"; precondition(rule.isValid)
        let suite = "BridgeAutomationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = BridgeAutomation(defaults: defaults)
        precondition(!automation.enabled && automation.rules.isEmpty)
        for _ in 0..<10 { automation.addRule() }
        precondition(automation.rules.count == 8 && automation.rules.allSatisfy { !$0.enabled })
        var invalid = automation.rules[0]; invalid.enabled = true; invalid.action = .shortcut
        automation.update(invalid); precondition(!automation.rules[0].enabled)
        automation.setEnabled(true)
        let restored = BridgeAutomation(defaults: defaults)
        precondition(restored.enabled && restored.rules.count == 8)
        restored.remove(restored.rules[0].id); precondition(restored.rules.count == 7)
        defaults.set(Data("corrupt".utf8), forKey: "bridge.automation.rules.v1")
        let failClosed = BridgeAutomation(defaults: defaults)
        precondition(!failClosed.enabled && failClosed.rules.isEmpty)
        print("Passed automation default-off, matching, cooldown, name validation, rule cap, persistence and fail-closed checks")
    }
}
