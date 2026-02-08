import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowX Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 140))
        window.minSize = NSSize(width: 400, height: 140)
        window.maxSize = NSSize(width: 400, height: 140)
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage("tickerWidth") private var tickerWidth: Double = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FlowX Settings")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                Text("Lyrics Width")
                Slider(value: $tickerWidth, in: 120...400, step: 10)
                    .onChange(of: tickerWidth) { _, _ in
                        NotificationCenter.default.post(name: .tickerWidthChanged, object: nil)
                    }
                Text("\(Int(tickerWidth))px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Notification.Name {
    static let tickerWidthChanged = Notification.Name("tickerWidthChanged")
}
