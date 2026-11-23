import AppKit
import SwiftData
import SwiftUI

public extension Notification.Name {
    static let snipBarDidSummonPopover = Notification.Name("dev.snipbar.didSummonPopover")
    static let snipBarPopoverToggleTab = Notification.Name("dev.snipbar.popoverToggleTab")
    static let snipBarPopoverOpenNewSnippet = Notification.Name("dev.snipbar.popoverOpenNewSnippet")
}

/// Shared `@MainActor` bridge between `FloatingPopoverPanel` (AppKit `sendEvent`)
/// and `PopoverContentView` (SwiftUI) so `Tab` switches Snippets ↔ Clipboard cleanly
/// in browse mode while still letting `Tab` move between inputs in the New Snippet form.
@MainActor
public final class PopoverInteractionBridge: ObservableObject {
    public var isEditingInlineForm: Bool = false
    public init() {}
}

/// Custom non-activating `NSPanel` for SnipBar's menu bar popover.
/// WHY NOT SWIFTUI `MenuBarExtra(.window)`:
/// 1. `MenuBarExtra` activates the app before we can inspect `NSWorkspace.shared.frontmostApplication`,
///    making reliable Auto-Paste into the previously active app impossible.
/// 2. `.nonactivatingPanel` + `.fullScreenAuxiliary` allows summoning SnipBar directly on top of
///    full-screen Xcode, Terminal, or Keynote spaces without yanking macOS to another Desktop Space!
/// 3. Overriding `canBecomeKey = true` lets the search `TextField` receive instant keyboard focus
///    while keeping the target app visually active underneath.
/// 4. Overriding `sendEvent(_:)` intercepts `Tab` (Snippets ↔ Clipboard), `⌘N` (New Snippet),
///    and `⌘L` / `⌘,` (Open Library) BEFORE `NSTextField` steals `Tab` or beeps on unhandled shortcuts.
public final class FloatingPopoverPanel: NSPanel {
    public var onResignKey: (@MainActor () -> Void)?
    public var shouldInterceptTab: (@MainActor () -> Bool)?
    public var onTabPressed: (@MainActor () -> Void)?
    public var onNewSnippetShortcut: (@MainActor () -> Void)?
    public var onOpenLibraryShortcut: (@MainActor () -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    override public func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Tab (keyCode 48): switch between Snippets and Clipboard in browse mode
            if event.keyCode == 48,
               flags.isDisjoint(with: [.command, .control, .option]),
               shouldInterceptTab?() == true {
                onTabPressed?()
                return
            }

            // Command-only shortcuts: ⌘N (New Snippet), ⌘L or ⌘, (Open Library)
            if flags == .command,
               let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "n" {
                    onNewSnippetShortcut?()
                    return
                }
                if key == "l" || key == "," {
                    onOpenLibraryShortcut?()
                    return
                }
            }
        }

        super.sendEvent(event)
    }

    override public func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override public func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }
}

