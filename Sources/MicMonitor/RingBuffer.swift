import Foundation
import Synchronization

/// 单生产者-单消费者(SPSC)无锁环形缓冲区,数据按帧交错存放(Float × 声道数)。
///
/// - 生产者:采集端 tap 回调(实时音频线程)
/// - 消费者:播放端渲染回调(实时音频线程)
///
/// writePos 只由生产者写、readPos 只由消费者写,两侧都通过原子操作读取对方的索引,
/// 借助 acquire/release 顺序保证数据可见性。溢出"丢弃旧数据"的请求经 dropRequest
/// 原子量转交给消费者执行,从而维持单侧写索引的纪律。
///
/// ⚠️ 本类所有方法都可能在实时音频线程执行:禁止分配内存、加锁、打日志。
final class RingBuffer: @unchecked Sendable {
    /// 缓冲区容量(帧)
    let capacityFrames: Int
    /// 声道数
    let channelCount: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    private let writePos = Atomic<Int>(0)   // 单调递增写位置(帧),仅生产者写
    private let readPos = Atomic<Int>(0)    // 单调递增读位置(帧),仅消费者写
    /// 生产者 → 消费者:请求丢弃最旧数据的帧数,由消费者在下次读取时生效
    private let dropRequest = Atomic<Int>(0)

    /// 目标水位(帧):约 2~3 个缓冲块,决定整体延迟
    let targetWater: Int
    /// 高水位(帧):超过即请求消费端丢弃多余数据
    let highWater: Int

    // ---- 统计计数(诊断用,两侧线程都可能更新)----
    let overflowFrames = Atomic<Int>(0)   // 因溢出/水位控制丢弃的帧数
    let overflowEvents = Atomic<Int>(0)   // 溢出事件次数
    let underrunFrames = Atomic<Int>(0)   // 欠载补静音的帧数
    let underrunEvents = Atomic<Int>(0)   // 整块完全无数据可给的次数

    init(capacityFrames: Int, channelCount: Int, targetWater: Int = 1280, highWater: Int = 3072) {
        self.capacityFrames = max(64, capacityFrames)
        self.channelCount = max(1, channelCount)
        self.targetWater = max(0, min(targetWater, self.capacityFrames / 2))
        self.highWater = max(self.targetWater, min(highWater, self.capacityFrames))
        storage = .allocate(capacity: self.capacityFrames * self.channelCount)
        storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    /// 当前可读帧数(近似值,两侧线程均可查询)
    var availableFrames: Int {
        writePos.load(ordering: .acquiring) - readPos.load(ordering: .acquiring)
    }

    // MARK: - 生产者(采集 tap 线程)

    /// 写入交错格式样本。空间不足时丢弃写不下的尾部;写入后水位超过 highWater
    /// 时请求消费端丢弃最旧数据,把延迟拉回 targetWater。
    /// - Returns: 实际写入的帧数
    @discardableResult
    func write(_ src: UnsafeBufferPointer<Float>, frameCount: Int) -> Int {
        let w = writePos.load(ordering: .relaxed)
        let r = readPos.load(ordering: .acquiring)
        let pending = dropRequest.load(ordering: .relaxed)
        let space = capacityFrames - (w - r)
        guard space > 0 else {
            overflowFrames.add(frameCount, ordering: .relaxed)
            overflowEvents.add(1, ordering: .relaxed)
            return 0
        }
        let n = min(frameCount, space)

        // 水位控制:availAfter 减去 pending(那部分即将被消费端丢弃,不应计入)
        let availAfter = (w - r) - pending + n
        if availAfter > highWater {
            let excess = availAfter - targetWater
            dropRequest.add(excess, ordering: .relaxed)
            overflowFrames.add(excess, ordering: .relaxed)
            overflowEvents.add(1, ordering: .relaxed)
        }

        var written = 0
        while written < n {
            let frameIndex = (w + written) % capacityFrames
            let chunk = min(n - written, capacityFrames - frameIndex)
            (storage.baseAddress! + frameIndex * channelCount)
                .update(from: src.baseAddress! + written * channelCount,
                        count: chunk * channelCount)
            written += chunk
        }
        writePos.store(w + n, ordering: .releasing)

        if n < frameCount {
            overflowFrames.add(frameCount - n, ordering: .relaxed)
            overflowEvents.add(1, ordering: .relaxed)
        }
        return n
    }

    /// 写入静音帧(启动预填充与欠载恢复用)
    func writeSilence(_ frameCount: Int) {
        let w = writePos.load(ordering: .relaxed)
        let r = readPos.load(ordering: .acquiring)
        let n = min(frameCount, capacityFrames - (w - r))
        var done = 0
        while done < n {
            let frameIndex = (w + done) % capacityFrames
            let chunk = min(n - done, capacityFrames - frameIndex)
            memset(storage.baseAddress! + frameIndex * channelCount, 0,
                   chunk * channelCount * MemoryLayout<Float>.size)
            done += chunk
        }
        if n > 0 { writePos.store(w + n, ordering: .releasing) }
    }

    // MARK: - 消费者(渲染线程)

    /// 读取交错格式数据到 dst。数据不足时剩余部分填 0 并计入 underrun。
    /// - Returns: 实际读到的有效帧数
    @discardableResult
    func read(_ dst: UnsafeMutableBufferPointer<Float>, frameCount: Int) -> Int {
        // 生效生产者的丢弃请求(readPos 只能在这一侧写)
        let drop = dropRequest.exchange(0, ordering: .acquiringAndReleasing)
        var r = readPos.load(ordering: .relaxed)
        let w = writePos.load(ordering: .acquiring)
        if drop > 0 {
            r += min(drop, w - r)
            readPos.store(r, ordering: .releasing)
        }

        let n = min(frameCount, w - r)
        var copied = 0
        while copied < n {
            let frameIndex = (r + copied) % capacityFrames
            let chunk = min(n - copied, capacityFrames - frameIndex)
            (dst.baseAddress! + copied * channelCount)
                .update(from: storage.baseAddress! + frameIndex * channelCount,
                        count: chunk * channelCount)
            copied += chunk
        }
        readPos.store(r + n, ordering: .releasing)

        if n < frameCount {
            memset(dst.baseAddress! + n * channelCount, 0,
                   (frameCount - n) * channelCount * MemoryLayout<Float>.size)
            underrunFrames.add(frameCount - n, ordering: .relaxed)
            if n == 0 { underrunEvents.add(1, ordering: .relaxed) }
        }
        return n
    }

    /// 复位(仅在引擎停止后、非实时上下文调用)
    func reset() {
        writePos.store(0, ordering: .relaxed)
        readPos.store(0, ordering: .relaxed)
        dropRequest.store(0, ordering: .relaxed)
    }
}
