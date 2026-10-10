import Testing
@testable import MicMonitor

struct DSPTests {

    private func process(_ dsp: DSPEngine, _ data: inout [Float], channels: Int = 1) {
        _ = data.withUnsafeMutableBufferPointer {
            dsp.process($0, frames: $0.count / channels, channels: channels)
        }
    }

    @Test func unityGainPassthrough() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        var data: [Float] = [0.1, -0.3, 0.5, -0.7]
        process(dsp, &data)
        #expect(data == [0.1, -0.3, 0.5, -0.7])   // |x|≤0.8 时软限幅不动作
    }

    @Test func gainRampIsSmooth() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 128)
        var data = [Float](repeating: 0.3, count: 256) // 0.3 < 0.8,限幅不影响
        process(dsp, &data)
        #expect(data[0] > 0.29 && data[0] < 0.4)       // 斜坡起点附近
        #expect(abs(data[255] - 0.6) < 0.001)          // 斜坡结束后 = 0.3 × 2
        for i in 1..<128 { #expect(data[i] >= data[i - 1]) } // 单调上升、无爆音
    }

    @Test func mute() {
        let dsp = DSPEngine()
        dsp.setVolume(0, rampFrames: 8)
        var data = [Float](repeating: 0.5, count: 64)
        process(dsp, &data)
        #expect(abs(data[63]) < 1e-6)
    }

    @Test func softClipNeverExceedsOne() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0, sampleRate: 48000)
        dsp.setVolume(2, rampFrames: 1)
        var data: [Float] = [0.9, -0.9, 0.6, -0.6, 1.0, -1.0]
        process(dsp, &data)
        for v in data { #expect(abs(v) <= 1.0) }
        // 0.9 × 2 = 1.8 → 软限幅后应接近 1 但不到 1
        #expect(data[0] > 0.8 && data[0] < 1.0)
    }

    @Test func gateBlocksQuietSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var data = [Float](repeating: 0.01, count: 96000) // 2s,gateGain 衰到 ~0.7% 以下
        process(dsp, &data)
        #expect((data.suffix(480).max() ?? 0) < 1e-4)
    }

    @Test func gateOpensOnLoudSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var quiet = [Float](repeating: 0.01, count: 48000) // 先让门关到底
        process(dsp, &quiet)
        var loud = [Float](repeating: 0.9, count: 4800)   // 100ms,attack 10ms 内应开
        process(dsp, &loud)
        #expect(dsp.gateGain > 0.9)
        #expect(abs(loud[4799] - 0.9) < 0.15)             // 全开时近似原样
    }

    @Test func gateDisabledPassesQuietSignal() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: false, threshold: 0.9, sampleRate: 48000)
        var data = [Float](repeating: 0.01, count: 1024)
        process(dsp, &data)
        #expect(abs(data[0] - 0.01) < 1e-5)
        #expect(abs(data[1023] - 0.01) < 1e-5)
    }

    @Test func gateRejectsBelowThresholdAfterRelease() {
        let dsp = DSPEngine()
        dsp.updateGate(enabled: true, threshold: 0.5, sampleRate: 48000)
        var data = [Float](repeating: 0.2, count: 96000) // 2s 低于阈值
        process(dsp, &data)
        #expect(dsp.gateGain < 0.01)
    }
}
