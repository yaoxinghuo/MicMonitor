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

/// 音频管线的跨线程共享状态:全部是原子量,实时音频线程与 UI 线程都可安全访问。
final class MeterState: @unchecked Sendable {
    let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)    // 目标音量 0~2(已含静音)
    let gateEnabled = Atomic<Int>(0)
    let gateThresholdBits = Atomic<UInt32>(Float(0).bitPattern) // 线性幅度阈值
    let inputPeakBits = Atomic<UInt32>(Float(0).bitPattern)     // 采集端输入峰值
    let gateGainBits = Atomic<UInt32>(Float(1).bitPattern)      // 噪声门开合度
    let bufferedFrames = Atomic<Int>(0)                       // 播放端环形缓冲水位
    let convertErrors = Atomic<Int>(0)
}

/// 采集端上下文(tap 回调专用)。
/// ⚠️ 回调跑在实时线程:禁止分配/锁/日志。converter 重建只在输入格式变化时发生(罕见)。
final class CaptureContext: @unchecked Sendable {
    let ring: RingBuffer
    let shared: MeterState
    let canonicalFormat: AVAudioFormat   // 交错 Float32,播放端采样率与声道数
    let prefillFrames: Int
    var converter: AVAudioConverter?
    var inSampleRate: Double = 0
    var inChannels: UInt32 = 0
    var outBuffer: AVAudioPCMBuffer?

    init(ring: RingBuffer, shared: MeterState, canonicalFormat: AVAudioFormat, prefillFrames: Int) {
        self.ring = ring
        self.shared = shared
        self.canonicalFormat = canonicalFormat
        self.prefillFrames = prefillFrames
    }
}

/// 播放端上下文(渲染回调专用,同样的实时约束)。
final class RenderContext: @unchecked Sendable {
    let ring: RingBuffer
    let shared: MeterState
    let dsp = DSPEngine()
    let channelCount: Int
    let sampleRate: Double
    let scratchFrames = 4096
    let scratch: UnsafeMutableBufferPointer<Float>  // 非交错布局兜底暂存

    init(ring: RingBuffer, shared: MeterState, channelCount: Int, sampleRate: Double) {
        self.ring = ring
        self.shared = shared
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        scratch = .allocate(capacity: scratchFrames * channelCount)
        scratch.initialize(repeating: 0)
    }

