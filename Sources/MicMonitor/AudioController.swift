import AppKit
// @preconcurrency:convert 的 inputBlock 标了 @Sendable 但实际在同一线程同步执行,
// 捕获 AVAudioPCMBuffer 是安全的;这样写避免 Sendable 噪音警告
@preconcurrency import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import ServiceManagement
import Synchronization
import SwiftUI

/// 音频管线的跨线程共享状态:全部是原子量,实时音频线程与 UI 线程都可安全访问。
final class MeterState: @unchecked Sendable {
    let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)    // 目标音量 0~2(已含静音)
    let gateEnabled = Atomic<Int>(0)
    let gateThresholdBits = Atomic<UInt32>(Float(0).bitPattern) // 线性幅度阈值
    let inputPeakBits = Atomic<UInt32>(Float(0).bitPattern)     // 采集端输入峰值
    let gateGainBits = Atomic<UInt32>(Float(1).bitPattern)      // 噪声门开合度
    let feedbackGainBits = Atomic<UInt32>(Float(1).bitPattern)  // 啸叫守护当前增益(<1 表示正在压制)
    let bufferedFrames = Atomic<Int>(0)                       // 播放端环形缓冲水位
    let convertErrors = Atomic<Int>(0)
}

/// 采集端上下文(tap 回调专用)。
/// ⚠️ 回调跑在实时线程:禁止分配/锁/日志。converter 重建只在输入格式变化时发生(罕见)。
final class CaptureContext: @unchecked Sendable {
    let ring: RingBuffer
    let shared: MeterState
    let canonicalFormat: AVAudioFormat   // 非交错 Float32,播放端采样率与声道数
    let channelCount: Int
    let prefillFrames: Int
    /// 声道指针数组(预分配):ring.write 的入参,回调内零分配
    let inPtrs: UnsafeMutableBufferPointer<UnsafeBufferPointer<Float>>
    /// 转换器意外吐出交错布局时的拆分暂存:[ch][scratchFrames]
    let scratch: UnsafeMutableBufferPointer<Float>
    let scratchPtrs: UnsafeMutableBufferPointer<UnsafeBufferPointer<Float>>
    let scratchFrames = 8192
    var converter: AVAudioConverter?
    var inSampleRate: Double = 0
    var inChannels: UInt32 = 0
    var outBuffer: AVAudioPCMBuffer?

    init(ring: RingBuffer, shared: MeterState, canonicalFormat: AVAudioFormat,
         channelCount: Int, prefillFrames: Int) {
        self.ring = ring
        self.shared = shared
        self.canonicalFormat = canonicalFormat
        self.channelCount = channelCount
        self.prefillFrames = prefillFrames
        inPtrs = .allocate(capacity: channelCount)
        scratch = .allocate(capacity: channelCount * scratchFrames)
        scratch.initialize(repeating: 0)
        scratchPtrs = .allocate(capacity: channelCount)
        for c in 0..<channelCount {
            scratchPtrs[c] = UnsafeBufferPointer(
                start: scratch.baseAddress! + c * scratchFrames, count: scratchFrames)
        }
    }

    deinit {
        inPtrs.deallocate()
        scratch.deallocate()
        scratchPtrs.deallocate()
    }
}

/// 播放端上下文(渲染回调专用,同样的实时约束)。
final class RenderContext: @unchecked Sendable {
    let ring: RingBuffer
    let shared: MeterState
    let dsp = DSPEngine()
    let channelCount: Int
    let sampleRate: Double
    /// 渲染缓冲的声道指针数组(预分配)
    let outPtrs: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    /// 渲染侧若意外收到交错布局时的兜底暂存:[ch][scratchFrames]
    let scratch: UnsafeMutableBufferPointer<Float>
    let scratchPtrs: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    let scratchFrames = 4096

    init(ring: RingBuffer, shared: MeterState, channelCount: Int, sampleRate: Double) {
        self.ring = ring
        self.shared = shared
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        outPtrs = .allocate(capacity: channelCount)
        scratch = .allocate(capacity: channelCount * scratchFrames)
        scratch.initialize(repeating: 0)
        scratchPtrs = .allocate(capacity: channelCount)
        for c in 0..<channelCount {
            scratchPtrs[c] = scratch.baseAddress! + c * scratchFrames
        }
    }

    deinit {
        outPtrs.deallocate()
        scratch.deallocate()
        scratchPtrs.deallocate()
    }
}

@MainActor
final class AudioController: ObservableObject {
    // MARK: - 面板状态
    /// 用户意图上的开关(= 期望直通开启;设备暂缺时为 true 且 pendingAutoResume)
    @Published private(set) var isEnabled = false
    /// 引擎实际运行状态
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?
    @Published var inputDevices: [AudioDeviceInfo] = []
    @Published var outputDevices: [AudioDeviceInfo] = []
    @Published var defaultInputName = "不可用"
    @Published var defaultOutputName = "不可用"
    @Published var micPermissionDenied = false
    @Published var showBluetoothWarning = false
    @Published private(set) var launchAtLogin = false
    @Published var launchNeedsApproval = false

    // "" = 系统默认
    @Published var selectedInputUID = "" {
        didSet {
            guard oldValue != selectedInputUID else { return }
            settings.inputUID = selectedInputUID
            updateBluetoothWarning()
            lowLatencyFallbackDone = false  // 换设备后重新允许低延迟自检
            bufferScale = 1.0               // 新设备可能不需要之前的自适应放大
            if isRunning { scheduleRebuild("切换输入设备") }
        }
    }
    @Published var selectedOutputUID = "" {
        didSet {
            guard oldValue != selectedOutputUID else { return }
            settings.outputUID = selectedOutputUID
            updateBluetoothWarning()
            lowLatencyFallbackDone = false  // 换设备后重新允许低延迟自检
            bufferScale = 1.0               // 新设备可能不需要之前的自适应放大
            if isRunning { scheduleRebuild("切换输出设备") }
        }
    }

