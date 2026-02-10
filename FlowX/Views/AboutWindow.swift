import SwiftUI
import AppKit

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.setContentSize(NSSize(width: 300, height: 380))
        window.minSize = NSSize(width: 300, height: 380)
        window.maxSize = NSSize(width: 300, height: 380)
        window.contentView = NSHostingView(rootView: AboutView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.window?.center()
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - About View

private struct AboutView: View {
    private static let repoURL = URL(string: "https://github.com/Kadxy/FlowX")!

    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }()
    private let buildNumber: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

    @State private var isChecking = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var newVersionURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }

            VStack(spacing: 4) {
                Text("FlowX")
                    .font(.system(size: 20, weight: .bold))
                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Menu bar lyrics for Apple Music")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button(String(localized: "Check for Updates")) {
                Task { await checkForUpdates() }
            }
            .controlSize(.small)
            .disabled(isChecking)

            Spacer()

            Button {
                NSWorkspace.shared.open(Self.repoURL)
            } label: {
                Text("GitHub")
                    .font(.caption)
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Text("© 2026 kadxy")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(alertTitle, isPresented: $showAlert) {
            if let url = newVersionURL {
                Button(String(localized: "Download")) {
                    NSWorkspace.shared.open(url)
                }
                Button(String(localized: "Later"), role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(alertMessage)
        }
    }

    private func checkForUpdates() async {
        isChecking = true
        newVersionURL = nil
        defer { isChecking = false }

        do {
            let apiURL = URL(string: "https://api.github.com/repos/Kadxy/FlowX/releases/latest")!
            var request = URLRequest(url: apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else {
                alertTitle = String(localized: "Check Failed")
                alertMessage = String(localized: "Unable to get version info from GitHub.")
                showAlert = true
                return
            }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            if compareVersions(latestVersion, isNewerThan: appVersion) {
                alertTitle = String(localized: "Update Available")
                alertMessage = String(localized: "A new version v\(latestVersion) is available.")
                newVersionURL = Self.repoURL.appendingPathComponent("releases/latest")
                showAlert = true
            } else {
                alertTitle = String(localized: "Up to Date")
                alertMessage = String(localized: "You're running the latest version.")
                showAlert = true
            }
        } catch {
            alertTitle = String(localized: "Check Failed")
            alertMessage = String(localized: "Unable to connect to GitHub.")
            showAlert = true
        }
    }

    /// Simple semantic version comparison (e.g. "1.2.3" > "1.2.0").
    private func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
