import Foundation

/// The second-generation Steam Controller as it speaks over Bluetooth LE.
///
/// iOS shows the pad to apps only through Valve's own GATT service, not as a game controller, so
/// the raw state is read here. That state carries everything the standard controller profile
/// lacks: both trackpads with pressure, the four grip buttons, the touch sensors and the gyro.
/// The identifiers and layouts follow SDL's Steam Controller drivers (`src/hidapi/ios/hid.m` and
/// `SDL_hidapi_steam_triton.c`), which are what Steam Link uses on iOS.
enum SteamControllerProtocol {
    static let serviceUUID = "100F6C32-1735-4313-B402-38567131E5F3"
    /// Notifies state report 0x45.
    static let stateCharacteristicUUID = "100F6C7A-1735-4313-B402-38567131E5F3"
    /// Notifies state report 0x47, which newer firmware sends instead.
    static let timestampedStateCharacteristicUUID = "100F6C7C-1735-4313-B402-38567131E5F3"
    /// Settings are written here as a feature report without its report ID.
    static let settingsCharacteristicUUID = "100F6C34-1735-4313-B402-38567131E5F3"
    /// Output report 0x80. Each output report has its own characteristic, numbered 0x35 above its ID.
    static let rumbleCharacteristicUUID = "100F6CB5-1735-4313-B402-38567131E5F3"
    /// Every paired pad exposes Device Information, which is how connected ones are found.
    static let deviceInformationServiceUUID = "180A"
    static let namePrefix = "Steam"

    static let stateLength = 45
    /// The pad falls back to typing keys and moving the system pointer ("lizard mode") a few
    /// seconds after it stops being told otherwise, so the settings are repeated.
    static let settingsRepeatInterval: TimeInterval = 3
    /// The pad stops a rumble that is not repeated.
    static let rumbleRepeatInterval: TimeInterval = 0.04

    private static let setSettingsMessage: UInt8 = 0x87
    private static let lizardModeSetting: UInt8 = 9
    private static let imuModeSetting: UInt8 = 48
    private static let imuRawAccelerometerAndGyro: UInt16 = 0x0008 | 0x0010
    private static let featureReportLength = 64

    /// Turns the pad's own keyboard and mouse emulation off, and asks for gyro readings if wanted.
    static func settings(gyro: Bool) -> Data {
        var settings: [(UInt8, UInt16)] = [(lizardModeSetting, 0)]
        settings.append((imuModeSetting, gyro ? imuRawAccelerometerAndGyro : 0))
        var bytes = [UInt8](repeating: 0, count: featureReportLength)
        bytes[0] = setSettingsMessage
        bytes[1] = UInt8(settings.count * 3)
        for (index, setting) in settings.enumerated() {
            bytes[2 + index * 3] = setting.0
            bytes[3 + index * 3] = UInt8(setting.1 & 0xff)
            bytes[4 + index * 3] = UInt8(setting.1 >> 8)
        }
        return Data(bytes)
    }

    /// The payload of the rumble output report: both motor speeds, no gain change.
    static func rumble(lowFrequency: UInt16, highFrequency: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[3] = UInt8(lowFrequency & 0xff)
        bytes[4] = UInt8(lowFrequency >> 8)
        bytes[6] = UInt8(highFrequency & 0xff)
        bytes[7] = UInt8(highFrequency >> 8)
        return Data(bytes)
    }
}

struct SteamControllerButtons: OptionSet, Equatable {
    let rawValue: UInt32

    static let a = SteamControllerButtons(rawValue: 0x0000_0001)
    static let b = SteamControllerButtons(rawValue: 0x0000_0002)
    static let x = SteamControllerButtons(rawValue: 0x0000_0004)
    static let y = SteamControllerButtons(rawValue: 0x0000_0008)
    static let quickAccess = SteamControllerButtons(rawValue: 0x0000_0010)
    static let rightStickClick = SteamControllerButtons(rawValue: 0x0000_0020)
    static let view = SteamControllerButtons(rawValue: 0x0000_0040)
    static let r4 = SteamControllerButtons(rawValue: 0x0000_0080)
    static let r5 = SteamControllerButtons(rawValue: 0x0000_0100)
    static let rightBumper = SteamControllerButtons(rawValue: 0x0000_0200)
    static let dpadDown = SteamControllerButtons(rawValue: 0x0000_0400)
    static let dpadRight = SteamControllerButtons(rawValue: 0x0000_0800)
    static let dpadLeft = SteamControllerButtons(rawValue: 0x0000_1000)
    static let dpadUp = SteamControllerButtons(rawValue: 0x0000_2000)
    static let menu = SteamControllerButtons(rawValue: 0x0000_4000)
    static let leftStickClick = SteamControllerButtons(rawValue: 0x0000_8000)
    static let steam = SteamControllerButtons(rawValue: 0x0001_0000)
    static let l4 = SteamControllerButtons(rawValue: 0x0002_0000)
    static let l5 = SteamControllerButtons(rawValue: 0x0004_0000)
    static let leftBumper = SteamControllerButtons(rawValue: 0x0008_0000)
    static let rightStickTouch = SteamControllerButtons(rawValue: 0x0010_0000)
    static let rightPadTouch = SteamControllerButtons(rawValue: 0x0020_0000)
    static let rightPadClick = SteamControllerButtons(rawValue: 0x0040_0000)
    /// The switch at the end of the trigger's travel.
    static let rightTriggerClick = SteamControllerButtons(rawValue: 0x0080_0000)
    static let leftStickTouch = SteamControllerButtons(rawValue: 0x0100_0000)
    static let leftPadTouch = SteamControllerButtons(rawValue: 0x0200_0000)
    static let leftPadClick = SteamControllerButtons(rawValue: 0x0400_0000)
    static let leftTriggerClick = SteamControllerButtons(rawValue: 0x0800_0000)
    static let rightGrip = SteamControllerButtons(rawValue: 0x1000_0000)
    static let leftGrip = SteamControllerButtons(rawValue: 0x2000_0000)
}

