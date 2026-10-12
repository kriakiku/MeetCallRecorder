import SwiftUI

/// One permission's card: icon, name, what it's for, and either its status
/// or the button that asks for it.
///
/// Shared by the welcome screen and the settings window - the two places
/// that show this list are the same list, and the second one was a
/// copy-paste waiting to drift out of step with the first.
struct PermissionRow: View {
    let permission: Permission
    let coordinator: PermissionCoordinator

    private var isGranted: Bool { coordinator.isGranted(permission) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isGranted ? Color.green.opacity(0.16) : Color.accentColor.opacity(0.14))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: permission.symbolName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isGranted ? Color.green : Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(permission.isRequired ? "Required" : "Optional")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Text(permission.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            status
        }
        .padding(14)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isGranted ? Color.green.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var status: some View {
        if coordinator.needsRestart(permission) {
            Label("Restart", systemImage: "arrow.clockwise.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        } else if isGranted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button("Allow…") { permission.request() }
                .controlSize(.regular)
        }
    }
}
