import Combine
import SwiftUI

struct MenuPanelView: View {
    @EnvironmentObject private var c: AudioController
    // 电平表刷新约 15fps,只读原子量,不占音频线程
    private let meterTimer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用麦克风直通", isOn: Binding(
                get: { c.isEnabled },
                set: { c.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.headline)

            if c.isEnabled && !c.isRunning {
                Text(c.pendingResumeText ?? "未在运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = c.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if c.micPermissionDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("没有麦克风权限").font(.callout).bold()
                    Text("允许 MicMonitor 访问麦克风后才能工作。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("打开系统设置") { c.openMicSettings() }
                        .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            if c.feedbackGain < 0.9 {
                Text("检测到啸叫(麦克风拾取了耳机的声音),已自动降低音量至 \(Int(c.feedbackGain * 100))%。"
                    + "建议换用离耳机更远的麦克风(如笔记本内置麦克风),或调低混入音量。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if c.showBluetoothWarning {
                Text("输入和输出是同一台蓝牙设备:使用它的麦克风会把耳机切换到通话模式(HFP),音乐音质会明显下降。建议选择内置麦克风。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Picker("输入设备(麦克风)", selection: $c.selectedInputUID) {
                Text("系统默认(\(c.defaultInputName))").tag("")
                ForEach(c.inputDevices) { d in
                    Text(d.name + (d.isBluetooth ? "(蓝牙)" : "")).tag(d.uid)
                }
            }

            Picker("输出设备(耳机)", selection: $c.selectedOutputUID) {
                Text("系统默认(\(c.defaultOutputName))").tag("")
                ForEach(c.outputDevices) { d in
                    Text(d.name + (d.isBluetooth ? "(蓝牙)" : "")).tag(d.uid)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("混入音量")
                Slider(value: $c.volume, in: 0...2, step: 0.01)
                Text("\(Int(round(c.volume * 100)))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button(c.muted ? "取消静音" : "静音") { c.muted.toggle() }
                    .controlSize(.small)
            }

            Divider()

            Toggle("噪声门", isOn: $c.gateEnabled)
            if c.gateEnabled {
                HStack(spacing: 8) {
                    Text("阈值")
                    Slider(value: $c.gateThresholdDB, in: -80...0)
                    Text("\(Int(c.gateThresholdDB)) dB")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            LevelBar(level: c.inputLevel, thresholdDB: c.gateThresholdDB,
                     gateGain: c.gateGain, gateOn: c.gateEnabled)
                .frame(height: 10)
            Text("实时输入电平(\(c.inputLevel > 0 ? String(format: "%.0f", 20 * log10f(max(c.inputLevel, 1e-4))) : "-∞") dB)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("低延迟模式(减少回声感)", isOn: $c.lowLatency)
            Text("启用后请求更小的设备 IO 缓冲。若声音卡顿、欠载增加,可关闭回退。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("在 Dock 中显示图标", isOn: $c.showDockIcon)
            Text("开启后可点 Dock 图标打开此面板;菜单栏图标仍会保留。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("开机自启", isOn: Binding(
                get: { c.launchAtLogin },
                set: { c.setLaunchAtLogin($0) }
            ))
            if c.launchNeedsApproval {
                Text("需在 系统设置 → 通用 → 登录项 中允许 MicMonitor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("缓冲 \(Int(c.bufferedMS)) ms · 欠载 \(c.underrunCount) · 丢弃 \(c.overflowCount) · 重建 \(c.restartCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if c.bufferScaleDisplay > 1.01 {
                Text("检测到设备不稳定,已自动将缓冲放大至 ×\(String(format: "%.1f", c.bufferScaleDisplay))(延迟增加,换取不再卡顿)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Button("打开日志") { c.openLogs() }
                Button("复制诊断信息") { c.copyDiagnostics() }
                Spacer()
                Button("退出") { c.quit() }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 350)
        .onReceive(meterTimer) { _ in c.refreshMeters() }
    }
}

/// 实时电平条:-60dB..0dB 量程;噪声门开启时显示阈值竖线,门关时电平条变灰。
private struct LevelBar: View {
    let level: Float        // 线性峰值
    let thresholdDB: Float
    let gateGain: Float
    let gateOn: Bool

    private func frac(_ linear: Float) -> CGFloat {
        let db = 20 * log10f(max(linear, 1e-4))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(barColor)
                    .frame(width: geo.size.width * frac(level))
                if gateOn {
                    Rectangle()
                        .fill(.white.opacity(0.85))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * thresholdFrac)
                }
            }
        }
    }

    private var thresholdFrac: CGFloat {
        CGFloat(min(max((thresholdDB + 60) / 60, 0), 1))
    }

    private var barColor: Color {
        if !gateOn { return .green }
        return gateGain > 0.5 ? .green : .gray
    }
}