@MainActor
public final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: FloatingPopoverPanel
    private let interactionBridge = PopoverInteractionBridge()
    private let onOpenLibraryWindow: () -> Void
    private let onOpenClipboardBezel: () -> Void

    public private(set) var previousFrontmostApp: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var iconResetTask: Task<Void, Never>?

    public init(
        modelContainer: ModelContainer,
        onOpenLibraryWindow: @escaping () -> Void,
        onOpenClipboardBezel: @escaping () -> Void = {}
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = FloatingPopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 444, height: 486))
        self.onOpenLibraryWindow = onOpenLibraryWindow
        self.onOpenClipboardBezel = onOpenClipboardBezel
        super.init()

        configureStatusButton()
        configurePanelContent(modelContainer: modelContainer)

        panel.onResignKey = { [weak self] in
            guard !BiometricAuthService.shared.isPresentingPrompt else { return }
            self?.closePopover()
        }

        panel.shouldInterceptTab = { [weak self] in
            guard let self else { return false }
            return !self.interactionBridge.isEditingInlineForm
        }

        panel.onTabPressed = {
            NotificationCenter.default.post(name: .snipBarPopoverToggleTab, object: nil)
        }

        panel.onNewSnippetShortcut = {
            NotificationCenter.default.post(name: .snipBarPopoverOpenNewSnippet, object: nil)
        }

        panel.onOpenLibraryShortcut = { [weak self] in
            self?.closePopover()
            self?.onOpenLibraryWindow()
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeSnipBarStatusIcon()
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Crisp 18x18pt monochrome template icon matching the SnipBar diagonal interlocking-S logo.
    /// Marking `isTemplate = true` makes macOS automatically adapt it to Light/Dark menu bars.
    private static func makeSnipBarStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setFill()

            // Outer rounded-diamond S silhouette formed by two offset precision snippet tiles
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            transform.rotate(byDegrees: 45)
            transform.concat()

            // Top-left tile
            let upperTile = NSBezierPath(
                roundedRect: NSRect(x: -5.6, y: 0.7, width: 8.6, height: 4.9),
                xRadius: 2.2,
                yRadius: 2.2
            )
            upperTile.fill()

            // Bottom-right tile
            let lowerTile = NSBezierPath(
                roundedRect: NSRect(x: -3.0, y: -5.6, width: 8.6, height: 4.9),
                xRadius: 2.2,
                yRadius: 2.2
            )
            lowerTile.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SnipBar"
        return image
    }

    private func configurePanelContent(modelContainer: ModelContainer) {
        let rootView = PopoverContentView(
            interactionBridge: interactionBridge,
            onCopyCompleted: { [weak self] snippetTitle, shouldAutoPaste in
                guard let self else { return }
                self.flashCheckmarkInMenuBar()
                let targetApp = self.previousFrontmostApp
                self.closePopover()
                if shouldAutoPaste {
                    Task { @MainActor in
                        _ = await AutoPasteService.shared.pasteInto(previousApp: targetApp)
                    }
                }
                _ = snippetTitle
            },
            onDirectPasteClipboard: { [weak self] entry in
                guard let self else { return }
                let targetApp = self.previousFrontmostApp
                ClipboardService.shared.copy(
                    entry.content,
                    isSecret: false,
                    isTransient: true,
                    autoClearAfterSeconds: nil,
                    skipHistoryCapture: true
                )
                ClipboardHistoryStore.shared.promoteToTop(id: entry.id)
                self.flashCheckmarkInMenuBar()
                self.closePopover()
                Task { @MainActor in
                    _ = await AutoPasteService.shared.pasteInto(previousApp: targetApp)
                }
            },
            onOpenClipboardBezel: { [weak self] in
                self?.closePopover()
                self?.onOpenClipboardBezel()
            },
            onOpenLibrary: { [weak self] in
                self?.closePopover()
                self?.onOpenLibraryWindow()
            },
            onClosePopover: { [weak self] in
                self?.closePopover()
            }
        )
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let visualEffect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        panel.contentView = visualEffect
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let clipboardBezelItem = NSMenuItem(
                title: "Clipboard History (⌘⇧V)…",
                action: #selector(openClipboardBezelFromMenu),
                keyEquivalent: ""
            )
            clipboardBezelItem.target = self
            menu.addItem(clipboardBezelItem)

            let libraryItem = NSMenuItem(
                title: "Open SnipBar Library…",
                action: #selector(openLibraryFromMenu),
                keyEquivalent: "l"
            )
            libraryItem.target = self
            menu.addItem(libraryItem)

            let aboutItem = NSMenuItem(
                title: "About SnipBar",
                action: #selector(openAboutPanel),
                keyEquivalent: ""
            )
            aboutItem.target = self
            menu.addItem(aboutItem)

            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit SnipBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func openClipboardBezelFromMenu() {
        closePopover()
        onOpenClipboardBezel()
    }

    @objc private func openLibraryFromMenu() {
        onOpenLibraryWindow()
    }

    @objc private func openAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    public func togglePopover() {
        if panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        // Capture whichever external app currently owns focus BEFORE showing our panel
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }

        positionPanelBeneathStatusItem()
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .snipBarDidSummonPopover, object: nil)

        if let existingMonitor = outsideClickMonitor {
            NSEvent.removeMonitor(existingMonitor)
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard !BiometricAuthService.shared.isPresentingPrompt else { return }
                self?.closePopover()
            }
        }
    }

    public func closePopover() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        interactionBridge.isEditingInlineForm = false
        panel.orderOut(nil)
    }

    /// Multi-display & notch-safe positioning anchored beneath `NSStatusBarButton`.
    private func positionPanelBeneathStatusItem() {
        let panelSize = panel.frame.size
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let origin = NSPoint(
                    x: visible.midX - panelSize.width / 2,
                    y: visible.maxY - panelSize.height - 12
                )
                panel.setFrameOrigin(origin)
            }
            return
        }

        let buttonRectInScreen = buttonWindow.convertToScreen(button.frame)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = round(buttonRectInScreen.midX - panelSize.width / 2)
        // Clamp horizontally within 8pt margin of the active monitor's visible frame
        x = max(visibleFrame.minX + 8, min(x, visibleFrame.maxX - panelSize.width - 8))
        let y = buttonRectInScreen.minY - panelSize.height - 6

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Micro-feedback: briefly swaps menu bar icon to a checkmark so user knows copy succeeded.
    public func flashCheckmarkInMenuBar() {
        iconResetTask?.cancel()
        statusItem.button?.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Copied"
        )
        statusItem.button?.image?.isTemplate = true

        iconResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.statusItem.button?.image = Self.makeSnipBarStatusIcon()
        }
    }
}
