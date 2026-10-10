import Testing
@testable import MicMonitor

struct RingBufferTests {

    /// 把每声道样本数组写入环形缓冲(planar)
    private func write(_ rb: RingBuffer, _ chans: [[Float]]) -> Int {
        let n = chans[0].count
        let ptrs = UnsafeMutableBufferPointer<UnsafeBufferPointer<Float>>.allocate(capacity: chans.count)
        var keeps: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            for p in keeps { p.deallocate() }
            ptrs.deallocate()
        }
        for (i, ch) in chans.enumerated() {
            let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
            _ = p.initialize(from: ch)
            keeps.append(p)
            ptrs[i] = UnsafeBufferPointer(p)
        }
        return rb.write(UnsafeBufferPointer(ptrs), frameCount: n)
    }

    /// 读 frames 帧,返回 (实际读到帧数, 每声道样本数组)
    private func read(_ rb: RingBuffer, frames: Int, channels: Int) -> (Int, [[Float]]) {
        let dsts = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        var bufs: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            for p in bufs { p.deallocate() }
            dsts.deallocate()
        }
        for i in 0..<channels {
            let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: -999)
            bufs.append(p)
            dsts[i] = p.baseAddress!
        }
        let n = rb.read(UnsafeBufferPointer(dsts), frameCount: frames)
        return (n, bufs.map { Array($0) })
    }

    @Test func writeReadRoundTrip() {
        let rb = RingBuffer(capacityFrames: 16, channelCount: 2)
        let l: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let r: [Float] = [10, 11, 12, 13, 14, 15, 16, 17]
        #expect(write(rb, [l, r]) == 8)
        #expect(rb.availableFrames == 8)
        let (n, out) = read(rb, frames: 8, channels: 2)
        #expect(n == 8)
        #expect(out[0] == l)
        #expect(out[1] == r)
        #expect(rb.availableFrames == 0)
    }

    @Test func wraparound() {
        let rb = RingBuffer(capacityFrames: 64, channelCount: 1)
        #expect(write(rb, [[0, 1, 2, 3, 4, 5]]) == 6)
        _ = read(rb, frames: 4, channels: 1)
        #expect(write(rb, [[6, 7, 8, 9, 10]]) == 5)
        let (n, out) = read(rb, frames: 7, channels: 1)
        #expect(n == 7)
        #expect(out[0] == [4, 5, 6, 7, 8, 9, 10])
    }

    @Test func writeBeyondCapacityTruncatesAndCountsOverflow() {
        // 注:RingBuffer init 对容量有最小钳制(64),这里用 64 容量写 100 帧
        let rb = RingBuffer(capacityFrames: 64, channelCount: 1, targetWater: 2, highWater: 6)
        let n = write(rb, [[Float](repeating: 1, count: 100)])
        #expect(n == 64)   // 只能写进容量内,剩余丢弃
        #expect(rb.overflowFrames.load(ordering: .relaxed) >= 36)
        #expect(rb.availableFrames == 64)
    }

    @Test func overflowTriggersPendingDropOnNextRead() {
        let rb = RingBuffer(capacityFrames: 64, channelCount: 1, targetWater: 2, highWater: 4)
        #expect(write(rb, [[0, 1, 2, 3, 4, 5, 6, 7]]) == 8)
        // 水位 8 > highWater 4 → 消费者读时应先丢到 targetWater 2
        let (n, out) = read(rb, frames: 8, channels: 1)
        #expect(n == 2)
        #expect(Array(out[0].prefix(2)) == [6, 7])   // 丢最旧的 6 帧,剩最新 2 帧
    }

    @Test func underrunFillsSilenceAndCounts() {
        let rb = RingBuffer(capacityFrames: 64, channelCount: 2)
        #expect(write(rb, [[1, 3], [2, 4]]) == 2) // 2 帧立体声
        let (n, out) = read(rb, frames: 6, channels: 2)
        #expect(n == 2)
        #expect(out[0] == [1, 3, 0, 0, 0, 0])
        #expect(out[1] == [2, 4, 0, 0, 0, 0])
        #expect(rb.underrunFrames.load(ordering: .relaxed) == 4)
        let (m, _) = read(rb, frames: 2, channels: 2)
        #expect(m == 0)
        #expect(rb.underrunEvents.load(ordering: .relaxed) == 1)
    }

    @Test func writeSilence() {
        let rb = RingBuffer(capacityFrames: 64, channelCount: 2)
        rb.writeSilence(4)
        #expect(rb.availableFrames == 4)
        let (n, out) = read(rb, frames: 4, channels: 2)
        #expect(n == 4)
        #expect(out[0] == [0, 0, 0, 0])
        #expect(out[1] == [0, 0, 0, 0])
    }

    @Test func reset() {
        let rb = RingBuffer(capacityFrames: 64, channelCount: 1)
        _ = write(rb, [[1, 2, 3]])
        rb.reset()
        #expect(rb.availableFrames == 0)
        let (n, _) = read(rb, frames: 1, channels: 1)
        #expect(n == 0)
    }
}
