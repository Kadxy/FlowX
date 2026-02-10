import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let windowSize = NSSize(width: 520, height: 720)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "FlowX Settings")
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.minSize = Self.windowSize
        window.maxSize = Self.windowSize
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        if window?.contentView == nil || !(window?.contentView is NSHostingView<SettingsView>) {
            window?.contentView = NSHostingView(rootView: SettingsView())
        }
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        if AboutWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
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

// MARK: - Section Header

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

// MARK: - Settings View

/// Source: https://github.com/jcoester/iTunes-country-codes  (fetched 2026-02-10)
private let storefronts: [(code: String, name: String)] = {
    guard let url = Bundle.main.url(forResource: "itunes_country_codes", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [("cn", "CN - China"), ("us", "US - United States"), ("jp", "JP - Japan")] }
    return dict.map { (code: $0.key.lowercased(), name: "\($0.key) - \($0.value)") }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}()
private let languages: [(code: String, label: String)] = {
    var list = Bundle.main.localizations
        .filter { $0 != "Base" }
        .map { code -> (code: String, label: String) in
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code) ?? code
            return (code, name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    list.insert(("system", String(localized: "System")), at: 0)
    return list
}()

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showRestartAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            // MARK: Apple Music API
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Apple Music API", icon: "key")

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("User Token")
                            .font(.system(.body, weight: .medium))
                        CharWrapTextView(text: $settings.userToken)
                            .frame(height: 80)
                            .background(
                                Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    SettingsRow("Storefront") {
                        Picker("", selection: $settings.storefront) {
                            ForEach(storefronts, id: \.code) { sf in
                                Text(sf.name).tag(sf.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                    }
                    .padding(16)
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            // MARK: Menu Bar Lyrics
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Menu Bar Lyrics", icon: "menubar.rectangle")

                VStack(spacing: 0) {
                    SettingsRow("Lyrics Width") {
                        HStack(spacing: 10) {
                            Slider(value: $settings.menuBarLyricsWidth, in: 120...320, step: 10)
                                .frame(width: 120)
                            Text("\(Int(settings.menuBarLyricsWidth)) pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    SettingsRow("Edge Fade") {
                        HStack(spacing: 10) {
                            Slider(value: $settings.menuBarEdgeFadeWidth, in: 0...60, step: 6)
                                .frame(width: 120)
                            Text("\(Int(settings.menuBarEdgeFadeWidth)) pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    SettingsRow("Karaoke Effect") {
                        Toggle("", isOn: $settings.menuBarKaraoke)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(16)

                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            // MARK: General
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "General", icon: "gearshape")

                VStack(spacing: 0) {
                    SettingsRow("Language") {
                        Picker("", selection: $settings.language) {
                            ForEach(languages, id: \.code) { lang in
                                Text(lang.label).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .onChange(of: settings.language) { _, _ in
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
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                restartApp()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "Language changed. Restart FlowX to apply."))
        }
    }

    private func restartApp() {
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        NSApp.terminate(nil)
    }
}
