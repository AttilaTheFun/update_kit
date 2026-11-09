#if canImport(SwiftUI) && canImport(UserNotifications)
import SwiftUI
import UpdateKit

/// A newer build of the app, offered in the app itself: "Version 1.2 is
/// available" and Install, while there is one (`UpdateStatus`); nothing
/// otherwise, and nothing in an app that names no app group. Put it where
/// the app has room for a line: over a list, under a toolbar.
public struct UpdateBanner: View {
    private var status = UpdateStatus.shared
    @State private var installing = false

    public init() {}

    public var body: some View {
        if let update = status.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Version \(update.latest.description) is available")
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(installing ? "Installing…" : "Install") {
                    installing = true
                    Task {
                        await AppUpdates.install(update)
                        installing = false
                    }
                }
                .disabled(installing)
                .accessibilityIdentifier("update-install")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("update-banner")
        }
    }
}
#endif
