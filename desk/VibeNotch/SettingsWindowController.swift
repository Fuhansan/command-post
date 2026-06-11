import AppKit
import SwiftUI

/// Owns the single Settings window. LSUIElement apps can't use SwiftUI's
/// `Settings { }` scene (no main menu to wire ⌘, into), so we manage an
/// `NSWindow` ourselves and bring it to the front from the status bar.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(settings: AppSettings.shared)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = L10n.t(.settingsTitle, locale: L10n.resolved(from: AppSettings.shared.language))
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Refresh the window title in the new language without recreating the
    /// window — called by AppDelegate when the language picker changes.
    func refreshTitle() {
        window?.title = L10n.t(.settingsTitle, locale: L10n.resolved(from: AppSettings.shared.language))
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Keep the controller alive but drop the window so next show() rebuilds
        // a fresh hosting view (avoids stale @ObservedObject bindings).
        Task { @MainActor in self.window = nil }
    }
}
