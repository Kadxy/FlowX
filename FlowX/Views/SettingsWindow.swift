import SwiftUI
import AppKit

// MARK: - Tabs

enum SettingsTab: String, CaseIterable {
    case account, appearance, general

    var title: String {
        switch self {
        case .account: String(localized: "Account")
        case .appearance: String(localized: "Appearance")
        case .general: String(localized: "General")
        }
    }

    var icon: String {
        switch self {
        case .account: "person.crop.circle"
        case .appearance: "paintbrush"
        case .general: "gearshape"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .account: AccountSettingsView()
        case .appearance: AppearanceSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

enum SettingsMetrics {
    static let width: CGFloat = 500
}

// MARK: - Window

/// A preferences window built the way AppKit intends: panes switch through an
/// `NSToolbar` in `.preference` style, so the tab strip, highlight and keyboard
/// handling come from the system instead of being drawn by hand. The window is
/// sized to its content, so there is never dead space or a stray scroll view.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var tab: SettingsTab = .account
    /// Smallest height we allow, so a nearly-empty pane doesn't produce a sliver.
    private static let minHeight: CGFloat = 60
    /// Kept so the instructions window can be closed together with Settings.
    private var tokenHelp: TokenHelpWindowController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "FlowX.Settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        show(.account)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        show(tab)
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        tokenHelp?.close()
        window?.contentView = nil
        if AboutWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Opens the instructions for obtaining the user token, centred over Settings.
    func showTokenHelp() {
        let help = tokenHelp ?? TokenHelpWindowController()
        tokenHelp = help
        help.show(over: window)
    }

    // MARK: Pane switching

    private func show(_ tab: SettingsTab) {
        guard let window else { return }
        self.tab = tab
        window.title = tab.title

        let root = PaneHost(tab: tab) { [weak self] height in
            self?.fit(height: height)
        }
        window.contentView = NSHostingView(rootView: root)
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
    }

    /// Resize the window so it exactly contains the current pane.
    private func fit(height: CGFloat) {
        guard let window else { return }
        let target = NSSize(width: SettingsMetrics.width, height: max(Self.minHeight, height))
        guard abs(window.contentLayoutRect.height - target.height) > 0.5 else { return }
        window.setContentSize(target)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Marking the items selectable is what makes them preference tabs: full-size icons with
    /// the system's selection highlight, rather than ordinary toolbar buttons.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        show(tab)
    }
}

/// Hosts a pane and reports its natural height, so the window can hug the content.
private struct PaneHost: View {
    let tab: SettingsTab
    let onHeight: (CGFloat) -> Void

    var body: some View {
        tab.content
            .frame(width: SettingsMetrics.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(HeightKey.self) { height in
                onHeight(height)
            }
    }

    private struct HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

// MARK: - Token editor

/// Monospaced, character-wrapping editor for the long opaque user token.
struct CharWrapTextView: NSViewRepresentable {
    @Binding var text: String

    /// Distance from the top of the view to the baseline of its first line of text.
    static let firstBaselineOffset: CGFloat = 17

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

        // The token has no spaces, so break it at any character; the container's own line
        // break mode only governs truncation, wrapping follows the paragraph style.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
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

// MARK: - Layout

/// Shared pane container, laid out like the settings of Apple's own apps (Music, Safari):
/// labels right-aligned in a leading column, controls in a trailing one, straight on the
/// window background. A grid rather than a `Form`, so separators can span both columns.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
            content()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }
}

/// One row of a pane: an optional label in the leading column and a control in the trailing one.
private struct SettingsRow<Content: View>: View {
    private let label: LocalizedStringKey?
    private let content: Content

    init(_ label: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        GridRow {
            Group {
                if let label {
                    ColumnLabel(label)
                } else {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .gridColumnAlignment(.trailing)

            content
        }
    }
}

/// Separator between groups of rows, spanning both columns without widening the grid.
private struct PaneDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 6)
            .gridCellUnsizedAxes(.horizontal)
    }
}

/// A leading-column label, written the way macOS settings write them: with a trailing colon.
private struct ColumnLabel: View {
    /// Chinese and Japanese take the full-width colon.
    private static let colon: String = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return language.hasPrefix("zh") || language.hasPrefix("ja") ? "：" : ":"
    }()

    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
            Text(verbatim: Self.colon)
        }
    }
}

// MARK: - Shared data

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

// MARK: - Account pane

struct AccountSettingsView: View {
    /// Fits a typical token without scrolling.
    private static let tokenEditorSize = CGSize(width: 300, height: 92)
    /// Shown in place of account details that are not known yet.
    private static let placeholder = "—"

    @ObservedObject private var settings = AppSettings.shared
    @State private var status: CheckStatus = .idle
    /// Details from the last successful check. They stay while a new check runs and the rows
    /// showing them are always present, so the pane never changes height under the pointer.
    @State private var account: AccountInfo?
    @State private var autoCheckTask: Task<Void, Never>?

    init(previewResult: AccountInfo? = nil) {
        if let previewResult {
            _status = State(initialValue: .done(.valid(previewResult)))
            _account = State(initialValue: previewResult)
        }
    }

    private enum CheckStatus: Equatable {
        case idle
        case checking
        case done(UserTokenStatus)
    }

