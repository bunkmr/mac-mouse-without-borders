// MWBMacClientApp.swift
// 应用入口：仅菜单栏(agent)应用。

import SwiftUI

@main
struct MWBMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 无主窗口；配置面板通过 StatusItem 弹出(见 AppDelegate)
        Settings {
            EmptyView()
        }
    }
}
