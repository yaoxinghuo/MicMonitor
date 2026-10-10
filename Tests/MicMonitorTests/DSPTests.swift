import Testing
@testable import MicMonitor

struct DSPTests {

    /// 就地处理 planar 数据(chans[c] 为第 c 声道的样本)
    private func process(_ dsp: DSPEngine, _ chans: inout [[Float]]) {
        let n = chans[0].count
        let ptrs = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>.allocate(capacity: chans.count)
        var keeps: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            for p in keeps { p.deallocate() }
            ptrs.deallocate()
        }
        for (i, ch) in chans.enumerated() {
            let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
            _ = p.initialize(from: ch)
            keeps.append(p)
            ptrs[i] = p.baseAddress!
        }
        dsp.process(UnsafeBufferPointer(ptrs), frames: n, channels: chans.count)
        for (i, p) in keeps.enumerated() { chans[i] = Array(p) }
    }

    @Test func unityGainPassthrough() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        var data = [[0.1, -0.3, 0.5, -0.7] as [Float]]
        process(dsp, &data)
        #expect(data[0] == [0.1, -0.3, 0.5, -0.7])   // |x|≤0.8 时软限幅不动作
    }

    @Test func stereoChannelsShareSameGain() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 1)
        var data: [[Float]] = [[0.2, 0.2], [0.4, 0.4]]
        process(dsp, &data)
        #expect(data[0] == [0.4, 0.4])
        #expect(data[1] == [0.8, 0.8])   // 0.4×2=0.8,正好在限幅拐点内
    }

    @Test func gainRampIsSmooth() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 128)
        var data = [[Float](repeating: 0.3, count: 256)] // 0.3 < 0.8,限幅不影响
        process(dsp, &data)
        #expect(data[0][0] > 0.29 && data[0][0] < 0.4)       // 斜坡起点附近
        #expect(abs(data[0][255] - 0.6) < 0.001)             // 斜坡结束后 = 0.3 × 2
        for i in 1..<128 { #expect(data[0][i] >= data[0][i - 1]) } // 单调上升、无爆音
    }

    @Test func mute() {
        let dsp = DSPEngine()
        dsp.setVolume(0, rampFrames: 8)
        var data = [[Float](repeating: 0.5, count: 64)]
        process(dsp, &data)
        #expect(abs(data[0][63]) < 1e-6)
    }

    @Test func softClipNeverExceedsOne() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 1)
        var data = [[0.9, -0.9, 0.6, -0.6, 1.0, -1.0] as [Float]]
        process(dsp, &data)
        for v in data[0] { #expect(abs(v) <= 1.0) }
        // 0.9 × 2 = 1.8 → 软限幅后应接近 1 但不到 1
        #expect(data[0][0] > 0.8 && data[0][0] < 1.0)
    }

    @Test func gateBlocksQuietSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var data = [[Float](repeating: 0.01, count: 96000)] // 2s,gateGain 衰到 ~0.7% 以下
        process(dsp, &data)
        #expect((data[0].suffix(480).max() ?? 0) < 1e-4)
    }

    @Test func gateOpensOnLoudSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var quiet = [[Float](repeating: 0.01, count: 48000)] // 先让门关到底
        process(dsp, &quiet)
        var loud = [[Float](repeating: 0.9, count: 4800)]   // 100ms,attack 10ms 内应开
        process(dsp, &loud)
        #expect(dsp.gateGain > 0.9)
        #expect(abs(loud[0][4799] - 0.9) < 0.15)            // 全开时近似原样
    }

    @Test func gateDisabledPassesQuietSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0.9, sampleRate: 48000)
        var data = [[Float](repeating: 0.01, count: 1024)]
        process(dsp, &data)
        #expect(abs(data[0][0] - 0.01) < 1e-5)
        #expect(abs(data[0][1023] - 0.01) < 1e-5)
    }

    @Test func gateRejectsBelowThresholdAfterRelease() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var data = [[Float](repeating: 0.2, count: 96000)] // 2s 低于阈值
        process(dsp, &data)
        #expect(dsp.gateGain < 0.01)
    }

    /// 持续顶满(模拟啸叫/反馈环路)应被自动压低增益,避免"嘟嘟嘟"反复削顶
    @Test func feedbackGovernorDucksSustainedClipping() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 1)
        // 分多个小块喂入持续满幅信号,模拟渲染回调逐块调用(每块触发一次守护更新)
        var peakAfterDuck: Float = 1
        for _ in 0..<40 {
            var block = [[Float](repeating: 0.95, count: 256)]
            process(dsp, &block)
            peakAfterDuck = block[0].map { abs($0) }.max() ?? 1
        }
        #expect(dsp.feedbackGain < 0.5)
        // 守护是闭环调节,稳态会在阈值附近"找平衡"(类似限幅器 hunting),
        // 不追求打到很低,只要求明显低于未受控时的满幅限幅输出(~0.999)
        #expect(peakAfterDuck < 0.85)
    }

    /// 单次瞬态响动(如拍手)不应触发守护,避免误伤正常大声说话
    @Test func feedbackGovernorIgnoresSingleTransient() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        var loud = [[Float](repeating: 0.9, count: 64)]   // 一个很短的块
        process(dsp, &loud)
        #expect(dsp.feedbackGain > 0.9)
    }

    /// 停止持续顶满后,守护增益应缓慢恢复到 1
    @Test func feedbackGovernorRecovers() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 1)
        for _ in 0..<40 {
            var block = [[Float](repeating: 0.95, count: 256)]
            process(dsp, &block)
        }
        #expect(dsp.feedbackGain < 0.5)
        dsp.setVolume(0.1, rampFrames: 1)   // 回到安全音量,不再顶限幅
        for _ in 0..<300 {
            var block = [[Float](repeating: 0.1, count: 256)]
            process(dsp, &block)
        }
        #expect(dsp.feedbackGain > 0.9)
    }
}
