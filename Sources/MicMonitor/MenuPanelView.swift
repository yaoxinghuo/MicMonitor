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

            // 常驻状态行:正常时显示"运行中/已停止",异常时变橙/红;
            // 固定最小高度,避免提示出现/消失时整个面板布局跳动
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)

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
                Text(String(localized: "检测到啸叫(麦克风拾取了耳机的声音),已自动降低音量至 \(Int(c.feedbackGain * 100))%。建议换用离耳机更远的麦克风(如笔记本内置麦克风),或调低混入音量。"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if c.showBluetoothWarning {
                Text("输入和输出是同一台蓝牙设备:使用它的麦克风会把耳机切换到通话模式(HFP),音乐音质会明显下降。建议选择内置麦克风。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Picker("输入设备(麦克风)", selection: $c.selectedInputUID) {
                Text("系统默认(\(c.defaultInputName))").tag("")
                ForEach(c.inputDevices) { d in
                    Text(d.name + (d.isBluetooth ? String(localized: "(蓝牙)") : "")).tag(d.uid)
                }
            }

            Picker("输出设备(耳机)", selection: $c.selectedOutputUID) {
                Text("系统默认(\(c.defaultOutputName))").tag("")
                ForEach(c.outputDevices) { d in
                    Text(d.name + (d.isBluetooth ? String(localized: "(蓝牙)") : "")).tag(d.uid)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("混入音量")
                Slider(value: $c.volume, in: 0...2, step: 0.01)
                Text("\(Int(round(c.volume * 100)))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button(c.muted ? String(localized: "取消静音") : String(localized: "静音")) { c.muted.toggle() }
                    .controlSize(.small)
            }

            Divider()

            helpRow("gate", "噪声门", isOn: $c.gateEnabled,
                    help: "环境安静但耳机里有持续底噪时开启;电平低于阈值的声音不混入。看电平条把阈值设在「底噪之上、说话声之下」。")
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
                .fixedSize(horizontal: false, vertical: true)

            helpRow("voice", "人声突显", isOn: $c.voiceFocus,
                    help: "检测到语音时正常播放;无人声时按「压低量」衰减,突出说话声、压低环境噪声。可与噪声门叠加。灵敏度过低可能把人声也压掉,过高则失去过滤效果;结合下方状态指示调节。")
            if c.voiceFocus {
                HStack(spacing: 8) {
                    Text("灵敏度")
                    Slider(value: $c.voiceFocusSensitivity, in: 0...1, step: 0.05)
                    Text("\(Int(round(c.voiceFocusSensitivity * 100)))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("压低量")
                    Slider(value: $c.voiceDuckDB, in: -40...0, step: 1)
                    Text("\(Int(c.voiceDuckDB)) dB")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text(c.voiceSpeechActiveUI
                     ? String(localized: "当前状态:检测到语音")
                     : String(localized: "当前状态:非人声(已压低)"))
                    .font(.caption2)
                    .foregroundStyle(c.voiceSpeechActiveUI ? .green : .secondary)
            }

            helpRow("venh", "人声增强(自动增益)", isOn: $c.voiceEnhance,
                    help: "自动抬升小声输入(上限约 +20dB):安静时增益缓慢拉高、响起来快速回落,让远处人声更清楚。底噪也会被一起放大,建议配合噪声门使用。")
            if c.voiceEnhance {
                Text("当前增益提升:+\(String(format: "%.1f", 20 * log10f(max(c.agcGain, 1e-3)))) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            helpRow("lowlat", "低延迟模式(减少回声感)", isOn: $c.lowLatency,
                    help: "启用后请求更小的设备 IO 缓冲,端到端延迟更低、回声感更弱;设备跟不上时若声音卡顿、欠载增加,可关闭回退。")

            Divider()

            helpRow("dock", "在 Dock 中显示图标", isOn: Binding(
                get: { c.showDockIcon },
                set: { c.setDockIcon($0) }
            ), help: "开启后可点 Dock 图标打开此面板;菜单栏图标仍会保留。")

            helpRow("login", "开机自启", isOn: Binding(
                get: { c.launchAtLogin },
                set: { c.setLaunchAtLogin($0) }
            ), help: "登录后自动启动 MicMonitor。若系统提示需要批准,去 系统设置 → 通用 → 登录项 中允许。")
            if c.launchNeedsApproval {
                Text("需在 系统设置 → 通用 → 登录项 中允许 MicMonitor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 等宽字体 + Grid 按列对齐(标签/数值各占一列),数值位数变化不抖动,上下行整齐
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    Text("缓冲")
                    Text(String(format: "%-4d", Int(c.bufferedMS)) + "ms")
                    Text("欠载")
                    Text(String(format: "%-5d", c.underrunCount))
                }
                GridRow {
                    Text("丢弃")
                    Text(String(format: "%-5d", c.overflowCount))
                    Text("重建")
                    Text(String(format: "%-2d", c.restartCount))
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            if c.bufferScaleDisplay > 1.01 {
                Text("检测到设备不稳定,已自动将缓冲放大至 ×\(String(format: "%.1f", c.bufferScaleDisplay))(延迟增加,换取不再卡顿)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 开关 + 可点击的 ? 图标:点击在该行下方展开/收起说明文字(手风琴,同时只展开一条)。
    /// 不用系统 tooltip:菜单栏弹层非 key window,.help() 不触发;而原生 toolTip 有固定
    /// ~1s 延迟且无公开 API 可调,点击展开更贴合"主动查看说明"的习惯(系统设置同款)。
    @State private var expandedHelp: String?

    /// 状态行内容:红/橙/绿/灰圆点 + 对应文案。错误优先于等待态,未启用显示"已停止"。
    private var statusText: String {
        if let err = c.errorMessage { return err }
        if !c.isEnabled { return String(localized: "已停止") }
        if c.isRunning { return String(localized: "运行中") }
        return c.pendingResumeText ?? String(localized: "未在运行")
    }

    private var statusColor: Color {
        if c.errorMessage != nil { return .red }
        if !c.isEnabled { return .secondary }
        return c.isRunning ? .green : .orange
    }

    private func helpRow(_ id: String, _ title: LocalizedStringKey, isOn: Binding<Bool>,
                         help: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(title, isOn: isOn)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedHelp = expandedHelp == id ? nil : id
                    }
                } label: {
                    Image(systemName: expandedHelp == id
                          ? "questionmark.circle.fill" : "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if expandedHelp == id {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
