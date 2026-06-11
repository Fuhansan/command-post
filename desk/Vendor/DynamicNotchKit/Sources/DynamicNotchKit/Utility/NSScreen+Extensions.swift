//
//  NSScreen+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//

import SwiftUI

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })

        return screenWithMouse
    }

    var hasNotch: Bool {
        auxiliaryTopLeftArea?.width != nil && auxiliaryTopRightArea?.width != nil
    }

    var notchSize: NSSize? {
        guard
            let topLeftNotchpadding: CGFloat = auxiliaryTopLeftArea?.width,
            let topRightNotchpadding: CGFloat = auxiliaryTopRightArea?.width
        else {
            return nil
        }

        let notchHeight = safeAreaInsets.top
        let notchWidth = frame.width - topLeftNotchpadding - topRightNotchpadding
        return .init(width: notchWidth, height: notchHeight)
    }

    var notchFrame: NSRect? {
        guard let notchSize else { return nil }
        return .init(
            x: frame.midX - (notchSize.width / 2),
            y: frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    /// Standard macOS menu bar height — used as a fallback on external displays
    /// where the system menu bar is hidden (`visibleFrame.maxY == frame.maxY`).
    /// Without this, the notch collapses to a 0pt-tall invisible shape.
    private static let fallbackMenubarHeight: CGFloat = 24

    var menubarHeight: CGFloat {
        let measured = frame.maxY - visibleFrame.maxY
        return measured > 0 ? measured : Self.fallbackMenubarHeight
    }

    var notchFrameWithMenubarAsBackup: NSRect {
        if let notchFrame {
            return notchFrame
        } else {
            let arbitraryNotchWidth: CGFloat = 300
            let arbitraryNotchHeight: CGFloat = menubarHeight

            let arbitraryNotchFrame = NSRect(
                x: frame.midX - (arbitraryNotchWidth / 2),
                y: frame.maxY - arbitraryNotchHeight,
                width: arbitraryNotchWidth,
                height: arbitraryNotchHeight
            )

            return arbitraryNotchFrame
        }
    }
}
