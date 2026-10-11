import Foundation

/// UserDefaults 持久化。设备按 UID(字符串)保存——deviceID 在重启/重插后会变,UID 稳定。
final class Settings {
    static let shared = Settings()

    private let d = UserDefaults.standard

    private enum K {
        static let inputUID = "inputUID"          // "" = 跟随系统默认
        static let outputUID = "outputUID"
        static let volume = "volume"              // 0.0 ~ 2.0
        static let muted = "muted"
        static let gateEnabled = "gateEnabled"
        static let gateThresholdDB = "gateThresholdDB"
        static let voiceFocus = "voiceFocus"      // 人声突显:非人声自动压低 ~22dB
        static let lowLatency = "lowLatency"      // 低延迟模式(默认开):请求小 IO 缓冲
        static let dockIcon = "dockIcon"          // Dock 图标模式:regular vs accessory
        static let wasRunning = "wasRunning"
        static let hasLaunched = "hasLaunched"
    }

    var inputUID: String {
        get { d.string(forKey: K.inputUID) ?? "" }
        set { d.set(newValue, forKey: K.inputUID) }
    }
    var outputUID: String {
        get { d.string(forKey: K.outputUID) ?? "" }
        set { d.set(newValue, forKey: K.outputUID) }
    }
    var volume: Float {
        get { d.object(forKey: K.volume) != nil ? d.float(forKey: K.volume) : 1.0 }
        set { d.set(min(max(newValue, 0), 2), forKey: K.volume) }
    }
    var muted: Bool {
        get { d.bool(forKey: K.muted) }
        set { d.set(newValue, forKey: K.muted) }
    }
    var gateEnabled: Bool {
        get { d.bool(forKey: K.gateEnabled) }
        set { d.set(newValue, forKey: K.gateEnabled) }
    }
    var gateThresholdDB: Float {
        get { d.object(forKey: K.gateThresholdDB) != nil ? d.float(forKey: K.gateThresholdDB) : -50 }
        set { d.set(newValue, forKey: K.gateThresholdDB) }
    }
    var voiceFocus: Bool {
        get { d.bool(forKey: K.voiceFocus) }
        set { d.set(newValue, forKey: K.voiceFocus) }
    }
    /// 低延迟模式默认开启:只在用户明确关掉时才持久化为 false
    var lowLatency: Bool {
        get { d.object(forKey: K.lowLatency) != nil ? d.bool(forKey: K.lowLatency) : true }
        set { d.set(newValue, forKey: K.lowLatency) }
    }
    var wasRunning: Bool {
        get { d.bool(forKey: K.wasRunning) }
        set { d.set(newValue, forKey: K.wasRunning) }
    }
    /// 是否在 Dock 显示图标(false = 纯菜单栏 accessory 模式)
    var dockIcon: Bool {
        get { d.bool(forKey: K.dockIcon) }
        set { d.set(newValue, forKey: K.dockIcon) }
    }
    var hasLaunched: Bool {
        get { d.bool(forKey: K.hasLaunched) }
        set { d.set(newValue, forKey: K.hasLaunched) }
    }
}
