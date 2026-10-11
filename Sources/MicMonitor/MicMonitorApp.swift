import SwiftUI

@main
struct MicMonitorApp: App {
    @StateObject private var controller = AudioController()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(controller)
        } label: {
            // 开启时用填充+声波图标区分(LSUIElement 应用只出现在菜单栏)
            Image(nsImage: controller.isRunning ? MenuBarIcon.on : MenuBarIcon.off)
        }
        .menuBarExtraStyle(.window)
    }
}
