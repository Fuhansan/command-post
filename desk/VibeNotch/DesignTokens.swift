import SwiftUI

enum DesignTokens {
    // MARK: - State semantic colors
    static let stateIdle    = Color(hex: 0x8E8E93)
    static let stateWorking = Color(hex: 0x0A84FF)
    static let stateWaiting = Color(hex: 0xFF9F0A)
    static let stateDone    = Color(hex: 0x30D158)

    // MARK: - Surfaces
    static let surfaceRow       = Color.white.opacity(0.04)
    static let surfaceRowActive = Color.white.opacity(0.08)
    static let borderDivider    = Color.white.opacity(0.06)

    // MARK: - Text
    static let textPrimary   = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary  = Color.white.opacity(0.38)

    // MARK: - Diff
    static let diffAddBackground = Color(hex: 0x30D158).opacity(0.15)
    static let diffDelBackground = Color(hex: 0xFF453A).opacity(0.15)

    // MARK: - Spacing (4pt baseline)
    static let spaceXXS: CGFloat = 2
    static let spaceXS:  CGFloat = 4
    static let spaceSM:  CGFloat = 8
    static let spaceMD:  CGFloat = 12
    static let spaceLG:  CGFloat = 16
    static let spaceXL:  CGFloat = 24

    // MARK: - Sizes
    static let panelWidth: CGFloat = 420
    static let rowHeight:  CGFloat = 40
    static let stateDot:   CGFloat = 6
    static let cornerCard: CGFloat = 8
    static let buttonHeight: CGFloat = 28

    // MARK: - Animations
    static let openSpring     = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let collapseEase   = Animation.easeOut(duration: 0.25)
    static let stateTween     = Animation.easeInOut(duration: 0.18)
    static let pulse: Animation = .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
}
