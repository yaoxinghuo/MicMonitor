import Foundation

/// 播放端渲染链路的 DSP:音量增益(线性斜坡防爆音)→ 噪声门 → 软限幅。
/// 纯内部状态 + 计算,无外部依赖,可单元测试。
/// 在实时渲染线程运行:不分配、不加锁、不打日志。
/// 输入为 planar 布局(每声道一段连续样本)。
final class DSPEngine: @unchecked Sendable {

    // ---- 音量 ----
    private(set) var volumeTarget: Float = 1.0
    private(set) var volumeCurrent: Float = 1.0
    private var rampStep: Float = 0        // 每帧线性步进量
    private var rampRemaining: Int = 0

    // ---- 噪声门 ----
    var gateEnabled = false
    var gateThreshold: Float = 0           // 线性幅度阈值(0~1)
    private(set) var gateGain: Float = 1   // 0 = 关闭,1 = 全开(平滑过渡)
    private var gateAttackCoeff: Float = 0
    private var gateReleaseCoeff: Float = 0
    private var envDecayCoeff: Float = 0
    private var envelope: Float = 0        // 峰值包络(瞬时上升、缓慢衰减)

    // ---- 人声突显(VAD ducking) ----
    // 与噪声门互补:噪声门按"电平高低"开关,人声突显按"是否语音"衰减。
    // active 由 VoiceFocusAnalyzer(SoundAnalysis 分类器)异步写入;
    // 有语音 → 增益回到 1(快攻 ~150ms,保证话头不被切),无语音 → 压到 voiceDuck(慢释 ~600ms 平滑)
    var voiceFocusEnabled = false
    var voiceSpeechActive = false
    var voiceDuck: Float = 0.08              // 非人声目标增益(用户可调,默认 ≈ -22dB)
    private(set) var voiceGain: Float = 1
    private var voiceAttackCoeff: Float = 0
    private var voiceReleaseCoeff: Float = 0

    // ---- 电平(只读,供 UI 电平表)----
    private(set) var inputPeak: Float = 0
    private(set) var outputPeak: Float = 0

    // ---- 啸叫守护(feedback governor) ----
    // 麦克风离输出设备太近(典型如耳机线控麦克风紧贴发声单元)会形成声学/电气反馈环:
    // 增益在环路里不断放大 → 顶到软限幅 → 能量跌落 → 再爬升,听起来像"嘟嘟嘟"的拖拉机声。
    // 这与延迟/缓冲无关,必须单独检测并自动压低增益打断环路,原理类似专业音响的 howling suppression。
    // 判据:输出端包络持续贴着限幅拐点(说明环路能量在爆发式增长),
    // 用快起慢落的包络跟踪,一旦判定正在啸叫就快速把 feedbackGain 打下去,环路增益低于 1 后振荡自然停止;
    // 安静下来后再缓慢(几秒)恢复到 1,避免反复开关导致新的"嘟嘟"。
    private(set) var feedbackGain: Float = 1
    /// 块级平滑包络(不是逐样本):需要连续若干块维持高电平才会触发,
    /// 避免拍手/关门这类瞬态响动被误判成啸叫。
    private var feedbackEnvelope: Float = 0
    private let feedbackEnvCoeff: Float = 0.25    // 包络跟踪速度:约几十毫秒达到稳态
    private let feedbackThreshold: Float = 0.75   // 略低于 softClip 拐点(0.8),提前介入
    private let feedbackDuckStep: Float = 0.3     // 判定啸叫时,每块把增益再砍掉的比例(快速压下)
    private let feedbackRecoverStep: Float = 0.01 // 未判定啸叫时,每块缓慢恢复的量(约 2~3 秒恢复到 1)

    /// 逐帧总增益系数暂存(音量 × 门开合度),init 预分配;超过则分块处理
    private let gainScratch: UnsafeMutableBufferPointer<Float>

    init(gainScratchFrames: Int = 8192) {
        gainScratch = .allocate(capacity: gainScratchFrames)
        gainScratch.initialize(repeating: 1)
    }

    deinit { gainScratch.deallocate() }

    /// 设置目标音量(0~2,超过 1 的部分靠软限幅防爆音)。
    /// 增益按线性斜坡在 rampFrames 帧内平滑到位。
    func setVolume(_ target: Float, rampFrames: Int) {
        let t = min(max(target, 0), 2)
        guard t != volumeTarget else { return }
        volumeTarget = t
        rampRemaining = max(1, rampFrames)
        rampStep = (t - volumeCurrent) / Float(rampRemaining)
    }

