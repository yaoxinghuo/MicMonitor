import CoreAudio
import Foundation

/// 一个音频设备的快照(可能同时有输入和输出通道)
struct AudioDeviceInfo: Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let transportType: UInt32

    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "内置"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "聚合"
        case kAudioDeviceTransportTypeVirtual: return "虚拟"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        default: return "其他"
        }
    }
}

/// CoreAudio HAL 属性读写工具
enum CoreAudioUtil {
    /// kAudioObjectSystemObject 导入到 Swift 后是 Int32,统一转成 AudioObjectID
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// 读取定长值属性(UInt32 / Float64 / AudioDeviceID 等)
    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            type: T.Type) -> T? {
        var addr = address(selector, scope: scope)
        // 注意:不能直接写 Optional<T> 的存储 —— 对没有 spare inhabitant 的类型,
        // Optional 的 nil 标记在独立字节上,写 payload 后仍会被读作 nil
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        return status == noErr ? ptr.pointee : nil
    }

    /// 读取 CFString 属性。CoreAudio 按 copy 语义返回,用 Unmanaged + takeRetainedValue 平衡引用。
    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref)
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID {
        property(systemObject,
                 input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                 type: AudioDeviceID.self) ?? 0
    }

    /// 设备当前 IO 缓冲帧数(优先方向 scope,内置设备上有些属性挂在全局 scope)
    static func bufferFrameSize(_ device: AudioDeviceID, input: Bool) -> UInt32? {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        return property(device, kAudioDevicePropertyBufferFrameSize, scope: scope, type: UInt32.self)
            ?? property(device, kAudioDevicePropertyBufferFrameSize, type: UInt32.self)
    }

    /// 请求修改设备 IO 缓冲帧数。这只是"请求":USB/蓝牙等设备可拒绝或取整,须读回实际值。
    static func setBufferFrameSize(_ device: AudioDeviceID, input: Bool, frames: UInt32) -> Bool {
        var wanted = frames
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        var addr = address(kAudioDevicePropertyBufferFrameSize, scope: scope)
        var status = AudioObjectSetPropertyData(device, &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &wanted)
        if status != noErr {
            addr = address(kAudioDevicePropertyBufferFrameSize)
            status = AudioObjectSetPropertyData(device, &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &wanted)
        }
        return status == noErr
    }

    /// 某方向上的声道总数:读取 StreamConfiguration 中全部 buffer 的 mNumberChannels 之和
    static func channelCount(_ device: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        var total = 0
        for b in UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1)) {
            total += Int(b.mNumberChannels)
        }
        return total
    }
}

/// 设备枚举 + 热插拔/默认设备变化监听(回调在主队列触发)
final class AudioDeviceManager {
    private(set) var devices: [AudioDeviceInfo] = []
    /// 参数为触发监听的 selector:kAudioHardwarePropertyDevices / DefaultInputDevice / DefaultOutputDevice
    var onEvent: ((AudioObjectPropertySelector) -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() { refresh() }
    deinit { stopMonitoring() }

    func refresh() {
        devices = CoreAudioUtil.allDeviceIDs().compactMap { id in
            guard let uid = CoreAudioUtil.stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDeviceInfo(
                id: id,
                uid: uid,
                name: CoreAudioUtil.stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? uid,
                inputChannels: CoreAudioUtil.channelCount(id, input: true),
                outputChannels: CoreAudioUtil.channelCount(id, input: false),
                nominalSampleRate: CoreAudioUtil.property(id, kAudioDevicePropertyNominalSampleRate, type: Double.self) ?? 0,
                transportType: CoreAudioUtil.property(id, kAudioDevicePropertyTransportType, type: UInt32.self) ?? 0
            )
        }
    }

    func info(forUID uid: String) -> AudioDeviceInfo? { devices.first { $0.uid == uid } }
    func info(forID id: AudioDeviceID) -> AudioDeviceInfo? { devices.first { $0.id == id } }

    func startMonitoring() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] as [AudioObjectPropertySelector] {
            var addr = CoreAudioUtil.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, addresses in
                self?.onEvent?(addresses.pointee.mSelector)
            }
            let status = AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &addr,
                                                           DispatchQueue.main, block)
            if status == noErr {
                listeners.append((addr, block))
            } else {
                AppLogger.shared.log("设备监听器注册失败 selector=\(selector) status=\(status)")
            }
        }
    }

    func stopMonitoring() {
        for (var addr, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &addr,
                                                   DispatchQueue.main, block)
        }
        listeners.removeAll()
    }
}
