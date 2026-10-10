import Testing
@testable import MicMonitor

struct RingBufferTests {

    private func write(_ rb: RingBuffer, _ samples: [Float], channels: Int) -> Int {
        samples.withUnsafeBufferPointer { rb.write($0, frameCount: samples.count / channels) }
    }

    private func read(_ rb: RingBuffer, frames: Int, channels: Int) -> (Int, [Float]) {
        var out = [Float](repeating: -999, count: frames * channels)
        let n = out.withUnsafeMutableBufferPointer { rb.read($0, frameCount: frames) }
        return (n, out)
    }

    @Test func writeReadRoundTrip() {
        let rb = RingBuffer(capacityFrames: 16, channelCount: 2)
        let src: [Float] = (0..<8).flatMap { f in [Float(f), Float(f) + 0.5] }
        #expect(write(rb, src, channels: 2) == 8)
        #expect(rb.availableFrames == 8)
        let (n, out) = read(rb, frames: 8, channels: 2)
        #expect(n == 8)
        #expect(out == src)
        #expect(rb.availableFrames == 0)
    }

    @Test func wraparound() {
        let rb = RingBuffer(capacityFrames: 8, channelCount: 1)
        #expect(write(rb, [0, 1, 2, 3, 4, 5], channels: 1) == 6)
        _ = read(rb, frames: 4, channels: 1)
        // 写索引此时会绕回起点
        #expect(write(rb, [6, 7, 8, 9, 10], channels: 1) == 5)
        let (n, out) = read(rb, frames: 7, channels: 1)
        #expect(n == 7)
        #expect(out == [4, 5, 6, 7, 8, 9, 10])
    }

    @Test func writeBeyondCapacityTruncatesAndCountsOverflow() {
        // 注:RingBuffer init 对容量有最小钳制(64),这里用 64 容量写 100 帧
        let rb = RingBuffer(capacityFrames: 64, channelCount: 1, targetWater: 2, highWater: 6)
        let n = write(rb, [Float](repeating: 1, count: 100), channels: 1)
        #expect(n == 64)   // 只能写进容量内,剩余丢弃
        #expect(rb.overflowFrames.load(ordering: .relaxed) >= 36)
        #expect(rb.availableFrames == 64)
    }

    @Test func overflowTriggersPendingDropOnNextRead() {
        let rb = RingBuffer(capacityFrames: 8, channelCount: 1, targetWater: 2, highWater: 4)
        #expect(write(rb, [0, 1, 2, 3, 4, 5, 6, 7], channels: 1) == 8)
        // 水位 8 > highWater 4 → 消费者读时应先丢到 targetWater 2
        let (n, out) = read(rb, frames: 8, channels: 1)
        #expect(n == 2)
        #expect(Array(out.prefix(2)) == [6, 7])   // 丢最旧的 6 帧,剩最新 2 帧
    }

    @Test func underrunFillsSilenceAndCounts() {
        let rb = RingBuffer(capacityFrames: 8, channelCount: 2)
        #expect(write(rb, [1, 2, 3, 4], channels: 2) == 2) // 2 帧立体声
        let (n, out) = read(rb, frames: 6, channels: 2)
        #expect(n == 2)
        #expect(out == [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(rb.underrunFrames.load(ordering: .relaxed) == 4)
        let (m, _) = read(rb, frames: 2, channels: 2)
        #expect(m == 0)
        #expect(rb.underrunEvents.load(ordering: .relaxed) == 1)
    }

    @Test func writeSilence() {
        let rb = RingBuffer(capacityFrames: 8, channelCount: 1)
        rb.writeSilence(4)
        #expect(rb.availableFrames == 4)
        let (n, out) = read(rb, frames: 4, channels: 1)
        #expect(n == 4)
        #expect(out == [0, 0, 0, 0])
    }

    @Test func reset() {
        let rb = RingBuffer(capacityFrames: 8, channelCount: 1)
        _ = write(rb, [1, 2, 3], channels: 1)
        rb.reset()
        #expect(rb.availableFrames == 0)
        let (n, _) = read(rb, frames: 1, channels: 1)
        #expect(n == 0)
    }
}
