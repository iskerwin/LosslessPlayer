import SwiftUI
import UIKit

/// Shared playback control. The symbol is drawn explicitly so a highlighted fill cannot hide it.
/// Collection capsules stay stateless: accent icon and label on a gray system fill, with no border.
/// Transport capsules are the Now Playing controls, and only those use the filled active state.
struct CapsuleButton: View {
    enum Chrome { case transport, collection }

    var title: String? = nil
    var systemImage: String
    var active = false
    var chrome: Chrome = .transport
    var iconPointSize: CGFloat = 17
    var expands = false
    var accessibilityLabel: String
    var action: () -> Void

    private var highlighted: Bool { chrome == .transport && active }
    private var iconColor: Color { highlighted ? .white : .orange }
    private var titleColor: Color {
        if chrome == .collection { return .orange }
        return highlighted ? .white : .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: chrome == .collection ? 8 : 6) {
                Image(systemName: systemImage)
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: iconPointSize + 8, height: iconPointSize + 8)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(chrome == .collection ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(titleColor)
                }
            }
            .frame(maxWidth: expands ? .infinity : nil, minHeight: chrome == .collection ? 48 : iconPointSize + 16)
            .padding(.horizontal, title == nil ? 12 : 10)
            .padding(.vertical, chrome == .collection ? 12 : 8)
            .background { chromeBackground }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var chromeBackground: some View {
        if chrome == .collection {
            Capsule().fill(Color(uiColor: .secondarySystemFill))
        } else {
            Capsule().fill(highlighted ? Color.orange : Color.orange.opacity(0.14))
            Capsule().strokeBorder(Color.orange.opacity(highlighted ? 0 : 0.55), lineWidth: 1)
        }
    }
}