    @Published var volume: Float = 1.0 {
        didSet { pushGain(); settings.volume = volume }
    }
    @Published var muted = false {
        didSet { pushGain(); settings.muted = muted }
    }
    @Published var gateEnabled = false {
        didSet {
            meter.gateEnabled.store(gateEnabled ? 1 : 0, ordering: .relaxed)
            settings.gateEnabled = gateEnabled
        }
    }
    @Published var gateThresholdDB: Float = -50 {
        didSet { pushThreshold(); settings.gateThresholdDB = gateThresholdDB }
    }
    /// 低延迟模式:请求 256 帧 IO 缓冲并把水位压到 ~5 块,端到端延迟 ~27ms;
    /// 关掉则回到系统默认缓冲。若设备跟不上小缓冲,启动自检会自动关闭此项并提示。
    @Published var lowLatency = true {
        didSet {
            settings.lowLatency = lowLatency
            if lowLatency { lowLatencyFallbackDone = false }  // 用户手动重新开启,允许再次自检
            if isRunning { scheduleRebuild("切换低延迟模式") }
        }
    }
    /// Dock 图标模式:开 = regular(显示 Dock 图标,点击弹出面板窗口);
    /// 关 = accessory(纯菜单栏)。LSUIElement 只是启动默认值,运行时可合法切换。
    /// 菜单栏图标两种模式下都保留——它是常驻入口,否则 Dock 模式关窗后无入口可回。
    @Published var showDockIcon = false {
        didSet {
            settings.dockIcon = showDockIcon
            applyActivationPolicy()
            if showDockIcon {
                showPanelWindow()  // 立即弹窗给反馈,让用户看到效果
            } else {
                panelWindow?.close()  // Dock 入口没了,窗口留着会失去意义
            }
        }
    }

    /// 面板副标题:期望开启但未在运行时的说明
    var pendingResumeText: String? {
        guard isEnabled, !isRunning else { return nil }
        if pendingAutoResume { return "等待设备重新连接…" }
        return errorMessage == nil ? "启动中…" : nil
    }

    // 电平/状态(UI 定时刷新)
    @Published var inputLevel: Float = 0
    @Published var gateGain: Float = 1
    @Published var feedbackGain: Float = 1
    @Published var bufferedMS: Double = 0
    @Published var underrunCount = 0
    @Published var overflowCount = 0
    @Published var restartCount = 0
    @Published private(set) var bufferScaleDisplay: Double = 1.0

    // MARK: - 内部
    private let settings = Settings.shared
    private let log = AppLogger.shared
    private let devices = AudioDeviceManager()
    private let meter = MeterState()

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    /// 聚合模式(首选架构,与 AU Lab passthrough 同款):
    /// 单引擎绑定私有聚合设备,输入输出同一时钟域,天然无漂移。
    /// 创建失败时回退 captureEngine+playbackEngine 双引擎路径。
    private var unifiedEngine: AVAudioEngine?
    private var aggregateID: AudioDeviceID = 0
    private var ring: RingBuffer?
    private var canonicalFormat: AVAudioFormat?
    private var configObservers: [NSObjectProtocol] = []
    /// Dock 模式下的面板窗口(懒建,关窗只隐藏不销毁,isReleasedWhenClosed=false)
    private var panelWindow: NSWindow?

    private var pendingAutoResume = false
    private var rebuildTask: Task<Void, Never>?
    /// 自身重建引擎(setAudioUnitDevice/installTap/start)会触发引擎再发
    /// AVAudioEngineConfigurationChange 通知 → 不抑制的话"重建→通知→重建"死循环。
    /// 启动后 2s 内到达的通知视为自身副作用,直接忽略;
    /// 真正的拔插事件由 kAudioHardwarePropertyDevices 监听兜底,不依赖此通知。
    private var suppressConfigChangesUntil = Date.distantPast
    private var suppressedConfigChanges = 0
    /// 低延迟模式改过的设备 IO 缓冲原值 (deviceID, isInput, 原帧数),stopPipeline 时恢复
    private var ioBufferOriginals: [(AudioDeviceID, Bool, UInt32)] = []
    /// 低延迟模式启动自检:2s 内欠载次数若超过阈值,说明该设备跟不上小缓冲,自动回退标准模式。
    /// 每次用户手动开启/换设备时重置,避免无限重试循环。
    private var lowLatencyCheckTask: Task<Void, Never>?
    private var lowLatencyFallbackDone = false
    /// 自适应缓冲:某些设备(典型如廉价 USB 耳机)时钟抖动大,聚合设备的漂移补偿
    /// 也压不住,固定缓冲大小猜不准。改为持续监测欠载/溢出率,不稳定就自动把
    /// 水位倍数调大一档重建,直到稳定或到达上限;比让用户手动试缓冲大小靠谱。
    private var bufferScale: Double = 1.0 {
        didSet { bufferScaleDisplay = bufferScale }
    }
    private let maxBufferScale: Double = 6.0
    private var healthCheckTask: Task<Void, Never>?
    private var healthSnapshotEvents = 0
    private var sampleRate = 48000.0
    private var outputChannelCount = 2
    // ring 随引擎重建,旧计数在这里累计
    private var accUnderrun = 0
    private var accOverflow = 0

