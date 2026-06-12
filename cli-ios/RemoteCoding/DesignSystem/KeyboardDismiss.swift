import SwiftUI

extension View {
    /// 点击空白处收起键盘:挂一个不拦截子视图按钮的背景点击手势。
    func dismissKeyboardOnTap() -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded { hideKeyboard() }
        )
    }
}

/// 收起当前键盘(辞去第一响应者)。
@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
