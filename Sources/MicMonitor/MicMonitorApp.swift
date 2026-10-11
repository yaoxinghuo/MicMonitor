import AppKit
import SwiftUI

@main
struct MicMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudioController()

    init() {
        // 让 delegate 能拿到 controller(reopen/激活策略都转发给它)
        appDelegate.controller = _controller.wrappedValue
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(controller)
                .onAppear { controller.applyActivationPolicy() }
        } label: {
            // 开启时用填充图标区分(LSUIElement 应用只出现在菜单栏)
            Image(nsImage: controller.isRunning ? MenuBarIcon.on : MenuBarIcon.off)
        }
        .menuBarExtraStyle(.window)
    }
}

/// LSUIElement 只是 Info.plist 的启动默认;用户开启"Dock 图标"后切换为 regular,
/// 点击 Dock 图标(无可见窗口时触发 applicationShouldHandleReopen)弹出面板窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: AudioController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller?.handleDockReopen() }
        return true
    }
}
