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
    var wasRunning: Bool {
        get { d.bool(forKey: K.wasRunning) }
        set { d.set(newValue, forKey: K.wasRunning) }
    }
    var hasLaunched: Bool {
        get { d.bool(forKey: K.hasLaunched) }
        set { d.set(newValue, forKey: K.hasLaunched) }
    }
}
