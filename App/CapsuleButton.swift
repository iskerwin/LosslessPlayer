import SwiftUI

/// Shared playback control. The symbol is drawn explicitly so a highlighted fill cannot hide it.
struct CapsuleButton: View {
    var title: String? = nil
    var systemImage: String
    var active = false
    var iconPointSize: CGFloat = 17
    var expands = false
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: iconPointSize + 8, height: iconPointSize + 8)
                    .foregroundStyle(active ? Color.white : Color.orange)
                    .accessibilityHidden(true)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(active ? Color.white : Color.primary)
                }
            }
            .frame(maxWidth: expands ? .infinity : nil, minHeight: iconPointSize + 16)
            .padding(.horizontal, title == nil ? 12 : 8)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(active ? Color.orange : Color.orange.opacity(0.14))
                Capsule().strokeBorder(Color.orange.opacity(active ? 0 : 0.55), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
