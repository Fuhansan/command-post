import SwiftUI

/// 主框架:底部 4 Tab(任务 / 通知 / 设备 / 设置)。
struct MainTabView: View {
    @State private var selection: Int

    init(initialTab: Int = 0) {
        _selection = State(initialValue: initialTab)
        // 深色 Tab 栏外观
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.bg)
        appearance.shadowColor = UIColor(Theme.stroke)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selection) {
            TasksView()
                .tabItem { Label("任务", systemImage: "checklist") }
                .tag(0)

            NotificationsView()
                .tabItem { Label("通知", systemImage: "bell") }
                .badge(2)
                .tag(1)

            DevicesView()
                .tabItem { Label("设备", systemImage: "desktopcomputer") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(Theme.blue)
    }
}