    init() {
        // 清理上次异常退出可能残留的聚合设备(正常路径 stopPipeline 已销毁)
        CoreAudioUtil.destroyStaleAggregates()
        devices.onEvent = { [weak self] selector in
            Task { @MainActor [weak self] in self?.handleDeviceEvent(selector) }
        }
        devices.startMonitoring()
        refreshLists()

        // 恢复持久化设置(didSet 在 init 中不触发,手动同步原子量)
        selectedInputUID = settings.inputUID
        selectedOutputUID = settings.outputUID
        volume = settings.volume
        muted = settings.muted
        gateEnabled = settings.gateEnabled
        gateThresholdDB = settings.gateThresholdDB
        lowLatency = settings.lowLatency
        showDockIcon = settings.dockIcon
        pushGain()
        pushThreshold()
        meter.gateEnabled.store(gateEnabled ? 1 : 0, ordering: .relaxed)

        // 首次启动优先选内置麦克风:蓝牙耳机的麦克风会把耳机切到通话模式(HFP),
        // 导致音乐音质明显下降(蓝牙协议限制,无法绕过)
        if !settings.hasLaunched {
            settings.hasLaunched = true
            if selectedInputUID.isEmpty,
               let builtIn = devices.devices.first(where: {
                   $0.hasInput && $0.transportType == kAudioDeviceTransportTypeBuiltIn
               }) {
                selectedInputUID = builtIn.uid
                settings.inputUID = builtIn.uid
                log.log("首次启动:预选内置输入设备 \(builtIn.name)")
            }
        }

        refreshPermission()
        refreshLaunchStatus()
        updateBluetoothWarning()
        log.log("启动:输入设备 \(inputDevices.count) 个,输出设备 \(outputDevices.count) 个")

        if settings.wasRunning {
            log.log("上次为开启状态,自动恢复直通")
            setEnabled(true)
        }
    }

    // MARK: - 开关

    func setEnabled(_ on: Bool) {
        if on {
            isEnabled = true
            pendingAutoResume = false
            lowLatencyFallbackDone = false  // 每次重新开启,允许低延迟自检重新评估
            Task { await requestPermissionAndStart() }
        } else {
            isEnabled = false
            pendingAutoResume = false
            settings.wasRunning = false
            stopPipeline()
            errorMessage = nil
        }
    }

    // MARK: - Dock 图标模式

