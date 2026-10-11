import AVFoundation
import Foundation
import SoundAnalysis
import Synchronization

/// 人声突显:用系统内置声音分类器(SoundAnalysis,离线 ML)实时判断采集缓冲里有没有语音,
/// 结果写入原子量供实时渲染线程读取——检测到语音正常放行,检测不到时由 DSP 侧做 ducking。
/// 官方用法即是在 installTap 回调里直接调 analyze();每次回调只做一次拷贝式投递,
/// 结果(若有)在同一调用线程同步分发给观察者,我们只做 O(类别数) 的字符串比较 + 原子写。
final class VoiceFocusAnalyzer: NSObject, SNResultsObserving, @unchecked Sendable {

    private let analyzer: SNAudioStreamAnalyzer
    private var framePos: AVAudioFramePosition = 0
    /// 最近一次判定为语音的时刻;结果间隔 ~0.75s(1.5s 窗 × 0.5 overlap),
    /// 加 1.2s 保持窗吸收句中停顿,避免逐词抖动
    private var lastSpeechAt = Date.distantPast
    private let speechHoldSec: TimeInterval = 1.2
    /// 共享状态引用:灵敏度阈值在其原子量里,UI 滑杆改动实时生效
    private let shared: MeterState

    init(format: AVAudioFormat, shared: MeterState) throws {
        self.shared = shared
        analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5
        super.init()
        try analyzer.add(request, withObserver: self)
    }

    /// 采集 tap 回调内调用:把本块缓冲喂给流式分类器。
    /// ⚠️ 实时线程:仅一次浅拷贝投递 + 偶发的同步结果回调,无可测延迟开销。
    func feed(_ buffer: AVAudioPCMBuffer) {
        analyzer.analyze(buffer, atAudioFramePosition: framePos)
        framePos += AVAudioFramePosition(buffer.frameLength)
    }

    // MARK: - SNResultsObserving

    /// version1 内置分类器输出 snake_case 标识(实测如 "male_speech"、"bird_chirp_tweet"),
    /// 与"人声"相关的标签集合(多标签,各自独立置信度)
    private func isSpeechLabel(_ id: String) -> Bool {
        id.contains("speech") || id == "conversation" || id.contains("narration")
            || id.contains("dialogue") || id == "babbling"
            || id.hasPrefix("shout") || id.hasPrefix("scream") || id == "whispering"
            || id == "yell" || id.hasPrefix("bellow") || id == "whoop"
            || id.hasPrefix("baby_cry") || id.hasPrefix("children_shouting")
            || id.hasPrefix("singing") || id == "humming" || id.hasPrefix("yodel")
            || id.hasPrefix("chant") || id == "mantra" || id == "choir"
            || id.contains("laugh") || id.hasPrefix("giggle") || id.hasPrefix("snicker")
            || id.hasPrefix("chuckle") || id == "groan" || id == "grunt"
            || id == "whimper" || id.hasPrefix("wail") || id == "sigh"
            || id == "crying_sobbing"
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        var speech = 0.0
        for c in r.classifications where isSpeechLabel(c.identifier) {
            speech += c.confidence
        }
        let now = Date()
        let threshold = Double(Float(bitPattern: shared.voiceFocusThreshBits.load(ordering: .relaxed)))
        if speech >= threshold { lastSpeechAt = now }
        shared.voiceSpeechActive.store(
            now.timeIntervalSince(lastSpeechAt) < speechHoldSec ? 1 : 0, ordering: .relaxed)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // 分类器出错时保守起见放行全部声音(等效关闭),而不是把人声也压掉
        shared.voiceSpeechActive.store(1, ordering: .relaxed)
    }
}
