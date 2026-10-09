import SwiftUI

struct BridgeAutomationView: View {
    @ObservedObject var automation: BridgeAutomation
    var body: some View {
        VStack(alignment: .leading, spacing: BridgeUI.spacing) {
            Toggle("Enable automations", isOn: Binding(get: { automation.enabled }, set: automation.setEnabled))
            Text(automation.enabled ? "Rules react to future phone events." : "Saved rules are inactive until automations are enabled.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(automation.rules) { rule in
                ruleEditor(rule)
            }
            BridgeFlowLayout {
                Button("Add rule", systemImage: "plus") { automation.addRule() }.disabled(automation.rules.count >= 8)
                Button(automation.loadingShortcuts ? "Loading…" : "Refresh Shortcuts") { automation.refreshShortcuts() }.disabled(automation.loadingShortcuts)
                Button("Allow notifications") { automation.requestNotificationPermission() }
            }
            Text(automation.status).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Automation privacy & limits") {
                Text("Shortcuts run locally without event text or file contents. A Shortcut can perform the actions you designed in Apple's Shortcuts app. Each rule runs at most once per minute; events arriving while a Shortcut runs are skipped.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }
    private func binding<T>(_ rule: BridgeAutomationRule, _ keyPath: WritableKeyPath<BridgeAutomationRule, T>) -> Binding<T> {
        Binding(get: { (automation.rules.first { $0.id == rule.id } ?? rule)[keyPath: keyPath] }, set: { value in
            var updated = automation.rules.first { $0.id == rule.id } ?? rule
            updated[keyPath: keyPath] = value; automation.update(updated)
        })
    }
    private func ruleEditor(_ rule: BridgeAutomationRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Rule enabled", isOn: binding(rule, \.enabled)).disabled(!rule.isValid)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) { automation.remove(rule.id) }.labelStyle(.iconOnly)
            }
            if !automation.enabled {
                Label("Inactive · automations off", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
            }
            Picker("When", selection: binding(rule, \.event)) {
                ForEach(BridgeAutomationEvent.allCases) { Text($0.title).tag($0) }
            }
            Picker("Then", selection: binding(rule, \.action)) {
                ForEach(BridgeAutomationAction.allCases) { Text($0.title).tag($0) }
            }
            if rule.action == .shortcut {
                Picker("Shortcut", selection: binding(rule, \.shortcutName)) {
                    Text("Choose a Shortcut").tag("")
                    if !rule.shortcutName.isEmpty && !automation.shortcutNames.contains(rule.shortcutName) {
                        Text(rule.shortcutName + " (refresh to verify)").tag(rule.shortcutName)
                    }
                    ForEach(automation.shortcutNames, id: \.self) { Text($0).tag($0) }
                }
                Text("Refresh Shortcuts, select one, then enable this rule.").font(.caption).foregroundStyle(.secondary)
            }
        }.bridgeCard()
    }
}
