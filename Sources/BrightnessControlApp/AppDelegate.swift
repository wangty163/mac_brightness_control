import AppKit
import BrightnessControlCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: BrightnessAppState!
    private var mainWindow: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var menuView: NSView!
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BrightnessControlApp did finish launching")
        NSApp.setActivationPolicy(.regular)
        appState = BrightnessAppState()
        configureMainMenu()
        configureMainWindow()
        configureStatusItem()
        configureAutomaticRefreshTriggers()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Brightness Control")
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Brightness Control",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(closeMainWindow(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func closeMainWindow(_ sender: Any?) {
        mainWindow?.performClose(sender)
    }

    private func configureMainWindow() {
        NSLog("BrightnessControlApp configuring main window")
        let rootView = DetailWindowView()
            .environmentObject(appState)
            .frame(minWidth: 560, minHeight: 420)
        let hostingView = NSHostingView(rootView: rootView)

        mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "Brightness Control"
        mainWindow.contentView = hostingView
        mainWindow.center()
        mainWindow.isRestorable = false
        mainWindow.isReleasedWhenClosed = false
    }

    private func configureStatusItem() {
        NSLog("BrightnessControlApp configuring status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Brightness Control"
        }

        let menuView = NSHostingView(
            rootView: MenuBarPanelView { [weak self] in
                self?.statusMenu.cancelTracking()
                self?.showMainWindow()
            }.environmentObject(appState)
        )
        self.menuView = menuView
        updateMenuViewFrame()

        let panelItem = NSMenuItem()
        panelItem.view = menuView

        statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        statusMenu.addItem(panelItem)
        statusItem.menu = statusMenu
    }

    private func updateMenuViewFrame() {
        let size = NSSize(
            width: MenuPanelSizing.width,
            height: MenuPanelSizing.height(
                displayCount: appState.displays.count,
                isLoading: appState.isRefreshing,
                hasError: appState.errorMessage != nil
            )
        )
        menuView.frame = NSRect(origin: .zero, size: size)
    }

    private func showMainWindow() {
        NSLog("BrightnessControlApp showing main window")
        centerMainWindowOnCurrentScreen()
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        appState.requestRefreshSoon()
        NSLog("BrightnessControlApp main window visible=%d ordered=%d", mainWindow.isVisible, mainWindow.isVisible)
    }

    private func configureAutomaticRefreshTriggers() {
        let defaultCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        notificationObservers.append(
            defaultCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appState.requestRefreshSoon()
                }
            }
        )

        notificationObservers.append(
            defaultCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appState.requestRefreshSoon()
                }
            }
        )

        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for notificationName in workspaceNotifications {
            notificationObservers.append(
                workspaceCenter.addObserver(
                    forName: notificationName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.appState.requestRefreshSoon()
                    }
                }
            )
        }
    }

    private func centerMainWindowOnCurrentScreen() {
        let screen = screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        var frame = mainWindow.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        mainWindow.setFrame(mainWindow.constrainFrameRect(frame, to: screen), display: false)
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuViewFrame()
        appState.requestRefreshSoon()
    }
}
