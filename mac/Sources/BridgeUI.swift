import SwiftUI
import AppKit

enum BridgeUI {
    static let margin: CGFloat = 20
    static let spacing: CGFloat = 12
    static let radius: CGFloat = 12
    static let contentWidth: CGFloat = 800
}

extension View {
    func bridgeCard() -> some View {
        self.padding(14).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: BridgeUI.radius))
            .overlay(RoundedRectangle(cornerRadius: BridgeUI.radius).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }
}
struct BridgeContentColumn<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeUI.spacing) { content }
                .frame(maxWidth: BridgeUI.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(BridgeUI.margin)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Use one native label with a defined top-down coordinate system and measured
/// height. SwiftUI's selectable Text host inside recycled lazy rows was the only
/// result-specific AppKit rendering path; an inverse transform would also flip
/// unaffected icons. This keeps native selection without that implicit host.
struct BridgeSelectableText: NSViewRepresentable {
    let text: String
    var secondary = false
    var semibold = false
    var lineLimit: Int = 0
    var truncatesMiddle = false
    func makeNSView(context: Context) -> BridgeUprightLabel {
        let view = BridgeUprightLabel(labelWithString: text)
        view.isEditable = false; view.isSelectable = true; view.isBordered = false
        view.drawsBackground = false; view.focusRingType = .none
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: BridgeUprightLabel, context: Context) {
        view.stringValue = text
        view.font = .systemFont(ofSize: 13, weight: semibold ? .semibold : .regular)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        view.maximumNumberOfLines = lineLimit
        view.lineBreakMode = lineLimit == 1 ? (truncatesMiddle ? .byTruncatingMiddle : .byTruncatingTail) : .byWordWrapping
        view.cell?.wraps = lineLimit != 1
        view.cell?.isScrollable = false
        view.toolTip = lineLimit > 0 ? text : nil
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BridgeUprightLabel, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 400)
        let font = nsView.font ?? .systemFont(ofSize: 13)
        let height = (text as NSString).boundingRect(with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let cap = lineLimit > 0 ? lineHeight * CGFloat(lineLimit) : CGFloat.greatestFiniteMagnitude
        return CGSize(width: width, height: ceil(max(lineHeight, min(height, cap))) + 2)
    }
}
final class BridgeUprightLabel: NSTextField {
    override var isFlipped: Bool { true }
}

/// Controls wrap rather than compressing long labels or creating empty flexible rows.
struct BridgeFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 800)
        return CGSize(width: width, height: positions(width, subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y), proposal: ProposedViewSize(width: layout.sizes[index].width, height: layout.sizes[index].height))
        }
    }
    private func positions(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], sizes: [CGSize], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var points: [CGPoint] = [], sizes: [CGSize] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing; row = max(row, size.height)
        }
        return (points, sizes, subviews.isEmpty ? 0 : y + row)
    }
}

struct BridgeFeedbackBar: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        if !model.notice.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(model.notice).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.notice = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss message").accessibilityLabel("Dismiss message")
            }.padding(.horizontal, BridgeUI.margin).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar).overlay(alignment: .top) { Divider() }
                .accessibilityElement(children: .contain)
        }
    }
}

enum NotificationActionAppearance {
    static func symbol(_ title: String) -> String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "previous", "previous track", "skip previous", "skip to previous", "previous song": return "backward.end.fill"
        case "play", "play track", "resume", "resume playback": return "play.fill"
        case "pause", "pause playback": return "pause.fill"
        case "play/pause", "play / pause", "toggle playback": return "playpause.fill"
        case "next", "next track", "skip next", "skip to next", "next song": return "forward.end.fill"
        default: return nil
        }
    }
}
struct BridgeNotificationActionButton: View {
    let action: PhoneNotificationAction
    let perform: () -> Void
    var body: some View {
        Button(action: perform) {
            if let symbol = NotificationActionAppearance.symbol(action.title) { Image(systemName: symbol).frame(minWidth: 18) }
            else { Text(action.title).lineLimit(2) }
        }.help(action.title).accessibilityLabel(action.title)
    }
}
