import SwiftUI
import AppKit

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private static let windowSize = NSSize(width: 530, height: 220)

    private init() {
        let window = NSWindow(
            contentRect: .zero,
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
        window.setContentSize(Self.windowSize)
        window.minSize = Self.windowSize
        window.maxSize = Self.windowSize
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        if window?.contentView == nil || !(window?.contentView is NSHostingView<AboutView>) {
            window?.contentView = NSHostingView(rootView: AboutView())
        }
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        if SettingsWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
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
        HStack(spacing: 0) {
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .padding(.leading, 40)
                    .padding(.trailing, 24)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("FlowX")
                    .font(.system(size: 32, weight: .bold))

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer()

                Text("Copyright © 2026 Kadxy. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                HStack(spacing: 12) {
                    Button(String(localized: "Check for Updates")) {
                        Task { await checkForUpdates() }
                    }
                    .disabled(isChecking)

                    Button("GitHub") {
                        NSWorkspace.shared.open(Self.repoURL)
                    }
                }
                .controlSize(.regular)
            }
            .padding(.trailing, 40)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
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
