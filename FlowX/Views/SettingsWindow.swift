import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "FlowX Settings")
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.level = .normal
        window.setContentSize(NSSize(width: 520, height: 480))
        window.minSize = NSSize(width: 520, height: 480)
        window.maxSize = NSSize(width: 520, height: 480)
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.window?.center()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Activate Finder so the desktop keeps focus instead of
        // switching back to the previous fullscreen app.
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate()
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Char-wrap NSTextView

struct CharWrapTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView

        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = context.coordinator
        textView.drawsBackground = false

        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CharWrapTextView
        init(_ parent: CharWrapTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Card Style

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }
}

// MARK: - Row

private struct SettingsRow<Content: View>: View {
    let label: LocalizedStringKey
    let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            content()
        }
    }
}

// MARK: - Settings View

private let storefronts = ["cn", "us", "jp"]
private let languages: [(code: String, label: String)] = {
    var list = Bundle.main.localizations
        .filter { $0 != "Base" }
        .map { code -> (code: String, label: String) in
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code) ?? code
            return (code, name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    list.insert(("system", "System"), at: 0)
    return list
}()

struct SettingsView: View {
    @State private var userToken: String = AppSettings.shared.userToken
    @State private var storefront: String = AppSettings.shared.storefront
    @State private var menuBarLyricsWidth: Double = AppSettings.shared.menuBarLyricsWidth
    @State private var language: String = AppSettings.shared.language
    @State private var showRestartAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Apple Music API
                VStack(alignment: .leading, spacing: 10) {
                    Label("Apple Music API", systemImage: "apple.logo")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    VStack(spacing: 0) {
                        // User Token
                        VStack(alignment: .leading, spacing: 8) {
                            Text("User Token")
                                .font(.system(.body, weight: .medium))
                            CharWrapTextView(text: $userToken)
                                .frame(height: 80)
                                .background(
                                    Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                                .onChange(of: userToken) { _, val in
                                    AppSettings.shared.userToken = val
                                }
                        }
                        .padding(16)

                        Divider().padding(.horizontal, 16)

                        // Storefront
                        SettingsRow("Storefront") {
                            Picker("", selection: $storefront) {
                                ForEach(storefronts, id: \.self) { code in
                                    Text(code.uppercased()).tag(code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            .onChange(of: storefront) { _, val in
                                AppSettings.shared.storefront = val
                            }
                        }
                        .padding(16)
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                // MARK: Appearance
                VStack(alignment: .leading, spacing: 10) {
                    Label("Appearance", systemImage: "paintbrush")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    VStack(spacing: 0) {
                        SettingsRow("MenuBar Lyrics Width") {
                            HStack(spacing: 10) {
                                Slider(value: $menuBarLyricsWidth, in: 120...320, step: 10)
                                    .frame(width: 150)
                                    .onChange(of: menuBarLyricsWidth) { _, val in
                                        AppSettings.shared.menuBarLyricsWidth = val
                                        NotificationCenter.default.post(name: .menuBarLyricsWidthChanged, object: nil)
                                    }
                                Text("\(Int(menuBarLyricsWidth)) pt")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }
                        .padding(16)

                        Divider().padding(.horizontal, 16)

                        SettingsRow("Language") {
                            Picker("", selection: $language) {
                                ForEach(languages, id: \.code) { lang in
                                    Text(lang.label).tag(lang.code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .onChange(of: language) { _, val in
                                AppSettings.shared.language = val
                                showRestartAlert = true
                            }
                        }
                        .padding(16)
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()
            }
            .padding(24)
        }
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Restart Now") {
                restartApp()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Language changed. Restart FlowX to apply.")
        }
    }

    private func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let menuBarLyricsWidthChanged = Notification.Name("menuBarLyricsWidthChanged")
}
