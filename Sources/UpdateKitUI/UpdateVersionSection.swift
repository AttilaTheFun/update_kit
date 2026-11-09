#if canImport(SwiftUI) && canImport(UserNotifications)
import SwiftUI
import UpdateKit

/// The app's version, for its Settings or About form: the build running,
/// and, where the app checks for updates (it names an app group), whether
/// it is the newest, with Install when a newer one is known.
public struct UpdateVersionSection: View {
    private var status = UpdateStatus.shared
    private let title: String
    @State private var installing = false

    /// `title` heads the section ("Version", "About").
    public init(title: String = "Version") {
        self.title = title
    }

    public var body: some View {
        Section {
            LabeledContent("Installed", value: status.installed.map { $0.appVersion.description } ?? "Unknown")
                .accessibilityIdentifier("update-installed")
            if let update = status.available {
                Button(installing ? "Installing…" : "Install Version \(update.latest.description)") {
                    installing = true
                    Task {
                        await AppUpdates.install(update)
                        installing = false
                    }
                }
                .disabled(installing)
                .accessibilityIdentifier("update-install")
            } else if status.lastCheck == .upToDate {
                Text("This is the newest version.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("update-up-to-date")
            }
        } header: {
            Text(title)
        }
    }
}
#endif