    /// 更新噪声门参数。attack/release/envDecay 为时间常数(秒)。
    /// 每个块调用一次代价极低;系数重复计算无副作用。
    func updateGate(enabled: Bool, threshold: Float, sampleRate: Double,
                    attackSec: Float = 0.010, releaseSec: Float = 0.400,
                    envDecaySec: Float = 0.150) {
        gateEnabled = enabled
        gateThreshold = threshold
        let sr = Float(max(sampleRate, 1))
        gateAttackCoeff = 1 - expf(-1 / (attackSec * sr))
        gateReleaseCoeff = 1 - expf(-1 / (releaseSec * sr))
        envDecayCoeff = expf(-1 / (envDecaySec * sr))
    }

    /// 更新人声突显参数。active 为分类器当前帧判定;平滑系数每块重算代价极低。
    func updateVoiceFocus(enabled: Bool, active: Bool, duckGain: Float, sampleRate: Double,
                          attackSec: Float = 0.150, releaseSec: Float = 0.600) {
        voiceFocusEnabled = enabled
        voiceSpeechActive = active
        voiceDuck = min(max(duckGain, 0), 1)
        let sr = Float(max(sampleRate, 1))
        voiceAttackCoeff = 1 - expf(-1 / (attackSec * sr))
        voiceReleaseCoeff = 1 - expf(-1 / (releaseSec * sr))
    }

    /// 就地处理一块 planar 音频(dsts[c] 为第 c 声道的缓冲)。返回本块输入峰值。
    /// 两遍处理:先逐帧算出总增益(音量斜坡 × 门开合度),再逐声道施加并限幅。
    @discardableResult
    func process(_ dsts: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
                 frames: Int, channels: Int) -> Float {
        var inPeak: Float = 0
        var outPeak: Float = 0
        var f = 0
        while f < frames {
            let n = min(frames - f, gainScratch.count)
            // 第一遍:逐帧计算峰值包络、门开合度、音量斜坡 → 总增益
            for i in 0..<n {
                let fi = f + i
                var framePeak: Float = 0
                for c in 0..<channels {
                    let v = dsts[c][fi]
                    let a = v < 0 ? -v : v
                    if a > framePeak { framePeak = a }
                }
                if framePeak > inPeak { inPeak = framePeak }

                envelope = framePeak > envelope ? framePeak : envelope * envDecayCoeff

                let target: Float = (!gateEnabled || envelope >= gateThreshold) ? 1 : 0
                let coeff = target > gateGain ? gateAttackCoeff : gateReleaseCoeff
                gateGain += (target - gateGain) * coeff

                let vTarget: Float = (!voiceFocusEnabled || voiceSpeechActive) ? 1 : voiceDuck
                let vcoeff = vTarget > voiceGain ? voiceAttackCoeff : voiceReleaseCoeff
                voiceGain += (vTarget - voiceGain) * vcoeff

                if rampRemaining > 0 {
                    volumeCurrent += rampStep
                    rampRemaining -= 1
                    if rampRemaining == 0 { volumeCurrent = volumeTarget }
                }
                gainScratch[i] = volumeCurrent * gateGain * feedbackGain * voiceGain
            }
            // 第二遍:逐声道应用增益 + 软限幅
            for c in 0..<channels {
                let p = dsts[c]
                for i in 0..<n {
                    let y = softClip(p[f + i] * gainScratch[i])
                    p[f + i] = y
                    let a = y < 0 ? -y : y
                    if a > outPeak { outPeak = a }
                }
            }
            f += n
        }
        inputPeak = inPeak
        outputPeak = outPeak

        // 啸叫守护:块级更新,一个 process() 调用(通常就是一个渲染块)更新一次
        feedbackEnvelope += (outPeak - feedbackEnvelope) * feedbackEnvCoeff
        if feedbackEnvelope > feedbackThreshold {
            feedbackGain = max(0.05, feedbackGain * (1 - feedbackDuckStep))
        } else {
            feedbackGain = min(1, feedbackGain + feedbackRecoverStep)
        }
        return inPeak
    }

    /// 复位(引擎重启时调用;音量直接落到目标值,避免重启后再斜坡)
    func reset() {
        volumeCurrent = volumeTarget
        rampRemaining = 0
        gateGain = 1
        envelope = 0
        voiceGain = 1
        inputPeak = 0
        outputPeak = 0
        feedbackGain = 1
        feedbackEnvelope = 0
    }
}

/// 软限幅:|x| ≤ 0.8 原样通过;超过后按 tanh 饱和曲线逼近 ±1。
/// 连接处导数连续(斜率均为 1),不会在交界产生额外失真。
@inline(__always)
func softClip(_ x: Float) -> Float {
    let knee: Float = 0.8
    let a = x < 0 ? -x : x
    if a <= knee { return x }
    let s = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
    return x < 0 ? -s : s
}
