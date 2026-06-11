import SwiftUI

/// PROTOCOL 原则 2 / §10 —— 未知组件类型的兜底渲染。绝不崩溃。
/// 这里只在「连兜底文本都没有」时出现;消息级 fallbackText 由 MessageBubble 优先处理。
struct UnknownRenderer: View {
    let component: Component
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
            Text("不支持的组件「\(component.type)」,请更新 App")
                .font(.system(size: 13))
        }
        .foregroundStyle(Theme.textTer)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardHi)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
