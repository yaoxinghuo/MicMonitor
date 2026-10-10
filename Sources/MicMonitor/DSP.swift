import Foundation

/// 播放端渲染链路的 DSP:音量增益(线性斜坡防爆音)→ 噪声门 → 软限幅。
/// 纯内部状态 + 计算,无外部依赖,可单元测试。
/// 在实时渲染线程运行:不分配、不加锁、不打日志。
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

    // ---- 电平(只读,供 UI 电平表)----
    private(set) var inputPeak: Float = 0
    private(set) var outputPeak: Float = 0

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

    /// 就地处理一块交错格式音频。返回本块输入峰值(门限之前,供阈值调试)。
    @discardableResult
    func process(_ buffer: UnsafeMutableBufferPointer<Float>, frames: Int, channels: Int) -> Float {
        var inPeak: Float = 0
        var outPeak: Float = 0
        for f in 0..<frames {
            let base = f * channels

            // 帧内峰值(跨声道取最大):包络输入 + 电平表
            var framePeak: Float = 0
            for c in 0..<channels {
                let v = buffer[base + c]
                let a = v < 0 ? -v : v
                if a > framePeak { framePeak = a }
            }
            if framePeak > inPeak { inPeak = framePeak }

            envelope = framePeak > envelope ? framePeak : envelope * envDecayCoeff

            // 噪声门开合度:开 → attack(快),关 → release(慢),避免门开关产生爆音
            let target: Float = (!gateEnabled || envelope >= gateThreshold) ? 1 : 0
            let coeff = target > gateGain ? gateAttackCoeff : gateReleaseCoeff
            gateGain += (target - gateGain) * coeff

            // 音量线性斜坡
            if rampRemaining > 0 {
                volumeCurrent += rampStep
                rampRemaining -= 1
                if rampRemaining == 0 { volumeCurrent = volumeTarget }
            }
            let gain = volumeCurrent * gateGain

            for c in 0..<channels {
                let y = softClip(buffer[base + c] * gain)
                buffer[base + c] = y
                let a = y < 0 ? -y : y
                if a > outPeak { outPeak = a }
            }
        }
        inputPeak = inPeak
        outputPeak = outPeak
        return inPeak
    }

    /// 复位(引擎重启时调用;音量直接落到目标值,避免重启后再斜坡)
    func reset() {
        volumeCurrent = volumeTarget
        rampRemaining = 0
        gateGain = 1
        envelope = 0
        inputPeak = 0
        outputPeak = 0
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