/// A point on a stick or trackpad: x grows to the right and y grows upward, both about -1...1.
struct SteamControllerVector: Equatable {
    var x: Float = 0
    var y: Float = 0

    static let zero = SteamControllerVector()
    var length: Float { (x * x + y * y).squareRoot() }
}

/// One state report from the pad.
struct SteamControllerReport: Equatable {
    var buttons: SteamControllerButtons = []
    /// 0 released, 1 fully pulled.
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var leftStick = SteamControllerVector.zero
    var rightStick = SteamControllerVector.zero
    /// Only meaningful while the matching touch flag is set.
    var leftPad = SteamControllerVector.zero
    var rightPad = SteamControllerVector.zero
    /// Rotation rate in radians per second. Positive pitch tilts the top of the pad toward the
    /// player and positive yaw turns it to the left.
    var gyroPitch: Float = 0
    var gyroYaw: Float = 0
    /// Seconds of rotation this reading covers; zero when it repeats the previous sample.
    var gyroInterval: TimeInterval = 0
}

/// Decodes state reports, carrying the gyro clock from one report to the next.
struct SteamControllerReportDecoder {
    enum Format {
        /// Report 0x45: the gyro clock counts microseconds in 32 bits.
        case standard
        /// Report 0x47: adds a trackpad timestamp and counts the gyro clock in 32 µs steps.
        case timestamped
    }

    let format: Format
    private var lastGyroTick: UInt32?

    init(format: Format) {
        self.format = format
    }

    /// Forgets the gyro clock, for when readings stop and later resume.
    mutating func resetGyroClock() {
        lastGyroTick = nil
    }

    mutating func decode(_ data: Data) -> SteamControllerReport? {
        guard data.count >= SteamControllerProtocol.stateLength else { return nil }
        let bytes = [UInt8](data.prefix(SteamControllerProtocol.stateLength))
        func unsigned(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func signed(_ offset: Int) -> Float { Float(Int16(bitPattern: unsigned(offset))) }
        func axis(_ offset: Int) -> Float { max(-1, signed(offset) / 32767) }

        var report = SteamControllerReport()
        report.buttons = SteamControllerButtons(rawValue:
            UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
        report.leftTrigger = min(max(signed(5) / 32767, 0), 1)
        report.rightTrigger = min(max(signed(7) / 32767, 0), 1)
        report.leftStick = SteamControllerVector(x: axis(9), y: axis(11))
        report.rightStick = SteamControllerVector(x: axis(13), y: axis(15))
        let pads = format == .timestamped ? 19 : 17
        report.leftPad = SteamControllerVector(x: axis(pads), y: axis(pads + 2))
        report.rightPad = SteamControllerVector(x: axis(pads + 6), y: axis(pads + 8))

        let tick: UInt32
        let microsecondsPerTick: UInt32
        switch format {
        case .standard:
            tick = UInt32(unsigned(29)) | UInt32(unsigned(31)) << 16
            microsecondsPerTick = 1
        case .timestamped:
            tick = UInt32(unsigned(31))
            microsecondsPerTick = 32
        }
        // The pad's axes are x right, y toward the player, z up; ±2000 degrees per second full scale.
        let radiansPerUnit = Float(2000.0 / 32768.0 * Double.pi / 180.0)
        report.gyroPitch = signed(39) * radiansPerUnit
        report.gyroYaw = signed(43) * radiansPerUnit
        if let last = lastGyroTick, tick != last {
            let elapsed = format == .timestamped ? UInt32(UInt16(truncatingIfNeeded: tick &- last)) : tick &- last
            report.gyroInterval = TimeInterval(elapsed) * TimeInterval(microsecondsPerTick) / 1_000_000
        }
        lastGyroTick = tick
        return report
    }
}