    deinit { scratch.deallocate() }
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
            if isRunning { scheduleRebuild("切换输入设备") }
        }
    }
    @Published var selectedOutputUID = "" {
        didSet {
            guard oldValue != selectedOutputUID else { return }
            settings.outputUID = selectedOutputUID
            updateBluetoothWarning()
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

    /// 面板副标题:期望开启但未在运行时的说明
    var pendingResumeText: String? {
        guard isEnabled, !isRunning else { return nil }
        if pendingAutoResume { return "等待设备重新连接…" }
        return errorMessage == nil ? "启动中…" : nil
    }

    // 电平/状态(UI 定时刷新)
    @Published var inputLevel: Float = 0
    @Published var gateGain: Float = 1
    @Published var bufferedMS: Double = 0
    @Published var underrunCount = 0
    @Published var overflowCount = 0
    @Published var restartCount = 0

    // MARK: - 内部
    private let settings = Settings.shared
    private let log = AppLogger.shared
    private let devices = AudioDeviceManager()
    private let meter = MeterState()

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var ring: RingBuffer?
    private var canonicalFormat: AVAudioFormat?
    private var configObservers: [NSObjectProtocol] = []

    private var pendingAutoResume = false
    private var rebuildTask: Task<Void, Never>?
    private var sampleRate = 48000.0
    private var outputChannelCount = 2
    // ring 随引擎重建,旧计数在这里累计
    private var accUnderrun = 0
    private var accOverflow = 0

    init() {
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
            Task { await requestPermissionAndStart() }
        } else {
            isEnabled = false
            pendingAutoResume = false
            settings.wasRunning = false
            stopPipeline()
            errorMessage = nil
        }
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
            try buildPlaybackEngine(output: outDev)
            try buildCaptureEngine(input: inDev)
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
            + " 输出 \(Int(sampleRate))Hz × \(outputChannelCount)ch,目标水位 \(ring?.targetWater ?? 0) 帧")
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

        let sr = (output?.nominalSampleRate ?? 0) > 0 ? output!.nominalSampleRate : 48000
        let ch = max(1, min(8, output?.outputChannels ?? 2))
        guard let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                            channels: AVAudioChannelCount(ch), interleaved: true) else {
            throw PipelineError.format
        }
        sampleRate = sr
        outputChannelCount = ch
        canonicalFormat = canonical

        // 环形缓冲:容量 ~0.4s;目标水位 ≈ 2.5 个 512 帧块(~26ms@48k),高水位 6 块
        let ringBuf = RingBuffer(capacityFrames: max(Int(sr * 0.4), 8192), channelCount: ch,
                                 targetWater: 1280, highWater: 3072)
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

        let ctx = CaptureContext(ring: ring, shared: meter, canonicalFormat: canonical,
                                 prefillFrames: ring.targetWater)
        // format: nil → 使用设备原生输入格式,在回调内做格式转换
        inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
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
        let outChannels = Int(ctx.canonicalFormat.channelCount)
        for b in UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList) {
            guard let data = b.mData else { continue }
            let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let src = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            ctx.ring.write(src, frameCount: count / outChannels)
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
        if list.count == 1, let data = list[0].mData {
            // 交错布局(canonical 格式):一块内存包含全部声道
            let dst = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                 count: frameCount * ctx.channelCount)
            gotAny = ctx.ring.read(dst, frameCount: frameCount) > 0
            ctx.dsp.process(dst, frames: frameCount, channels: ctx.channelCount)
        } else if list.count == ctx.channelCount {
            // 非交错兜底:逐块读到 scratch,DSP 后按声道拆分
            var f = 0
            while f < frameCount {
                let chunk = min(frameCount - f, ctx.scratchFrames)
                let scratch = UnsafeMutableBufferPointer(start: ctx.scratch.baseAddress,
                                                         count: chunk * ctx.channelCount)
                if ctx.ring.read(scratch, frameCount: chunk) > 0 { gotAny = true }
                ctx.dsp.process(scratch, frames: chunk, channels: ctx.channelCount)
                for (ch, b) in list.enumerated() where ch < ctx.channelCount {
                    guard let data = b.mData else { continue }
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<chunk { p[f + i] = scratch[i * ctx.channelCount + ch] }
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

        accumulateCounters()
        if let cap = captureEngine {
            cap.inputNode.removeTap(onBus: 0)
            cap.stop()
        }
        playbackEngine?.stop()
        captureEngine = nil
        playbackEngine = nil
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
        for (engine, tag) in [(captureEngine, "capture"), (playbackEngine, "playback")] {
            guard let engine else { continue }
            let o = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.log.log("引擎配置变化(\(tag)),重建管线")
                    self?.scheduleRebuild("配置变化")
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
        inputDevices = devices.devices.filter { $0.hasInput }
        outputDevices = devices.devices.filter { $0.hasOutput }
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
        lines.append(String(format: "音量 %d%% 静音:%@ 噪声门:%@ 阈值 %.0fdB",
                            Int(volume * 100), muted.description,
                            gateEnabled.description, gateThresholdDB))
        lines.append(String(format: "输出 %.0fHz × %dch 缓冲 %.1fms",
                            sampleRate, outputChannelCount, bufferedMS))
        lines.append("欠载 \(underrunCount) 次 · 溢出丢弃 \(overflowCount) 次 · 重建 \(restartCount) 次"
            + " · 转换错误 \(meter.convertErrors.load(ordering: .relaxed)) 次")
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
