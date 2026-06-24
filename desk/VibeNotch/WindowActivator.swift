import AppKit
import ApplicationServices
import Foundation

/// Multi-window-aware activator for IDEs (PyCharm, VS Code, etc.) where one
/// process hosts many project windows. Plain `NSRunningApplication.activate`
/// only brings the *app* forward — not the specific project window the user's
/// session lives in. We use the Accessibility API to enumerate the app's
/// windows and raise the one whose title matches the session's cwd.
enum WindowActivator {
    /// True if VibeNotch has Accessibility permission. AX calls silently fail
    /// without it; we use this to decide whether to even attempt window-level
    /// activation vs. falling back to whole-app activation.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the system Accessibility permission prompt if not already
    /// granted. Safe to call repeatedly — only prompts the first time.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Activate the specific window of `pid` whose AX title best matches the
    /// project rooted at `cwd`. Returns true if a matching window was raised;
    /// false if no match (caller should fall back to whole-app activation).
    @MainActor
    static func activateWindow(pid: pid_t, cwd: String) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return false
        }

        guard let target = bestMatch(windows: windows, cwd: cwd) else {
            return false
        }

        // Raise + make-main brings the window to the front of the app's stack;
        // app.activate then brings the app itself forward. Order matters: raise
        // first so when activate fires the right window is already on top.
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        if let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: [])
        }
        return true
    }

    /// Best-effort focus for Electron-style chat inputs. This is used after
    /// activating Codex.app so remote phone input lands in the composer rather
    /// than whichever non-editable element happened to be focused.
    @MainActor
    static func focusEditableText(pid: pid_t) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let app = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = []
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement
            roots.append(focused)
        }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            roots.append(contentsOf: windows)
        }

        for root in roots {
            if let target = firstEditableText(in: root, depth: 0) {
                AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return true
            }
        }
        return false
    }

    /// Score each window by how well its title matches the cwd, return the best.
    /// Tie-break: prefer windows that contain the full project name as a token.
    private static func bestMatch(windows: [AXUIElement], cwd: String) -> AXUIElement? {
        let projectName = (cwd as NSString).lastPathComponent
        guard !projectName.isEmpty, projectName != "/" else {
            return windows.first
        }
        let cwdLower = cwd.lowercased()
        let nameLower = projectName.lowercased()

        var best: (window: AXUIElement, score: Int)? = nil
        for w in windows {
            let title = windowTitle(w)?.lowercased() ?? ""
            var score = 0
            if title.contains(cwdLower) { score += 100 }       // full path mentioned
            if title.contains(nameLower) { score += 50 }       // project name mentioned
            // JetBrains often formats titles "Name – path" — boost windows
            // that start with the project name (most likely the right one).
            if title.hasPrefix(nameLower) { score += 25 }
            if score > 0 {
                if best == nil || score > best!.score {
                    best = (w, score)
                }
            }
        }
        return best?.window
    }

    private static func windowTitle(_ window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard r == .success else { return nil }
        return titleRef as? String
    }

    private static func firstEditableText(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" {
            return element
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = firstEditableText(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