    /// LSUIElement 只是 bundle 启动默认,运行时用 setActivationPolicy 切换是合法做法。
    /// 需在 NSApplication 初始化完成后调用,所以 MicMonitorApp 在 onAppear 里触发。
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    /// Dock 模式下点图标(applicationShouldHandleReopen)或开关切换时调用:
    /// 弹出一个普通窗口托管与菜单栏弹层同一个 MenuPanelView,设置天然共享。
    func showPanelWindow() {
        if let w = panelWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
        } else {
            let host = NSHostingController(rootView: MenuPanelView().environmentObject(self))
            let w = NSWindow(contentViewController: host)
            w.title = "MicMonitor"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false  // 关窗只隐藏,再次点击不重进托管
            w.center()
            panelWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// AppDelegate 转发:Dock 图标被点且当前没有可见窗口时调用
    func handleDockReopen() {
        if showDockIcon { showPanelWindow() }
    }

    private func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startPipeline()
        case .notDetermined:
            log.log("请求麦克风权限")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log.log("麦克风权限授权结果:\(granted)")
            if granted {
                startPipeline()
            } else {
                errorMessage = "未获得麦克风权限,请在系统设置中允许后重试。"
            }
        case .denied, .restricted:
            errorMessage = "未获得麦克风权限,请在系统设置中允许后重试。"
        @unknown default:
            break
        }
        refreshPermission()
    }

    // MARK: - 管线构建

    private func resolveDevice(uid: String, input: Bool) -> AudioDeviceInfo? {
        guard !uid.isEmpty else { return nil }
        return devices.info(forUID: uid)
    }

    /// UID 为空 → 解析当前默认设备(用于取采样率/声道与蓝牙检测)
    private func resolvedInput() -> AudioDeviceInfo? {
        resolveDevice(uid: settings.inputUID, input: true)
            ?? devices.info(forID: CoreAudioUtil.defaultDeviceID(input: true))
    }
    private func resolvedOutput() -> AudioDeviceInfo? {
        resolveDevice(uid: settings.outputUID, input: false)
            ?? devices.info(forID: CoreAudioUtil.defaultDeviceID(input: false))
    }

    private func startPipeline() {
        stopPipeline()
        errorMessage = nil
        let wasWaiting = pendingAutoResume
        pendingAutoResume = false

        // 校验选定设备是否在线
        if !settings.inputUID.isEmpty && devices.info(forUID: settings.inputUID) == nil {
            errorMessage = "所选输入设备当前不可用,重新连接后将自动恢复。"
            pendingAutoResume = true
            return
        }
        if !settings.outputUID.isEmpty && devices.info(forUID: settings.outputUID) == nil {
            errorMessage = "所选输出设备当前不可用,重新连接后将自动恢复。"
            pendingAutoResume = true
            return
        }

        let inDev = resolvedInput()
        let outDev = resolvedOutput()
        guard inDev != nil || CoreAudioUtil.defaultDeviceID(input: true) != 0 else {
            errorMessage = "没有可用的输入设备"
            return
        }
        guard outDev != nil || CoreAudioUtil.defaultDeviceID(input: false) != 0 else {
            errorMessage = "没有可用的输出设备"
            return
        }

        do {
            // 首选:私有聚合设备 + 单引擎(AU Lab passthrough 同款方案)。
            // 输入输出在同一 IO proc/时钟域,系统做漂移补偿,无欠载/回声问题。
            // 聚合创建失败时回退原双引擎路径。
            if let inDev, let outDev,
               let agg = CoreAudioUtil.createAggregateDevice(inputUID: inDev.uid, outputUID: outDev.uid) {
                do {
                    try buildUnifiedEngine(aggregate: agg, input: inDev, output: outDev)
                    log.log("统一引擎已启动(聚合设备 id=\(agg))")
                } catch {
                    log.log("统一引擎启动失败,回退双引擎:\(error.localizedDescription)")
                    unifiedEngine?.stop()
                    unifiedEngine = nil
                    if aggregateID != 0 {
                        CoreAudioUtil.destroyAggregateDevice(aggregateID)
                        aggregateID = 0
                    }
                    try buildDualEngines(input: inDev, output: outDev)
                }
            } else {
                if inDev == nil || outDev == nil {
                    log.log("输入/输出设备未具体指定,使用双引擎路径")
                } else {
                    log.log("聚合设备创建失败,回退双引擎")
                }
                try buildDualEngines(input: inDev, output: outDev)
            }
            // 引擎 start/installTap 引发的配置变化通知会在稍后投递到主队列,
            // 在启动完成后才设窗口,确保覆盖这些"自己造成"的通知
            suppressConfigChangesUntil = Date().addingTimeInterval(2.0)
            registerConfigObservers()
        } catch {
            log.log("启动失败:\(error.localizedDescription)")
            errorMessage = error.localizedDescription
            stopPipeline()
            return
        }

        isRunning = true
        settings.wasRunning = true
        updateBluetoothWarning()
        if wasWaiting { errorMessage = nil }
        log.log("直通开启:输入[\(inDev?.name ?? "系统默认")] → 输出[\(outDev?.name ?? "系统默认")],"
            + " 输出 \(Int(sampleRate))Hz × \(outputChannelCount)ch,目标水位 \(ring?.targetWater ?? 0) 帧"
            + (unifiedEngine != nil ? " [聚合模式]" : " [双引擎模式]"))
        scheduleLowLatencyCheck()
        healthSnapshotEvents = 0
        scheduleBufferHealthCheck()
    }

    /// 双引擎兜底路径:独立采集引擎 + 独立播放引擎(各自绑定设备)
    private func buildDualEngines(input inDev: AudioDeviceInfo?, output outDev: AudioDeviceInfo?) throws {
        try buildPlaybackEngine(output: outDev)
        log.log("播放引擎已启动")
        try buildCaptureEngine(input: inDev)
        log.log("采集引擎已启动")
    }

    /// 统一引擎:私有聚合设备把输入+输出合成一个逻辑设备,单个 AVAudioEngine 驱动。
    /// tap(输入)→ 环形缓冲 → source(输出)全部保留,但两端回调跑在同一个 IO 周期里,
    /// 由系统对两个子设备做漂移补偿——双引擎架构的欠载/时钟漂移问题在原理上不存在。
    private func buildUnifiedEngine(aggregate aggID: AudioDeviceID,
                                    input inDev: AudioDeviceInfo, output outDev: AudioDeviceInfo) throws {
        let engine = AVAudioEngine()
        engine.isAutoShutdownEnabled = false

        do {
            try engine.inputNode.setVoiceProcessingEnabled(false)
        } catch {
            log.log("关闭 VoiceProcessing 失败(继续运行):\(error.localizedDescription)")
        }
        guard let au = engine.outputNode.audioUnit else {
            throw PipelineError.os("获取输出 AudioUnit 失败", -1)
        }
        // 统一引擎的 inputNode/outputNode 共享同一个 IO 单元,绑一次即覆盖双向
        let status = Self.setAudioUnitDevice(au, aggID)
        guard status == noErr else { throw PipelineError.os("绑定聚合设备失败", status) }

        // 聚合设备是我们私有的、用完即毁,直接改其 IO 缓冲无需恢复原值
        let ioFrames = lowLatency
            ? requestIOBufferFrames(aggID, input: false, wanted: 256)
            : Int(CoreAudioUtil.bufferFrameSize(aggID, input: false) ?? 512)

        let sr = (outDev.nominalSampleRate) > 0 ? outDev.nominalSampleRate : 48000
        let ch = max(1, min(8, outDev.outputChannels))
        // 必须非交错:AVAudioMixerNode 输入不接受 interleaved(-10868),planar 也是引擎原生布局
        guard let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                            channels: AVAudioChannelCount(ch), interleaved: false) else {
            throw PipelineError.format
        }
        sampleRate = sr
        outputChannelCount = ch
        canonicalFormat = canonical

        // 同一时钟域,水位只需覆盖调度抖动:目标 ≈3 块,高水位 8 块;
        // bufferScale 由运行时自适应健康检查按需放大(应对 USB 等时钟抖动较大的设备)
        let ringBuf = RingBuffer(capacityFrames: max(Int(sr * 0.8 * bufferScale), 8192), channelCount: ch,
                                 targetWater: max(512, Int(Double(ioFrames * 3) * bufferScale)),
                                 highWater: max(2048, Int(Double(ioFrames * 8) * bufferScale)))
        ring = ringBuf

        let rctx = RenderContext(ring: ringBuf, shared: meter, channelCount: ch, sampleRate: sr)
        rctx.dsp.reset()
        let source = AVAudioSourceNode(format: canonical) { isSilence, _, frameCount, abl -> OSStatus in
            Self.render(ctx: rctx, isSilence: isSilence, frameCount: Int(frameCount), abl: abl)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: canonical)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let cctx = CaptureContext(ring: ringBuf, shared: meter, canonicalFormat: canonical,
                                  channelCount: ch, prefillFrames: ringBuf.targetWater)
        engine.inputNode.installTap(onBus: 0, bufferSize: lowLatency ? 256 : 512, format: nil) { buffer, _ in
            Self.tap(ctx: cctx, buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        unifiedEngine = engine
        aggregateID = aggID
    }

    /// 低延迟模式自检:启动 2s 后看欠载次数是否异常。
    /// 两个独立引擎在小缓冲下对该设备/系统负载撑不住时,欠载会接近 100% 的块都发生
    /// (实测过 61334 次/165s,相当于持续输出静音却完全无感知)。
    /// 一旦判定不稳定,自动关闭低延迟模式回退标准缓冲,避免用户反复手动试错。
    private func scheduleLowLatencyCheck() {
        lowLatencyCheckTask?.cancel()
        guard lowLatency, !lowLatencyFallbackDone else { return }
        let ringRef = ring
        lowLatencyCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.isRunning, let ringRef, ringRef === self.ring else { return }
            let events = ringRef.underrunEvents.load(ordering: .relaxed)
            // 2s 内阈值:正常运行偶有个位数欠载(启动预填充等),大幅异常才回退
            guard events > 200 else { return }
            self.log.log("低延迟模式 2s 内欠载 \(events) 次,判定设备跟不上小缓冲,自动回退标准缓冲")
            self.lowLatencyFallbackDone = true
            self.errorMessage = "检测到音频不稳定,已自动切换为标准缓冲模式(可能是设备不支持低延迟小缓冲)。"
            self.lowLatency = false
        }
    }

    /// 自适应缓冲健康检查:持续每 3s 看一次欠载+溢出增量。
    /// 某些设备(典型如廉价 USB 耳机)时钟抖动大,固定缓冲猜不准、聚合设备的
    /// 漂移补偿也压不住,表现为持续的断续卡顿(不是啸叫,与音量无关)。
    /// 一旦判定不稳定就把 bufferScale 调大一档并重建,循环直到稳定或到上限;
    /// 不在这里尝试自动调小(避免和"判定不稳定→调大"来回震荡)。
    private func scheduleBufferHealthCheck() {
        healthCheckTask?.cancel()
        guard bufferScale < maxBufferScale else { return }
        let ringRef = ring
        healthCheckTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning,
                      let ringRef, ringRef === self.ring else { return }
                let events = ringRef.underrunEvents.load(ordering: .relaxed)
                        + ringRef.overflowEvents.load(ordering: .relaxed)
                let delta = events - self.healthSnapshotEvents
                self.healthSnapshotEvents = events
                guard delta > 30 else { continue }   // 偶发个位数属正常抖动,不处理
                guard self.bufferScale < self.maxBufferScale else {
                    self.log.log("缓冲已达上限(×\(self.bufferScale)),仍有欠载 \(delta) 次/3s,设备可能本身不稳定")
                    return
                }
                self.bufferScale = min(self.maxBufferScale, self.bufferScale * 1.8)
                self.log.log("3s 内欠载+溢出 \(delta) 次,自动放大缓冲至 ×\(String(format: "%.1f", self.bufferScale)) 并重建")
                self.errorMessage = "检测到音频不稳定,已自动增大缓冲(延迟会略增)。"
                self.scheduleRebuild("自适应缓冲放大")
                return   // 新管线启动后会重新调度一次健康检查
            }
        }
    }

    private func buildPlaybackEngine(output: AudioDeviceInfo?) throws {
        let engine = AVAudioEngine()
        engine.isAutoShutdownEnabled = false

        // 只有指定了具体设备才设置;选"系统默认"时让 HAL 单元自动跟随系统默认输出
        if let output {
            guard let au = engine.outputNode.audioUnit else {
                throw PipelineError.os("获取输出 AudioUnit 失败", -1)
            }
            let status = Self.setAudioUnitDevice(au, output.id)
            guard status == noErr else { throw PipelineError.os("设置输出设备失败", status) }
        }

        // 低延迟:请求输出设备 IO 缓冲压到 256 帧(设备可拒绝,读回实际值算水位)。
        // 之前试过 128 帧,在双引擎(输入输出各自独立时钟)架构下余量太小,
        // 实测几乎每块都欠载(61334 次/165s ≈ 100% 欠载率),等于一直在放静音。
        let outID = output?.id ?? CoreAudioUtil.defaultDeviceID(input: false)
        let ioFrames = lowLatency && outID != 0
            ? requestIOBufferFrames(outID, input: false, wanted: 256)
            : Int(CoreAudioUtil.bufferFrameSize(outID, input: false) ?? 512)

        let sr = (output?.nominalSampleRate ?? 0) > 0 ? output!.nominalSampleRate : 48000
        let ch = max(1, min(8, output?.outputChannels ?? 2))
        // 必须非交错:AVAudioMixerNode 输入不接受 interleaved(-10868),planar 也是引擎原生布局
        guard let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                            channels: AVAudioChannelCount(ch), interleaved: false) else {
            throw PipelineError.format
        }
        sampleRate = sr
        outputChannelCount = ch
        canonicalFormat = canonical

        // 环形缓冲:容量 ~0.4s;水位跟随实际 IO 缓冲——目标 ≈5 块,高水位 12 块
        // (两个引擎时钟独立,块数太少会被时钟抖动/调度延迟直接打穿导致持续欠载)
        let ringBuf = RingBuffer(capacityFrames: max(Int(sr * 0.8 * bufferScale), 8192), channelCount: ch,
                                 targetWater: max(512, Int(Double(ioFrames * 5) * bufferScale)),
                                 highWater: max(2048, Int(Double(ioFrames * 12) * bufferScale)))
        ring = ringBuf
        let ctx = RenderContext(ring: ringBuf, shared: meter, channelCount: ch, sampleRate: sr)
        ctx.dsp.reset()

        // AVAudioSourceNode 作为播放数据源:渲染回调从环形缓冲读数据 → DSP → 输出
        let source = AVAudioSourceNode(format: canonical) { isSilence, _, frameCount, abl -> OSStatus in
            Self.render(ctx: ctx, isSilence: isSilence, frameCount: Int(frameCount), abl: abl)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: canonical)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
    }

    private func buildCaptureEngine(input: AudioDeviceInfo?) throws {
        guard let ring, let canonical = canonicalFormat else { throw PipelineError.format }
        let engine = AVAudioEngine()
        engine.isAutoShutdownEnabled = false
        let inputNode = engine.inputNode

        // 关闭语音处理,使用原始 HAL 采集;VoiceProcessingIO 会附带 AGC/AEC 并可能锁定 48k
        do {
            try inputNode.setVoiceProcessingEnabled(false)
        } catch {
            log.log("关闭 VoiceProcessing 失败(继续运行):\(error.localizedDescription)")
        }

        if let input {
            guard let au = inputNode.audioUnit else {
                throw PipelineError.os("获取输入 AudioUnit 失败", -1)
            }
            let status = Self.setAudioUnitDevice(au, input.id)
            guard status == noErr else { throw PipelineError.os("设置输入设备失败", status) }
        }

        // 低延迟:输入侧同样请求小 IO 缓冲;tap 的 bufferSize 只是请求值,实际回调块大小以设备为准
        let inID = input?.id ?? CoreAudioUtil.defaultDeviceID(input: true)
        if lowLatency, inID != 0 {
            _ = requestIOBufferFrames(inID, input: true, wanted: 256)
        }

        let ctx = CaptureContext(ring: ring, shared: meter, canonicalFormat: canonical,
                                 channelCount: outputChannelCount, prefillFrames: ring.targetWater)
        // format: nil → 使用设备原生输入格式,在回调内做格式转换
        inputNode.installTap(onBus: 0, bufferSize: lowLatency ? 256 : 512, format: nil) { buffer, _ in
            Self.tap(ctx: ctx, buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        captureEngine = engine
    }

    private static func setAudioUnitDevice(_ audioUnit: AudioUnit, _ deviceID: AudioDeviceID) -> OSStatus {
        var id = deviceID
        return AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &id,
                                    UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// 低延迟模式:请求设备 IO 缓冲为 wanted 帧,记录原值供 stopPipeline 恢复,返回实际生效帧数
    private func requestIOBufferFrames(_ deviceID: AudioDeviceID, input: Bool, wanted: UInt32) -> Int {
        guard let current = CoreAudioUtil.bufferFrameSize(deviceID, input: input) else { return 512 }
        if current > wanted {
            if CoreAudioUtil.setBufferFrameSize(deviceID, input: input, frames: wanted) {
                ioBufferOriginals.append((deviceID, input, current))
            } else {
                log.log("请求 IO 缓冲 \(wanted) 帧失败,维持 \(current) 帧")
            }
        }
        let actual = CoreAudioUtil.bufferFrameSize(deviceID, input: input) ?? current
        if actual != current {
            log.log("\(input ? "输入" : "输出")设备 IO 缓冲:\(current) → \(actual) 帧")
        }
        return Int(actual)
    }

    // MARK: - 音频线程回调(禁止分配/锁/日志)

    /// 采集 tap:峰值统计 → AVAudioConverter 转为播放端规范格式 → 写环形缓冲。
    private static func tap(ctx: CaptureContext, buffer: AVAudioPCMBuffer) {
        let shared = ctx.shared

        // 输入峰值(仅 Float32 数据有效),供电平表与门限调试
        if buffer.format.commonFormat == .pcmFormatFloat32 {
            var peak: Float = 0
            for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                guard let data = b.mData else { continue }
                let p = data.assumingMemoryBound(to: Float.self)
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                var i = 0
                while i < n {
                    let a = p[i] < 0 ? -p[i] : p[i]
                    if a > peak { peak = a }
                    i += 1
                }
            }
            shared.inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
        }

        let fmt = buffer.format
        if ctx.converter == nil || ctx.inSampleRate != fmt.sampleRate || ctx.inChannels != fmt.channelCount {
            guard let conv = makeConverter(from: fmt, to: ctx.canonicalFormat) else {
                shared.convertErrors.add(1, ordering: .relaxed)
                return
            }
            ctx.converter = conv
            ctx.inSampleRate = fmt.sampleRate
            ctx.inChannels = fmt.channelCount
            ctx.outBuffer = nil
        }

        let ratio = ctx.canonicalFormat.sampleRate / max(fmt.sampleRate, 1)
        let needed = AVAudioFrameCount(min(Int(Double(buffer.frameLength) * ratio * 2.0) + 64, 1 << 20))
        if ctx.outBuffer == nil || ctx.outBuffer!.frameCapacity < needed {
            ctx.outBuffer = AVAudioPCMBuffer(pcmFormat: ctx.canonicalFormat, frameCapacity: needed)
            if ctx.outBuffer == nil {
                shared.convertErrors.add(1, ordering: .relaxed)
                return
            }
        }
        guard let conv = ctx.converter, let out = ctx.outBuffer else { return }

        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status -> AVAudioBuffer? in
            if fed {
                // 流式转换:无更多输入时返回 noDataNow 而非 endOfStream
                // (endOfStream 会冲刷重采样尾垫,造成额外延迟)
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil {
            shared.convertErrors.add(1, ordering: .relaxed)
            return
        }

        let frames = Int(out.frameLength)
        guard frames > 0 else { return }
        // 缓冲为空(首次启动/欠载恢复):先预填充静音拉到目标水位,避免立刻再次欠载
        if ctx.ring.availableFrames == 0 {
            ctx.ring.writeSilence(ctx.prefillFrames)
        }
        let outChannels = ctx.channelCount
        let abl = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        if abl.count == outChannels {
            // 正常路径:转换器输出与 canonical 一致的非交错布局
            var i = 0
            for b in abl where i < outChannels {
                guard let data = b.mData else { return }
                ctx.inPtrs[i] = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self), count: frames)
                i += 1
            }
            ctx.ring.write(UnsafeBufferPointer(ctx.inPtrs), frameCount: frames)
        } else if abl.count == 1, let data = abl[0].mData {
            // 兜底:转换器吐出了交错布局 → 拆分到 scratch 平面再写环
            let p = data.assumingMemoryBound(to: Float.self)
            var f = 0
            while f < frames {
                let chunk = min(frames - f, ctx.scratchFrames)
                for c in 0..<outChannels {
                    let plane = ctx.scratch.baseAddress! + c * ctx.scratchFrames
                    for i in 0..<chunk { plane[i] = p[(f + i) * outChannels + c] }
                }
                ctx.ring.write(UnsafeBufferPointer(ctx.scratchPtrs), frameCount: chunk)
                f += chunk
            }
        }
    }

    /// 渲染回调:环形缓冲 → DSP(增益斜坡/噪声门/软限幅)→ 输出缓冲。
    private static func render(ctx: RenderContext, isSilence: UnsafeMutablePointer<ObjCBool>,
                               frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let shared = ctx.shared
        // 每块同步一次 UI 参数(原子读),具体平滑在 DSP 内逐帧进行
        ctx.dsp.setVolume(Float(bitPattern: shared.targetGainBits.load(ordering: .relaxed)),
                          rampFrames: frameCount)
        ctx.dsp.updateGate(enabled: shared.gateEnabled.load(ordering: .relaxed) != 0,
                           threshold: Float(bitPattern: shared.gateThresholdBits.load(ordering: .relaxed)),
                           sampleRate: ctx.sampleRate)

        let list = UnsafeMutableAudioBufferListPointer(abl)
        var gotAny = false
        if list.count == ctx.channelCount {
            // 正常路径:canonical 非交错,每声道一块缓冲
            var ok = true
            var i = 0
            for b in list where i < ctx.channelCount {
                guard let data = b.mData else { ok = false; break }
                ctx.outPtrs[i] = data.assumingMemoryBound(to: Float.self)
                i += 1
            }
            if ok {
                let dsts = UnsafeBufferPointer(ctx.outPtrs)
                gotAny = ctx.ring.read(dsts, frameCount: frameCount) > 0
                ctx.dsp.process(dsts, frames: frameCount, channels: ctx.channelCount)
            } else {
                for b in list {
                    if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
                }
            }
        } else if list.count == 1, ctx.channelCount > 1, let data = list[0].mData {
            // 兜底:渲染缓冲是交错布局 → 读到 scratch 平面,DSP 后交错写出
            let p = data.assumingMemoryBound(to: Float.self)
            var f = 0
            while f < frameCount {
                let chunk = min(frameCount - f, ctx.scratchFrames)
                let sd = UnsafeBufferPointer(ctx.scratchPtrs)
                if ctx.ring.read(sd, frameCount: chunk) > 0 { gotAny = true }
                ctx.dsp.process(sd, frames: chunk, channels: ctx.channelCount)
                for i in 0..<chunk {
                    for c in 0..<ctx.channelCount {
                        p[(f + i) * ctx.channelCount + c] = ctx.scratchPtrs[c][i]
                    }
                }
                f += chunk
            }
        } else {
            // 未知布局:输出静音
            for b in list {
                if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
            }
        }

        isSilence.pointee = ObjCBool(!gotAny)
        shared.bufferedFrames.store(ctx.ring.availableFrames, ordering: .relaxed)
        shared.gateGainBits.store(ctx.dsp.gateGain.bitPattern, ordering: .relaxed)
        shared.feedbackGainBits.store(ctx.dsp.feedbackGain.bitPattern, ordering: .relaxed)
        return noErr
    }

    /// 构建转换器;声道数不一致时显式给映射表(单声道麦克风 → 双声道为复制第 0 声道)
    private static func makeConverter(from: AVAudioFormat, to: AVAudioFormat) -> AVAudioConverter? {
        guard let c = AVAudioConverter(from: from, to: to) else { return nil }
        if from.channelCount != to.channelCount {
            let inCh = max(1, Int(from.channelCount))
            c.channelMap = (0..<Int(to.channelCount)).map { NSNumber(value: min($0, inCh - 1)) }
        }
        c.primeMethod = .none
        c.dither = false
        return c
    }

    // MARK: - 停止 / 重建

    private func stopPipeline() {
        for o in configObservers { NotificationCenter.default.removeObserver(o) }
        configObservers.removeAll()
        rebuildTask?.cancel()
        rebuildTask = nil
        lowLatencyCheckTask?.cancel()
        lowLatencyCheckTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil

        accumulateCounters()
        if let cap = captureEngine {
            cap.inputNode.removeTap(onBus: 0)
            cap.stop()
        }
        if let uni = unifiedEngine {
            uni.inputNode.removeTap(onBus: 0)
            uni.stop()
        }
        playbackEngine?.stop()
        captureEngine = nil
        playbackEngine = nil
        unifiedEngine = nil
        // 聚合设备是我们创建并拥有的,销毁它(HAL 会自动断开内部子设备引用)
        if aggregateID != 0 {
            CoreAudioUtil.destroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        // 恢复被低延迟模式改过的物理设备 IO 缓冲(聚合设备已销毁,无需恢复)
        for (devID, isInput, frames) in ioBufferOriginals {
            _ = CoreAudioUtil.setBufferFrameSize(devID, input: isInput, frames: frames)
        }
        ioBufferOriginals.removeAll()
        ring = nil
        canonicalFormat = nil
        isRunning = false
        meter.bufferedFrames.store(0, ordering: .relaxed)
    }

    private func accumulateCounters() {
        if let ring {
            accUnderrun += ring.underrunEvents.load(ordering: .relaxed)
            accOverflow += ring.overflowEvents.load(ordering: .relaxed)
        }
    }

    private func registerConfigObservers() {
        for (engine, tag) in [(captureEngine, "capture"), (playbackEngine, "playback"),
                              (unifiedEngine, "unified")] {
            guard let engine else { continue }
            let o = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard Date() >= self.suppressConfigChangesUntil else {
                        self.suppressedConfigChanges += 1
                        return
                    }
                    self.log.log("引擎配置变化(\(tag)),重建管线")
                    self.scheduleRebuild("配置变化")
                }
            }
            configObservers.append(o)
        }
    }

    /// 防抖重建:设备事件常常成串到来,300ms 内合并为一次
    private func scheduleRebuild(_ reason: String) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.log.log("重建音频管线:\(reason)")
            self.restartCount += 1
            self.startPipeline()
        }
    }

    // MARK: - 设备事件

    private func handleDeviceEvent(_ selector: AudioObjectPropertySelector) {
        devices.refresh()
        refreshLists()
        updateBluetoothWarning()

        switch selector {
        case kAudioHardwarePropertyDevices:
            let missing = missingSelectedDevice()
            if isRunning, let missing {
                log.log("设备已拔出(\(missing)),暂停直通等待重连")
                errorMessage = "设备「\(missing)」已拔出,重新连接后将自动恢复。"
                pendingAutoResume = true
                stopPipeline()
            } else if pendingAutoResume, missing == nil, isEnabled {
                log.log("设备已重新连接,自动恢复直通")
                pendingAutoResume = false
                errorMessage = nil
                startPipeline()
            }
        case kAudioHardwarePropertyDefaultInputDevice:
            if isRunning && settings.inputUID.isEmpty { scheduleRebuild("默认输入设备变化") }
        case kAudioHardwarePropertyDefaultOutputDevice:
            if isRunning && settings.outputUID.isEmpty { scheduleRebuild("默认输出设备变化") }
        default:
            break
        }
    }

    /// 返回当前缺失的选定设备描述;无缺失返回 nil
    private func missingSelectedDevice() -> String? {
        if !settings.inputUID.isEmpty && devices.info(forUID: settings.inputUID) == nil {
            return "输入设备"
        }
        if !settings.outputUID.isEmpty && devices.info(forUID: settings.outputUID) == nil {
            return "输出设备"
        }
        return nil
    }

    private func refreshLists() {
        // 隐藏我们自己创建的聚合设备(直通内部实现细节,不应出现在可选列表)
        let visible = devices.devices.filter {
            !$0.uid.hasPrefix(CoreAudioUtil.aggregateUIDPrefix)
        }
        inputDevices = visible.filter { $0.hasInput }
        outputDevices = visible.filter { $0.hasOutput }
        defaultInputName = devices.info(forID: CoreAudioUtil.defaultDeviceID(input: true))?.name ?? "不可用"
        defaultOutputName = devices.info(forID: CoreAudioUtil.defaultDeviceID(input: false))?.name ?? "不可用"
    }

    /// 输入与输出是同一台蓝牙设备 → 提示(开麦克风会让耳机进入 HFP 通话模式)
    private func updateBluetoothWarning() {
        let inDev = resolvedInput()
        let outDev = resolvedOutput()
        showBluetoothWarning = inDev != nil && inDev == outDev && (inDev?.isBluetooth ?? false)
    }

    // MARK: - UI 定时刷新

    func refreshMeters() {
        let peak = Float(bitPattern: meter.inputPeakBits.load(ordering: .relaxed))
        inputLevel = max(peak, inputLevel * 0.8)  // UI 侧峰值保持衰减
        gateGain = Float(bitPattern: meter.gateGainBits.load(ordering: .relaxed))
        feedbackGain = Float(bitPattern: meter.feedbackGainBits.load(ordering: .relaxed))
        bufferedMS = Double(meter.bufferedFrames.load(ordering: .relaxed)) / sampleRate * 1000
        if let ring {
            underrunCount = accUnderrun + ring.underrunEvents.load(ordering: .relaxed)
            overflowCount = accOverflow + ring.overflowEvents.load(ordering: .relaxed)
        }
    }

    private func pushGain() {
        meter.targetGainBits.store((muted ? 0 : volume).bitPattern, ordering: .relaxed)
    }
    private func pushThreshold() {
        let linear = Float(pow(10.0, Double(gateThresholdDB) / 20.0))
        meter.gateThresholdBits.store(linear.bitPattern, ordering: .relaxed)
    }

    // MARK: - 权限 / 自启 / 菜单动作

    private func refreshPermission() {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        micPermissionDenied = (s == .denied || s == .restricted)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                SMAppService.mainApp.unregister { err in
                    if let err { AppLogger.shared.log("取消开机自启失败:\(err.localizedDescription)") }
                }
            }
        } catch {
            errorMessage = "开机自启设置失败:\(error.localizedDescription)"
            log.log("SMAppService 失败:\(error.localizedDescription)")
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.refreshLaunchStatus()
        }
    }

    private func refreshLaunchStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        launchNeedsApproval = (status == .requiresApproval)
    }

    func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLogs() {
        NSWorkspace.shared.open(log.directoryURL)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }

    func quit() {
        stopPipeline()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 诊断信息

    private func permissionString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }

    private func diagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var u = utsname()
        uname(&u)
        let arch = withUnsafeBytes(of: &u.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        var lines: [String] = []
        lines.append("MicMonitor \(version) (build \(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(arch)")
        lines.append("麦克风权限:\(permissionString())")
        lines.append("状态:期望\(isEnabled ? "开" : "关") / 运行\(isRunning ? "中" : "停止")"
            + "\(pendingAutoResume ? " / 等待设备重连" : "")")
        lines.append("输入:\(settings.inputUID.isEmpty ? "系统默认(\(defaultInputName))" : settings.inputUID)")
        lines.append("输出:\(settings.outputUID.isEmpty ? "系统默认(\(defaultOutputName))" : settings.outputUID)")
        lines.append(String(format: "音量 %d%% 静音:%@ 噪声门:%@ 阈值 %.0fdB 低延迟:%@",
                            Int(volume * 100), muted.description,
                            gateEnabled.description, gateThresholdDB, lowLatency.description))
        lines.append(String(format: "啸叫守护增益 %d%% 自适应缓冲倍数 ×%.1f",
                            Int(feedbackGain * 100), bufferScale))
        lines.append(String(format: "输出 %.0fHz × %dch 缓冲 %.1fms",
                            sampleRate, outputChannelCount, bufferedMS))
        lines.append("欠载 \(underrunCount) 次 · 溢出丢弃 \(overflowCount) 次 · 重建 \(restartCount) 次"
            + " · 转换错误 \(meter.convertErrors.load(ordering: .relaxed)) 次"
            + " · 抑制配置通知 \(suppressedConfigChanges) 次")
        lines.append("设备列表:")
        for d in devices.devices {
            lines.append("  \(d.name) | uid=\(d.uid) | in \(d.inputChannels)ch out \(d.outputChannels)ch"
                + " | \(Int(d.nominalSampleRate))Hz | \(d.transportName)")
        }
        lines.append("最近日志:")
        lines.append(contentsOf: log.recentLines)
        return lines.joined(separator: "\n")
    }
}

private enum PipelineError: LocalizedError {
    case os(String, OSStatus)
    case format
    var errorDescription: String? {
        switch self {
        case .os(let what, let status): return "\(what)(OSStatus \(status))"
        case .format: return "创建音频格式失败"
        }
    }
}
