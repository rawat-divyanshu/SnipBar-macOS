import AppKit
import SwiftData
import SwiftUI

@main
struct SnipBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Using `Settings` keeps SnipBar strictly in the menu bar at launch without
        // automatically popping open an unwanted main window, while preserving responder commands.
        Settings {
            LibrarySplitView()
                .modelContainer(appDelegate.modelContainer)
        }
        .commands {
            TextEditingCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer
    private var statusBarController: StatusBarController?
    private var clipboardBezelController: ClipboardBezelController?
    private var libraryWindowController: NSWindowController?
    private var hotkeyObserver: NSObjectProtocol?

    override init() {
        self.modelContainer = Self.makeHardenedModelContainer()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep app out of Dock & Cmd+Tab by default (`LSUIElement` behavior)
        NSApp.setActivationPolicy(.accessory)
        installStandardEditMenu()

        seedInitialDataIfEmpty()

        // Start background clipboard history capture (up to 50 entries)
        ClipboardHistoryStore.shared.startMonitoring()

        statusBarController = StatusBarController(
            modelContainer: modelContainer,
            onOpenLibraryWindow: { [weak self] in
                self?.openDetachedLibraryWindow()
            },
            onOpenClipboardBezel: { [weak self] in
                self?.clipboardBezelController?.handleHotkeyTrigger(fromHotkey: false)
            }
        )

        clipboardBezelController = ClipboardBezelController(
            modelContainer: modelContainer,
            onPastedFeedback: { [weak self] in
                self?.statusBarController?.flashCheckmarkInMenuBar()
            }
        )

        let savedChoice = UserDefaults.standard.string(forKey: "snipbar.hotkeyChoice") ?? "cmd+shift+space"
        let initialCombo: HotkeyCombo = (savedChoice == "option+s") ? .optionS : .cmdShiftSpace

        GlobalHotkeyManager.shared.register(combo: initialCombo) { [weak self] in
            self?.statusBarController?.togglePopover()
        }

        // Dedicated clipboard cycling & direct paste shortcut (⌘⇧V)
        GlobalHotkeyManager.shared.registerClipboardHotKey(combo: .cmdShiftV) { [weak self] in
            guard ClipboardHistoryStore.shared.isEnabled else { return }
            self?.statusBarController?.closePopover()
            self?.clipboardBezelController?.handleHotkeyTrigger(fromHotkey: true)
        }

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .snipBarDidUpdateHotkey,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let combo = note.object as? HotkeyCombo else { return }
            Task { @MainActor in
                GlobalHotkeyManager.shared.register(combo: combo) {
                    self?.statusBarController?.togglePopover()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
            self.hotkeyObserver = nil
        }
        ClipboardHistoryStore.shared.stopMonitoring()
        GlobalHotkeyManager.shared.unregister()
    }

    /// Ensures standard macOS Edit responder shortcuts (`Cmd+C`, `Cmd+V`, `Cmd+X`, `Cmd+A`, `Cmd+Z`)
    /// function reliably in `LSUIElement` menu bar panels and detached SwiftUI windows.
    private func installStandardEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Opens the spacious Library manager window and brings it cleanly to the foreground.
    private func openDetachedLibraryWindow() {
        if let existing = libraryWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = LibrarySplitView()
            .modelContainer(modelContainer)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnipBar Library"
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        self.libraryWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    /// Creates a SwiftData SQLite store inside `~/Library/Application Support/SnipBar/`
    /// restricted to owner-only `0700` POSIX permissions so other local accounts or
    /// unprivileged processes cannot read snippet metadata.
    private static func makeHardenedModelContainer() -> ModelContainer {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dirURL = appSupport.appendingPathComponent("SnipBar", isDirectory: true)

        try? fileManager.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)

        let storeURL = dirURL.appendingPathComponent("SnipBarStore.sqlite")
        let schema = Schema([SnippetRecord.self, TagRecord.self])
        let config = ModelConfiguration(schema: schema, url: storeURL, allowsSave: true)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize SnipBar SwiftData container: \(error)")
        }
    }

    private func seedInitialDataIfEmpty() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SnippetRecord>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        let sqlTag = TagRecord(name: "sql", color: .blue)
        let gitTag = TagRecord(name: "git", color: .amber)
        let devopsTag = TagRecord(name: "devops", color: .rose)

        context.insert(sqlTag)
        context.insert(gitTag)
        context.insert(devopsTag)

        let s1 = SnippetRecord(
            title: "PostgreSQL Active Queries",
            content: "SELECT pid, now() - query_start AS duration, state, query FROM pg_stat_activity WHERE state <> 'idle' ORDER BY duration DESC;",
            tags: [sqlTag, devopsTag],
            isPinned: true
        )
        let s2 = SnippetRecord(
            title: "Git Prune Merged Branches",
            content: "git fetch -p && git branch --merged main | grep -vE '^(main|\\*)' | xargs -r git branch -d",
            tags: [gitTag],
            isPinned: true
        )
        let s3 = SnippetRecord(
            title: "Markdown Link from Clipboard",
            content: "[Reference ({{date}})]({{clipboard}})",
            tags: [devopsTag],
            isPinned: false
        )
        let s4 = SnippetRecord(
            title: "Staging Webhook Signing Secret",
            content: "whsec_demo_9f83b7c2e1409a8d6f5412e90c3b81a7",
            tags: [devopsTag],
            isPinned: false,
            isSecret: true,
            requireBiometrics: true,
            autoClearSeconds: 30
        )

        context.insert(s1)
        context.insert(s2)
        context.insert(s3)
        context.insert(s4)
        try? context.save()
    }
}
