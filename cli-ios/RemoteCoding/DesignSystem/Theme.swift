import SwiftUI

/// 全局设计令牌(对齐设计图,深色主题)。
enum Theme {
    // 背景层
    static let bg          = Color(hex: 0x0A0B0E)
    static let card        = Color(hex: 0x16181E)
    static let cardHi      = Color(hex: 0x1C1F26)
    static let field       = Color(hex: 0x101216)
    static let stroke      = Color(hex: 0x262A32)

    // 文字
    static let text        = Color(hex: 0xF2F3F5)
    static let textSec     = Color(hex: 0x8B919C)
    static let textTer     = Color(hex: 0x5C616B)

    // 强调 / 状态
    static let blue        = Color(hex: 0x3B82F6)
    static let blueBtn     = Color(hex: 0x2B6CF6)
    static let coral       = Color(hex: 0xEE4F2E)   // 主操作 / 危险
    static let gold        = Color(hex: 0xC8990F)   // 等待输入 / 回复
    static let green       = Color(hex: 0x2FBE4F)
    static let orange      = Color(hex: 0xF0A23C)
    static let purple      = Color(hex: 0x5B5BD6)

    // 圆角
    static let rCard: CGFloat = 16
    static let rBtn:  CGFloat = 12

    /// 协议里的颜色名(`color`/`tint`/`style`)→ 深色令牌。未知名走 `def`。
    /// 这是「服务端只发语义色名、客户端决定深色具体值」的落点。
    static func named(_ name: String?, default def: Color = textSec) -> Color {
        switch name {
        case "green", "success":          return green
        case "red", "coral", "danger":    return coral
        case "blue", "primary", "info":   return blue
        case "gold", "warning":           return gold
        case "orange":                    return orange
        case "purple":                    return purple
        case "text", "primaryText":       return text
        case "secondary", "textSec":      return textSec
        case "tertiary", "textTer":       return textTer
        default:                          return def
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - 复用修饰

/// 标准卡片容器外观。
struct CardBackground: ViewModifier {
    var fill: Color = Theme.card
    var stroke: Color = Theme.stroke
    var radius: CGFloat = Theme.rCard
    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    func cardStyle(fill: Color = Theme.card, stroke: Color = Theme.stroke, radius: CGFloat = Theme.rCard) -> some View {
        modifier(CardBackground(fill: fill, stroke: stroke, radius: radius))
    }
}
