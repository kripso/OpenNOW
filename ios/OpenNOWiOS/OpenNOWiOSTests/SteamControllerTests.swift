import Foundation
import XCTest

#if canImport(OpenNOWiOS)
@testable import OpenNOWiOS
#endif

final class SteamControllerTests: XCTestCase {
    // MARK: Wire format

    /// Builds a 45-byte state report the way the pad packs it: little-endian, no padding.
    private func stateBytes(
        timestamped: Bool,
        buttons: UInt32 = 0,
        leftTrigger: Int16 = 0,
        rightStickX: Int16 = 0,
        leftPad: (Int16, Int16) = (0, 0),
        rightPad: (Int16, Int16) = (0, 0),
        gyroTick: UInt32 = 0,
        gyroPitch: Int16 = 0,
        gyroYaw: Int16 = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 45)
        func put(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8(value >> 8)
        }
        func put(_ value: Int16, at offset: Int) { put(UInt16(bitPattern: value), at: offset) }
        put(UInt16(buttons & 0xffff), at: 1)
        put(UInt16(buttons >> 16), at: 3)
        put(leftTrigger, at: 5)
        put(rightStickX, at: 13)
        let pads = timestamped ? 19 : 17
        put(leftPad.0, at: pads)
        put(leftPad.1, at: pads + 2)
        put(rightPad.0, at: pads + 6)
        put(rightPad.1, at: pads + 8)
        if timestamped {
            put(UInt16(truncatingIfNeeded: gyroTick), at: 31)
        } else {
            put(UInt16(gyroTick & 0xffff), at: 29)
            put(UInt16(gyroTick >> 16), at: 31)
        }
        put(gyroPitch, at: 39)
        put(gyroYaw, at: 43)
        return Data(bytes)
    }

    func testStandardReportDecodesEveryField() throws {
        var decoder = SteamControllerReportDecoder(format: .standard)
        let buttons = SteamControllerButtons([.a, .r4, .leftGrip, .rightPadTouch]).rawValue
        _ = decoder.decode(stateBytes(timestamped: false, gyroTick: 1_000))
        let report = try XCTUnwrap(decoder.decode(stateBytes(
            timestamped: false, buttons: buttons, leftTrigger: 32767, rightStickX: -32768,
            leftPad: (16384, -16384), rightPad: (-8192, 8192), gyroTick: 5_000, gyroPitch: 16384, gyroYaw: -16384)))
        XCTAssertEqual(report.buttons, [.a, .r4, .leftGrip, .rightPadTouch])
        XCTAssertEqual(report.leftTrigger, 1, accuracy: 0.001)
        XCTAssertEqual(report.rightStick.x, -1, accuracy: 0.001)
        XCTAssertEqual(report.leftPad.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.leftPad.y, -0.5, accuracy: 0.001)
        XCTAssertEqual(report.rightPad.x, -0.25, accuracy: 0.001)
        XCTAssertEqual(report.rightPad.y, 0.25, accuracy: 0.001)
        // Half of the ±2000 degrees per second range.
        XCTAssertEqual(report.gyroPitch, Float(1000 * Double.pi / 180), accuracy: 0.01)
        XCTAssertEqual(report.gyroYaw, Float(-1000 * Double.pi / 180), accuracy: 0.01)
        XCTAssertEqual(report.gyroInterval, 0.004, accuracy: 0.000_001)
    }

    func testTimestampedReportMovesTheTrackpadsAndCountsACoarserGyroClock() throws {
        var decoder = SteamControllerReportDecoder(format: .timestamped)
        _ = decoder.decode(stateBytes(timestamped: true, gyroTick: 65_500))
        // The 16-bit clock wraps: 65500 -> 89 is 125 steps of 32 microseconds.
        let report = try XCTUnwrap(decoder.decode(stateBytes(
            timestamped: true, leftPad: (16384, 0), rightPad: (0, -16384), gyroTick: 89)))
        XCTAssertEqual(report.leftPad.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.rightPad.y, -0.5, accuracy: 0.001)
        XCTAssertEqual(report.gyroInterval, 0.004, accuracy: 0.000_001)
    }

    func testRepeatedGyroSampleAndShortReportAreNotCounted() throws {
        var decoder = SteamControllerReportDecoder(format: .standard)
        XCTAssertEqual(try XCTUnwrap(decoder.decode(stateBytes(timestamped: false, gyroTick: 9))).gyroInterval, 0)
        XCTAssertEqual(try XCTUnwrap(decoder.decode(stateBytes(timestamped: false, gyroTick: 9))).gyroInterval, 0)
        XCTAssertNil(decoder.decode(Data(repeating: 0, count: 44)))
    }

    func testSettingsAndRumbleMessagesMatchThePadsLayout() {
        let withGyro = [UInt8](SteamControllerProtocol.settings(gyro: true))
        XCTAssertEqual(withGyro.count, 64)
        // Set-settings, six bytes: lizard mode (9) off, IMU mode (48) raw accelerometer and gyro.
        XCTAssertEqual(Array(withGyro.prefix(8)), [0x87, 6, 9, 0, 0, 48, 0x18, 0])
        XCTAssertEqual(Array([UInt8](SteamControllerProtocol.settings(gyro: false)).prefix(8)), [0x87, 6, 9, 0, 0, 48, 0, 0])
        XCTAssertEqual([UInt8](SteamControllerProtocol.rumble(lowFrequency: 0x1234, highFrequency: 0xabcd)),
                       [0, 0, 0, 0x34, 0x12, 0, 0xcd, 0xab, 0])
    }

    // MARK: Layout storage

    func testLayoutKeepsOnlyWhatDiffersFromTheDefaultsAndSurvivesUnknownValues() throws {
        var layout = SteamControllerLayout()
        XCTAssertEqual(layout.action(for: .a), .pad(.a))
        XCTAssertEqual(layout.action(for: .steam), .shortcut(.controls))
        XCTAssertEqual(layout.action(for: .l4), ControllerAction.none)
        XCTAssertEqual(layout.mode(for: .rightPad), .mouse)
        layout.setAction(.key(0x20), for: .l4)
        layout.setAction(.pad(.a), for: .a)
        layout.setMode(.wasd, for: .leftStick)
        layout.setSensitivity(9_000, for: SteamSurface.rightPad.rawValue)
        XCTAssertEqual(layout.buttons, ["l4": "key:32"])
        XCTAssertEqual(layout.sensitivity(SteamSurface.rightPad.rawValue), 500)

        let restored = try JSONDecoder().decode(SteamControllerLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, layout)

        let future = #"{"buttons":{"a":"macro:7","b":"key:999","x":"mouse:right"},"surfaces":{"leftPad":"radial"},"extra":1}"#
        let tolerant = try JSONDecoder().decode(SteamControllerLayout.self, from: Data(future.utf8))
        XCTAssertEqual(tolerant.action(for: .a), .pad(.a))
        XCTAssertEqual(tolerant.action(for: .b), .pad(.b))
        XCTAssertEqual(tolerant.action(for: .x), .mouse(3))
        XCTAssertEqual(tolerant.mode(for: .leftPad), .scroll)
        XCTAssertEqual(try JSONDecoder().decode(SteamControllerLayout.self, from: Data("{}".utf8)), SteamControllerLayout())
    }

    func testEveryActionRoundTripsThroughItsToken() {
        let actions: [ControllerAction] = [.none, .pad(.rt), .pad(.guide), .key(0x41), .mouse(1), .mouse(2), .mouse(3),
                                           .wheel(1), .wheel(-1), .shortcut(.controls), .shortcut(.stats)]
        for action in actions {
            XCTAssertEqual(ControllerAction(token: action.token), action)
        }
        XCTAssertNil(ControllerAction(token: "app:none"))
        XCTAssertNil(ControllerAction(token: "key:0"))
    }

    // MARK: Mapping

    private func report(_ buttons: SteamControllerButtons = [], _ change: (inout SteamControllerReport) -> Void = { _ in }) -> SteamControllerReport {
        var report = SteamControllerReport()
        report.buttons = buttons
        change(&report)
        return report
    }

    func testStickDeadZoneIgnoresSmallDeflectionAndStillReachesFullTravel() throws {
        var mapper = SteamInputEngine()
        // The 12% default swallows a resting drift of 10%.
        var output = mapper.apply(report { $0.leftStick = .init(x: 0.1, y: 0) }, at: 0)
        XCTAssertEqual(output.pad.leftStickX, 0)
        // Past the dead zone the stick moves from zero, and full travel is still full travel.
        output = mapper.apply(report { $0.leftStick = .init(x: 0.56, y: 0) }, at: 0.01)
        XCTAssertEqual(Double(output.pad.leftStickX), 32767 * 0.5, accuracy: 40)
        output = mapper.apply(report { $0.leftStick = .init(x: 1, y: 0) }, at: 0.02)
        XCTAssertEqual(output.pad.leftStickX, 32767)

        // A larger setting needs more travel; zero passes the stick through untouched.
        mapper.tuning.stickDeadZone = 30
        output = mapper.apply(report { $0.leftStick = .init(x: 0.25, y: 0) }, at: 0.03)
        XCTAssertEqual(output.pad.leftStickX, 0)
        mapper.tuning.stickDeadZone = 0
        output = mapper.apply(report { $0.leftStick = .init(x: 0.1, y: 0) }, at: 0.04)
        XCTAssertEqual(Double(output.pad.leftStickX), 32767 * 0.1, accuracy: 40)

        // Settings saved before the dead zone existed keep the 12% default; out-of-range values are clamped.
        let old = try JSONDecoder().decode(SteamControllerTuning.self, from: Data(#"{"gyro":150}"#.utf8))
        XCTAssertEqual(old.stickDeadZone, 12)
        let wild = try JSONDecoder().decode(SteamControllerTuning.self, from: Data(#"{"stickDeadZone":90}"#.utf8))
        XCTAssertEqual(wild.stickDeadZone, 40)
    }

    func testDefaultLayoutIsAGamepadWithAMouseOnTheRightTrackpad() {
        var mapper = SteamInputEngine()
        var output = mapper.apply(report([.a, .dpadLeft, .view]) { $0.leftTrigger = 0.5; $0.leftStick = .init(x: 1, y: -1) }, at: 0)
        XCTAssertEqual(output.pad.buttons, 0x1000 | 0x0004 | 0x0020)
        XCTAssertEqual(output.pad.leftTrigger, 128)
        // A diagonal is held to the stick's circle.
        XCTAssertEqual(output.pad.leftStickX, 23170)
        XCTAssertEqual(output.pad.leftStickY, -23170)
        XCTAssertTrue(output.keys.isEmpty)

        // Landing a thumb does not move the pointer; sliding it does, with up on the pad as up on screen.
        output = mapper.apply(report([.rightPadTouch]) { $0.rightPad = .init(x: 0, y: 0) }, at: 0.01)
        XCTAssertEqual(output.mouse, .zero)
        output = mapper.apply(report([.rightPadTouch]) { $0.rightPad = .init(x: 0.25, y: 0.5) }, at: 0.02)
        XCTAssertEqual(output.mouse.x, 150, accuracy: 0.001)
        XCTAssertEqual(output.mouse.y, -300, accuracy: 0.001)

        output = mapper.apply(report([.rightPadTouch, .rightPadClick]) { $0.rightPad = .init(x: 0.25, y: 0.5) }, at: 0.03)
        XCTAssertEqual(output.mouseButtons, [.init(button: 1, pressed: true)])
        output = mapper.apply(report(), at: 0.04)
        XCTAssertEqual(output.mouseButtons, [.init(button: 1, pressed: false)])
        XCTAssertEqual(output.pad, SteamInputEngine.Pad())
    }

    func testBackButtonsCanSendPadButtonsTriggersAndKeys() {
        var layout = SteamControllerLayout()
        layout.setAction(.pad(.a), for: .r4)
        layout.setAction(.pad(.rt), for: .r5)
        layout.setAction(.key(0x20), for: .l4)
        var mapper = SteamInputEngine(layout: layout)
        var output = mapper.apply(report([.r4, .r5, .l4]), at: 0)
        XCTAssertEqual(output.pad.buttons, 0x1000)
        XCTAssertEqual(output.pad.rightTrigger, 255)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x20, pressed: true, modifiers: 0)])
        output = mapper.apply(report(), at: 0.01)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x20, pressed: false, modifiers: 0)])
        XCTAssertEqual(output.pad, SteamInputEngine.Pad())
    }

    func testKeyboardLayoutWalksWithTheStickAndSendsChordsInOrder() {
        var mapper = SteamInputEngine(layout: .keyboardAndMouse)
        var output = mapper.apply(report { $0.leftStick = .init(x: 0, y: 0.9) }, at: 0)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x57, pressed: true, modifiers: 0)])
        XCTAssertEqual(output.pad, SteamInputEngine.Pad(), "a stick that types must not also reach the game as a stick")

        // Shift goes down before the key it modifies and comes up after it.
        output = mapper.apply(report([.leftBumper, .dpadUp]) { $0.leftStick = .init(x: 0, y: 0.9) }, at: 0.01)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0xa0, pressed: true, modifiers: 0x01),
                                     .init(virtualKey: 0x31, pressed: true, modifiers: 0x01)])
        output = mapper.apply(report(), at: 0.02)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x31, pressed: false, modifiers: 0x01),
                                     .init(virtualKey: 0x57, pressed: false, modifiers: 0x01),
                                     .init(virtualKey: 0xa0, pressed: false, modifiers: 0)])

        // Triggers click once past their threshold and let go only once clearly released.
        output = mapper.apply(report { $0.rightTrigger = 0.35 }, at: 0.03)
        XCTAssertEqual(output.mouseButtons, [.init(button: 1, pressed: true)])
        output = mapper.apply(report { $0.rightTrigger = 0.25 }, at: 0.04)
        XCTAssertTrue(output.mouseButtons.isEmpty)
        output = mapper.apply(report { $0.rightTrigger = 0.1 }, at: 0.05)
        XCTAssertEqual(output.mouseButtons, [.init(button: 1, pressed: false)])
        XCTAssertEqual(output.pad.rightTrigger, 0)
    }

    func testStickAsMouseKeepsMovingWhileHeldStill() {
        var mapper = SteamInputEngine(layout: .keyboardAndMouse)
        var output = mapper.apply(report { $0.rightStick = .init(x: 1, y: 0) }, at: 10)
        XCTAssertEqual(output.mouse, .zero, "the first report only starts the clock")
        output = mapper.advance(to: 10.01)
        XCTAssertEqual(output.mouse.x, 10.8, accuracy: 0.001)
        XCTAssertEqual(output.mouse.y, 0, accuracy: 0.001)
        // A long gap counts as one step, not as a leap across the screen.
        output = mapper.advance(to: 20)
        XCTAssertEqual(output.mouse.x, 54, accuracy: 0.001)
    }

    func testLeftTrackpadScrollsAndTurnsItsSwipeIntoWheelUnits() {
        var mapper = SteamInputEngine()
        _ = mapper.apply(report([.leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0) }, at: 0)
        let output = mapper.apply(report([.leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0.1) }, at: 0.01)
        XCTAssertEqual(output.wheel, 120)
        XCTAssertEqual(output.mouse, .zero)
    }

    func testGyroAimsOnlyWhileItsActivatorIsHeld() {
        var layout = SteamControllerLayout()
        layout.gyroMode = .mouse
        layout.gyroActivator = .rightGrip
        var mapper = SteamInputEngine(layout: layout)
        XCTAssertTrue(mapper.wantsGyro)
        // One radian per second to the left and tilting back, for ten milliseconds.
        let turning: (inout SteamControllerReport) -> Void = { $0.gyroYaw = 1; $0.gyroPitch = 1; $0.gyroInterval = 0.01 }
        XCTAssertEqual(mapper.apply(report([], turning), at: 0).mouse, .zero)
        let output = mapper.apply(report([.rightGrip], turning), at: 0.01)
        let expected = -(180 / Double.pi) * 0.01 * 20
        XCTAssertEqual(output.mouse.x, expected, accuracy: 0.001)
        XCTAssertEqual(output.mouse.y, expected, accuracy: 0.001)

        layout.gyroMode = .rightStick
        layout.gyroActivator = nil
        mapper = SteamInputEngine(layout: layout)
        // Turning right at 90 degrees per second is half of the full-scale rate.
        let stick = mapper.apply(report { $0.gyroYaw = -.pi / 2; $0.gyroInterval = 0.004 }, at: 0)
        XCTAssertEqual(Int(stick.pad.rightStickX), 16384, accuracy: 2)
        XCTAssertEqual(stick.pad.rightStickY, 0)
    }

    func testSuspendingReleasesEverythingAndIgnoresControlsUntilTheyAreLetGo() {
        var layout = SteamControllerLayout()
        layout.setAction(.key(0x45), for: .l4)
        var mapper = SteamInputEngine(layout: layout)
        _ = mapper.apply(report([.a, .l4]), at: 0)

        // The Steam button asks for the stream controls even though the stream no longer owns the pad.
        var output = mapper.apply(report([.a, .l4, .steam]), at: 0.01, suspended: true)
        XCTAssertEqual(output.shortcuts, [.controls])
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x45, pressed: false, modifiers: 0)])
        XCTAssertEqual(output.pad, SteamInputEngine.Pad())

        // Back in the game with A still held from choosing a menu item: it must not reach the game.
        output = mapper.apply(report([.a, .l4]), at: 0.02)
        XCTAssertEqual(output.pad.buttons, 0)
        XCTAssertTrue(output.keys.isEmpty)
        output = mapper.apply(report([.l4]), at: 0.03)
        XCTAssertTrue(output.keys.isEmpty)
        output = mapper.apply(report(), at: 0.04)
        output = mapper.apply(report([.a, .l4]), at: 0.05)
        XCTAssertEqual(output.pad.buttons, 0x1000)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x45, pressed: true, modifiers: 0)])

        output = mapper.releaseAll()
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x45, pressed: false, modifiers: 0)])
        XCTAssertEqual(output.pad, SteamInputEngine.Pad())
    }

    func testChangingTheLayoutWhileHeldMovesTheOutput() {
        var layout = SteamControllerLayout()
        layout.setAction(.key(0x45), for: .r4)
        var mapper = SteamInputEngine(layout: layout)
        _ = mapper.apply(report([.r4]), at: 0)
        layout.setAction(.key(0x46), for: .r4)
        mapper.config = layout.steamInputConfig
        let output = mapper.apply(report([.r4]), at: 0.01)
        XCTAssertEqual(output.keys, [.init(virtualKey: 0x45, pressed: false, modifiers: 0),
                                     .init(virtualKey: 0x46, pressed: true, modifiers: 0)])
    }

    func testBoundKeysCarryTheirScanCodes() {
        XCTAssertEqual(NativeStreamKeyboardMapper.mapping(forVirtualKey: 0x0d),
                       NativeStreamKeyboardMapping(virtualKey: 0x0d, scanCode: 0x001c))
        XCTAssertEqual(NativeStreamKeyboardMapper.mapping(forVirtualKey: 0x57).scanCode, 0x0011)
        for group in ControllerBindableKey.groups {
            for key in group.keys {
                XCTAssertNotEqual(NativeStreamKeyboardMapper.mapping(forVirtualKey: key.code).scanCode, 0, key.name)
            }
        }
    }
}
