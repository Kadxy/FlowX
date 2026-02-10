import SwiftUI
import AppKit

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "About FlowX")
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.level = .normal
        window.setContentSize(NSSize(width: 320, height: 300))
        window.minSize = NSSize(width: 320, height: 300)
        window.maxSize = NSSize(width: 320, height: 300)
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
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - About View

private struct AboutView: View {
    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }()
    private let buildNumber: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

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

            Spacer()

            Text("© 2025 kadxy. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
