import AppKit
import SwiftUI

@main
struct MicMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudioController()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(controller)
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
    // 不能在 App.init 里用 _controller.wrappedValue 接线:那会强制提前实例化
    // AudioController,而 AudioController.init 早于 NSApplication 创建(NSApp=nil 崩溃)。
    // 改为通过 AudioController.current 静态弱引用在 delegate 回调里取。
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioController.current?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AudioController.current?.handleDockReopen() }
        return true
    }
}