    var body: some View {
        SettingsPane {
            SettingsRow("User Token") {
                VStack(alignment: .leading, spacing: 10) {
                    CharWrapTextView(text: $settings.userToken)
                        .frame(width: Self.tokenEditorSize.width, height: Self.tokenEditorSize.height)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        // Line the row's label up with the editor's first line of text.
                        .alignmentGuide(.firstTextBaseline) { _ in CharWrapTextView.firstBaselineOffset }

                    HStack(spacing: 10) {
                        Button("Check") { Task { await runCheck() } }
                            .disabled(status == .checking || trimmedToken.isEmpty)
                        statusIndicator
                    }

                    Button("How to Get Your User Token") {
                        SettingsWindowController.shared.showTokenHelp()
                    }
                    .buttonStyle(.link)
                }
            }

            PaneDivider()

            SettingsRow("Region") {
                Text(verbatim: account?.regionName ?? Self.placeholder)
            }
            SettingsRow("Content Language") {
                Text(verbatim: account.map { languageName($0.languageTag) } ?? Self.placeholder)
            }
        }
        .onChange(of: settings.userToken) { _, newValue in
            // Re-check automatically (debounced) so the account details appear as
            // soon as a token is pasted, without hunting for the Check button.
            if case .done = status { status = .idle }
            autoCheckTask?.cancel()
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                account = nil
                return
            }
            autoCheckTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await runCheck()
            }
        }
        .task {
            // Validate a token restored from disk on first appearance.
            if status == .idle, !trimmedToken.isEmpty { await runCheck() }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .done(let result):
            switch result {
            case .valid:
                statusLabel("Valid", icon: "checkmark.circle.fill", tint: .green)
            case .invalid:
                statusLabel("Invalid or expired", icon: "xmark.circle.fill", tint: .red)
            case .developerTokenUnavailable:
                statusLabel("Could not sign in to Apple Music", icon: "exclamationmark.triangle.fill", tint: .orange)
            case .failed:
                statusLabel("Could not reach Apple Music", icon: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    /// Only the symbol carries the colour; the text stays in the row's own style.
    private func statusLabel(_ title: LocalizedStringKey, icon: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .lineLimit(1)
    }

    private var trimmedToken: String {
        settings.userToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func languageName(_ tag: String) -> String {
        let locale = Locale(identifier: tag)
        guard let name = locale.localizedString(forIdentifier: tag) else { return tag }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func runCheck() async {
        status = .checking
        let result = await TokenValidator.validate(
            userToken: settings.userToken,
            developerToken: settings.developerToken
        )
        switch result {
        case .valid(let info):
            account = info
            // Apple tells us which storefront the account lives in — adopt it so the
            // region never has to be chosen by hand.
            if !info.regionCode.isEmpty { settings.storefront = info.regionCode }
        case .invalid:
            account = nil
        case .developerTokenUnavailable, .failed:
            // The token itself was not judged, so what is already known still stands.
            break
        }
        status = .done(result)
    }
}

// MARK: - Token help

/// Instructions for obtaining the user token, in a window of their own: they are followed in
/// a browser, so they have to stay visible without blocking or resizing Settings.
final class TokenHelpWindowController: NSWindowController {
    init() {
        let content = NSHostingView(rootView: TokenHelpView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "How to Get Your User Token")
        window.contentView = content
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings the window forward. On first appearance it is centred over `parent`; after that
    /// it stays wherever the user has put it.
    func show(over parent: NSWindow?) {
        guard let window else { return }
        if !window.isVisible {
            if let frame = parent?.frame {
                window.setFrameOrigin(NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                ))
            } else {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

struct TokenHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open music.apple.com in a browser and sign in with your Apple ID.")
                step(2, "Open the developer console (Option-Command-I in Safari, or F12 in Chrome).")
                step(3, "Paste the snippet below into the Console and press Return — it copies the token to your clipboard.")
                step(4, "Return here and paste it into the field above.")
            }

            ConsoleSnippetView()
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Console snippet

/// The one-liner users run in the browser console. Reads the `media-user-token`
/// cookie (the same value the web player reads) and copies it to the clipboard.
private struct ConsoleSnippetView: View {
    private static let snippet = #"""
    const raw = document.cookie
      .match(/(?:^|; )media-user-token=([^;]+)/)?.[1];
    const token = raw && decodeURIComponent(raw);
    token
      ? (copy(token), console.log('media-user-token copied:', token))
      : console.warn('Sign in to music.apple.com first');
    """#

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console Snippet")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copySnippet() }
            }

            Text(Self.snippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.snippet, forType: .string)
    }
}

// MARK: - Appearance pane

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsPane {
            SettingsRow {
                Toggle("Show in Menu Bar", isOn: $settings.showMenuBarLyrics)
            }
            SettingsRow {
                Toggle("Karaoke Effect", isOn: $settings.menuBarKaraoke)
            }

            PaneDivider()

            PointSlider(label: "Lyrics Width", value: $settings.menuBarLyricsWidth, range: 120...320, step: 10)
            PointSlider(label: "Edge Fade", value: $settings.menuBarEdgeFadeWidth, range: 0...60, step: 6)
        }
    }
}

/// A slider row that shows its current value, in points, beside the slider.
private struct PointSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        SettingsRow(label) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 200)
                Text(verbatim: "\(Int(value)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
        }
    }
}

// MARK: - General pane

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showRestartAlert = false

    var body: some View {
        SettingsPane {
            SettingsRow("Language") {
                Picker("Language", selection: $settings.language) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.language) { _, _ in
                    showRestartAlert = true
                }
            }
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
