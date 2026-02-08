import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowX Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 240))
        window.minSize = NSSize(width: 460, height: 240)
        window.maxSize = NSSize(width: 460, height: 240)
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
    @State private var userToken: String = AppSettings.shared.userToken
    @State private var storefront: String = AppSettings.shared.storefront
    @State private var tickerWidth: Double = AppSettings.shared.tickerWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FlowX Settings")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("User Token")
                        .frame(width: 80, alignment: .trailing)
                    SecureField("media-user-token", text: $userToken)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: userToken) { _, newValue in
                            AppSettings.shared.userToken = newValue
                        }
                }

                HStack(spacing: 12) {
                    Text("Storefront")
                        .frame(width: 80, alignment: .trailing)
                    TextField("e.g. cn, us, jp", text: $storefront)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: storefront) { _, newValue in
                            AppSettings.shared.storefront = newValue
                        }
                }

                HStack(spacing: 12) {
                    Text("Lyrics Width")
                        .frame(width: 80, alignment: .trailing)
                    Slider(value: $tickerWidth, in: 120...400, step: 10)
                        .onChange(of: tickerWidth) { _, newValue in
                            AppSettings.shared.tickerWidth = newValue
                            NotificationCenter.default.post(name: .tickerWidthChanged, object: nil)
                        }
                    Text("\(Int(tickerWidth))px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Notification.Name {
    static let tickerWidthChanged = Notification.Name("tickerWidthChanged")
}
