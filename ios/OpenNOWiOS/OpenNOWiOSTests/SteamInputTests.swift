import Foundation
import XCTest

#if canImport(OpenNOWiOS)
@testable import OpenNOWiOS
#endif

/// Imported Steam Input layouts: reading Valve's file format and running what it describes.
final class SteamInputTests: XCTestCase {
    /// A small layout in Steam's own format, shaped like the community layouts it is modelled on:
    /// two action sets, one layer, a mode shift onto a radial menu, and every press type.
    private static let layout = #"""
    "controller_mappings"
    {
        "version"		"3"
        "title"		"#Title"
        "controller_type"		"controller_neptune"
        "localization" { "english" { "Title" "Test Layout" } }
        "actions"
        {
            "Default" { "title" "On Foot" "legacy_set" "1" }
            "Preset_1000002" { "title" "Flying" "legacy_set" "1" }
        }
        "action_layers"
        {
            "Preset_1000001" { "title" "Bumper Layer" "set_layer" "1" "parent_set_name" "Default" }
        }
        "group"
        {
            "id" "0" "mode" "four_buttons"
            "inputs"
            {
                "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press SPACE, Jump" } } } }
                "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 3" } } } }
                "button_x"
                {
                    "activators"
                    {
                        "Full_Press" { "bindings" { "binding" "key_press 1" } }
                        "Long_Press" { "bindings" { "binding" "key_press 2" } "settings" { "long_press_time" "300" } }
                    }
                }
                "button_y"
                {
                    "activators"
                    {
                        "Double_Press" { "bindings" { "binding" "key_press F" } "settings" { "doubetap_max_duration" "250" } }
                        "Start_Press" { "bindings" { "binding" "key_press G" } }
                        "release" { "bindings" { "binding" "key_press H" } }
                    }
                }
            }
        }
        "group"
        {
            "id" "1" "mode" "switches"
            "inputs"
            {
                "left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action hold_layer 2 0 0" } } } }
                "right_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_SHIFT" } "settings" { "toggle" "1" } } } }
                "button_escape" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action CHANGE_PRESET 3 0 0" } } } }
                "button_menu" { "activators" { "Full_Press" { "bindings" { "binding" "game_action Menus open_map, , " } } } }
                "button_back_right_upper" { "activators" { "Full_Press" { "bindings" { "binding" "mode_shift left_trackpad 6" } } } }
                "button_back_left" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action SHOW_KEYBOARD" } } } }
            }
        }
        "group"
        {
            "id" "2" "mode" "four_buttons"
            "inputs"
            {
                "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 9" } } } }
            }
            "settings" { "layer" "1" }
        }
        "group" { "id" "3" "mode" "trigger" "inputs" { "click" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_button RIGHT" } } } } } "settings" { "output_trigger" "2" } }
        "group" { "id" "4" "mode" "scrollwheel" "inputs"
            {
                "scroll_clockwise" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_wheel SCROLL_DOWN" } } } }
                "scroll_counterclockwise" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_wheel SCROLL_UP" } } } }
            }
            "settings" { "scroll_angle" "45" }
        }
        "group"
        {
            "id" "5" "mode" "radial_menu" "name" "Mounts"
            "inputs"
            {
                "touch_menu_button_0" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_CONTROL, Raptor, @mount.png, " "binding" "key_press 1, Raptor, @mount.png, " } } } }
                "touch_menu_button_1" { "activators" { "Full_Press" { "bindings" { "binding" "key_press K, Skimmer" } } } }
                "touch_menu_button_2" { "activators" { "Full_Press" { "bindings" { "binding" "key_press L, Griffon" } } } }
                "touch_menu_button_3" { "activators" { "Full_Press" { "bindings" { "binding" "key_press M" } } } }
            }
        }
        "group" { "id" "6" "mode" "reference" "settings" { "referenced_mode" "5" } }
        "group" { "id" "7" "mode" "four_buttons" "inputs" { "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button A" } } } } } }
        "group" { "id" "8" "mode" "gyro_to_mouse" "inputs" { } "settings" { "gyro_button" "12" } }
        "group" { "id" "9" "mode" "mouse_region" "inputs" { } }
        "group" { "id" "10" "mode" "switches" "inputs" { "button_escape" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action CHANGE_PRESET 1 0 0" } } } } } }
        "preset"
        {
            "id" "0" "name" "Default"
            "group_source_bindings"
            {
                "0" "button_diamond active"
                "1" "switch active"
                "3" "right_trigger active"
                "4" "left_trackpad active"
                "6" "left_trackpad inactive modeshift"
                "8" "gyro active"
                "9" "right_trackpad active"
                "7" "button_diamond inactive"
            }
        }
        "preset" { "id" "1" "name" "Preset_1000001" "group_source_bindings" { "2" "button_diamond active" } }
        "preset" { "id" "2" "name" "Preset_1000002" "group_source_bindings" { "7" "button_diamond active" "10" "switch active" } }
    }
    """#

    private func report(_ buttons: SteamControllerButtons = [], _ change: (inout SteamControllerReport) -> Void = { _ in }) -> SteamControllerReport {
        var report = SteamControllerReport()
        report.buttons = buttons
        change(&report)
        return report
    }

    private func pressed(_ output: SteamInputEngine.Output) -> [UInt16] {
        output.keys.filter(\.pressed).map(\.virtualKey)
    }

    private func released(_ output: SteamInputEngine.Output) -> [UInt16] {
        output.keys.filter { !$0.pressed }.map(\.virtualKey)
    }

    // MARK: File format

    func testValveKeyValueTextIsParsedWithRepeatedKeysCommentsAndEscapes() throws {
        let value = try XCTUnwrap(SteamVDF.parse(#"""
        // a comment
        "Root" { bare value "quoted \"text\"" "with space"
            "binding" "one" "binding" "two" nested { "deep" "1" } }
        """#))
        let root = try XCTUnwrap(value["root"])
        XCTAssertEqual(root["bare"]?.string, "value")
        XCTAssertEqual(root["quoted \"text\""]?.string, "with space")
        XCTAssertEqual(root.all("binding").compactMap(\.string), ["one", "two"])
        XCTAssertEqual(root["nested"]?["deep"]?.string, "1")
        XCTAssertNil(SteamVDF.parse(#""open" { "never" "closed""#))
        XCTAssertNil(SteamVDF.parse(String(repeating: "\"a\" {", count: 64)))
        XCTAssertThrowsError(try SteamInputConfig(vdf: "not a layout"))
        XCTAssertThrowsError(try SteamInputConfig(vdf: #""controller_mappings" { "title" "Nothing" }"#))
    }

    func testLayoutFileBecomesSetsLayersGroupsAndNotes() throws {
        let config = try SteamInputConfig(vdf: Self.layout)
        XCTAssertEqual(config.title, "Test Layout")
        XCTAssertEqual(config.controllerType, "controller_neptune")
        XCTAssertEqual(config.defaultSet, 0)
        XCTAssertEqual(config.sets[0]?.title, "On Foot")
        XCTAssertEqual(config.sets[1]?.isLayer, true)
        XCTAssertEqual(config.sets[2]?.title, "Flying")
        // Inactive and mode-shift groups are not what a source uses by default.
        XCTAssertEqual(config.sets[0]?.groups[.buttonDiamond], 0)
        XCTAssertEqual(config.sets[0]?.groups[.leftTrackpad], 4)
        // A reference stands for the group it points at.
        XCTAssertEqual(config.groups[6]?.mode, .radialMenu)
        XCTAssertEqual(config.groups[6]?.name, "Mounts")
        XCTAssertEqual(config.groups[5]?.inputs["touch_menu_button_0"]?.first?.bindings, [.key(0xa2), .key(0x31)])
        XCTAssertEqual(config.groups[5]?.inputs["touch_menu_button_0"]?.first?.label, "Raptor")
        XCTAssertEqual(config.groups[0]?.inputs["button_x"]?.map(\.kind), [.fullPress, .longPress])
        XCTAssertEqual(config.groups[0]?.inputs["button_x"]?.last?.longPressTime, 0.3)
        XCTAssertEqual(config.groups[1]?.inputs["left_bumper"]?.first?.bindings, [.holdLayer(1)])
        XCTAssertEqual(config.groups[1]?.inputs["button_escape"]?.first?.bindings, [.changeSet(2)])
        XCTAssertEqual(config.groups[1]?.inputs["button_back_right_upper"]?.first?.bindings, [.modeShift(.leftTrackpad, 6)])
        XCTAssertEqual(config.groups[8]?.gyroActivators, [.init(source: .leftTrigger, input: "edge")])
        XCTAssertEqual(config.groups[8]?.gyroActivation, .whileHeld)
        XCTAssertEqual(config.groups[9]?.mode, .mouseRegion)
        XCTAssertTrue(config.usesGyro)
        // The Steam button is reserved by Steam, so imported layouts get OpenNOW's default for it.
        let system = try XCTUnwrap(config.sets[0]?.groups[.system])
        XCTAssertEqual(config.groups[system]?.inputs["steam"]?.first?.bindings, [.shortcut(.controls)])

        // A control bound to one of the game's own actions is sent as the matching gamepad button.
        XCTAssertEqual(config.groups[1]?.inputs["button_menu"]?.first?.bindings, [.pad(.back)])
        XCTAssertEqual(config.notes.count, 2)
        XCTAssertTrue(config.notes.contains { $0.contains("(1) are bound to the game's own Steam Input actions") })
        XCTAssertTrue(config.notes.contains { $0.contains("show_keyboard") })
    }

    // MARK: Running a layout

    func testLayerChangesOnlyWhatItListsAndAHeldButtonKeepsItsMeaning() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        XCTAssertEqual(pressed(engine.apply(report([.b]), at: 0)), [0x33])
        // The layer comes on while B is still down: B keeps sending 3 until it is let go.
        var output = engine.apply(report([.b, .leftBumper]), at: 0.01)
        XCTAssertTrue(output.keys.isEmpty)
        output = engine.apply(report([.leftBumper]), at: 0.02)
        XCTAssertEqual(released(output), [0x33])
        // In the layer B is 9, and A, which the layer does not mention, is still Space.
        output = engine.apply(report([.leftBumper, .b, .a]), at: 0.03)
        XCTAssertEqual(Set(pressed(output)), [0x39, 0x20])
        output = engine.apply(report([]), at: 0.04)
        XCTAssertEqual(pressed(engine.apply(report([.b]), at: 0.05)), [0x33])
    }

    func testLongDoubleStartAndReleasePressesFollowTheirTiming() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        // X sends 1 at once and adds 2 once it has been held for 300 ms, with no new report needed.
        XCTAssertEqual(pressed(engine.apply(report([.x]), at: 0)), [0x31])
        XCTAssertTrue(engine.advance(to: 0.2).keys.isEmpty)
        XCTAssertEqual(pressed(engine.advance(to: 0.31)), [0x32])
        XCTAssertEqual(Set(released(engine.apply(report(), at: 0.4))), [0x31, 0x32])

        // Y taps G on the way down and H on the way up; each tap ends by itself.
        XCTAssertEqual(pressed(engine.apply(report([.y]), at: 1)), [0x47])
        XCTAssertEqual(released(engine.advance(to: 1.05)), [0x47])
        XCTAssertEqual(pressed(engine.apply(report(), at: 1.06)), [0x48])
        XCTAssertEqual(released(engine.advance(to: 1.12)), [0x48])
        // A second press within 250 ms is a double press and holds F for as long as it is down.
        let double = engine.apply(report([.y]), at: 1.2)
        XCTAssertEqual(Set(pressed(double)), [0x46, 0x47])
        XCTAssertEqual(released(engine.advance(to: 1.3)), [0x47])
        XCTAssertTrue(released(engine.apply(report(), at: 1.4)).contains(0x46))
        _ = engine.advance(to: 1.5)
        // A slow second press is just another press.
        XCTAssertEqual(pressed(engine.apply(report([.y]), at: 3)), [0x47])
    }

    func testToggleSetChangeTriggerAndGameActions() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        // The right bumper toggles Shift: on with one press, off with the next.
        XCTAssertEqual(pressed(engine.apply(report([.rightBumper]), at: 0)), [0xa0])
        XCTAssertTrue(engine.apply(report(), at: 0.1).keys.isEmpty)
        XCTAssertEqual(released(engine.apply(report([.rightBumper]), at: 0.2)), [0xa0])
        _ = engine.apply(report(), at: 0.3)

        // The trigger keeps its analog travel and clicks the right mouse button at the end of it.
        var output = engine.apply(report { $0.rightTrigger = 0.5 }, at: 0.4)
        XCTAssertEqual(output.pad.rightTrigger, 128)
        XCTAssertTrue(output.mouseButtons.isEmpty)
        output = engine.apply(report([.rightTriggerClick]) { $0.rightTrigger = 1 }, at: 0.5)
        XCTAssertEqual(output.mouseButtons, [.init(button: 3, pressed: true)])
        _ = engine.apply(report(), at: 0.6)

        // A binding to the game's own actions reaches the host as the gamepad's View button.
        XCTAssertEqual(engine.apply(report([.view]), at: 0.7).pad.buttons, 0x0020)
        _ = engine.apply(report(), at: 0.8)

        // Menu switches to the Flying set, where A is the gamepad's A, and back again.
        XCTAssertNil(SteamInputEngine(layout: .init()).actionSetTitle)
        XCTAssertEqual(engine.actionSetTitle, "On Foot")
        _ = engine.apply(report([.menu]), at: 0.9)
        XCTAssertEqual(engine.actionSetTitle, "Flying")
        _ = engine.apply(report(), at: 1)
        output = engine.apply(report([.a]), at: 1.1)
        XCTAssertEqual(output.pad.buttons, 0x1000)
        XCTAssertTrue(output.keys.isEmpty)
        _ = engine.apply(report(), at: 1.2)
        _ = engine.apply(report([.menu]), at: 1.3)
        XCTAssertEqual(engine.actionSetTitle, "On Foot")
    }

    func testCirclingThePadTurnsTheWheelAStepPerSoManyDegrees() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        func at(_ degrees: Double) -> SteamControllerReport {
            report([.leftPadTouch]) {
                $0.leftPad = .init(x: Float(0.8 * sin(degrees * .pi / 180)), y: Float(0.8 * cos(degrees * .pi / 180)))
            }
        }
        var wheel = 0
        for (index, degrees) in stride(from: 0.0, through: 100, by: 10).enumerated() {
            wheel += engine.apply(at(degrees), at: Double(index) * 0.01).wheel
        }
        // 100 degrees clockwise at 45 degrees a step is two steps down.
        XCTAssertEqual(wheel, -240)
        // Turning back first uses up the 10 degrees left over, so 60 degrees is one step up.
        wheel = 0
        for (index, degrees) in stride(from: 100.0, through: 40, by: -10).enumerated() {
            wheel += engine.apply(at(degrees), at: 1 + Double(index) * 0.01).wheel
        }
        XCTAssertEqual(wheel, 120)
    }

    func testModeShiftOpensAMenuThatIsShownAndPickedOnRelease() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        _ = engine.apply(report([.r4]), at: 0)
        XCTAssertTrue(engine.menus.isEmpty)
        // With the shift held, a thumb on the pad opens the menu; pointing right is the second of four.
        _ = engine.apply(report([.r4, .leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0) }, at: 0.01)
        XCTAssertEqual(engine.menus, [.init(source: .leftTrackpad, radial: true, title: "Mounts",
                                            items: ["Raptor", "Skimmer", "Griffon", "M"], selected: nil)])
        _ = engine.apply(report([.r4, .leftPadTouch]) { $0.leftPad = .init(x: 0.9, y: 0) }, at: 0.02)
        XCTAssertEqual(engine.menus.first?.selected, 1)
        _ = engine.apply(report([.r4, .leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0.9) }, at: 0.03)
        XCTAssertEqual(engine.menus.first?.selected, 0)
        // A click picks it: the item's keys go down together, modifier first, and come back up.
        let picked = engine.apply(report([.r4, .leftPadTouch, .leftPadClick]) { $0.leftPad = .init(x: 0, y: 0.9) }, at: 0.04)
        XCTAssertEqual(picked.keys, [.init(virtualKey: 0xa2, pressed: true, modifiers: 0x02),
                                     .init(virtualKey: 0x31, pressed: true, modifiers: 0x02)])
        XCTAssertEqual(released(engine.advance(to: 0.1)), [0x31, 0xa2])
        // Letting the shift go closes the menu and gives the pad back to the wheel.
        _ = engine.apply(report([.leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0.9) }, at: 0.2)
        _ = engine.apply(report([.leftPadTouch]) { $0.leftPad = .init(x: 0, y: 0.9) }, at: 0.21)
        XCTAssertTrue(engine.menus.isEmpty)
    }

    func testMenuGeometryMatchesWhatIsDrawn() {
        XCTAssertNil(SteamInputEngine.radialItem(.init(x: 0.1, y: 0.1), count: 6))
        XCTAssertEqual(SteamInputEngine.radialItem(.init(x: 0, y: 1), count: 6), 0)
        XCTAssertEqual(SteamInputEngine.radialItem(.init(x: 1, y: 0), count: 4), 1)
        XCTAssertEqual(SteamInputEngine.radialItem(.init(x: 0, y: -1), count: 4), 2)
        XCTAssertEqual(SteamInputEngine.radialItem(.init(x: -1, y: 0), count: 4), 3)
        // Seven items lie in three columns: the top left is the first, the bottom left the last.
        XCTAssertEqual(SteamInputEngine.gridColumns(count: 7), 3)
        XCTAssertEqual(SteamInputEngine.gridItem(.init(x: -0.9, y: 0.9), count: 7), 0)
        XCTAssertEqual(SteamInputEngine.gridItem(.init(x: 0.9, y: 0.9), count: 7), 2)
        XCTAssertEqual(SteamInputEngine.gridItem(.init(x: -0.9, y: -0.9), count: 7), 6)
        XCTAssertNil(SteamInputEngine.gridItem(.init(x: 0.9, y: -0.9), count: 7))
    }

    func testImportedGyroFollowsItsEnableButton() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        let turning: (inout SteamControllerReport) -> Void = { $0.gyroYaw = 1; $0.gyroInterval = 0.01 }
        XCTAssertEqual(engine.apply(report([], turning), at: 0).mouse, .zero)
        let aiming = engine.apply(report { $0.gyroYaw = 1; $0.gyroInterval = 0.01; $0.leftTrigger = 0.6 }, at: 0.01)
        XCTAssertEqual(aiming.mouse.x, -(180 / Double.pi) * 0.01 * 20, accuracy: 0.001)
    }

    // MARK: Modes that place the pointer, scroll and flick

    /// A layout with one set, built directly: each source given a group in the wanted mode.
    private func config(_ modes: [SteamInputConfig.Source: SteamInputConfig.Group]) -> SteamInputConfig {
        var config = SteamInputConfig()
        var set = SteamInputConfig.ActionSet(id: 0)
        for (source, group) in modes {
            config.groups[group.id] = group
            set.groups[source] = group.id
        }
        config.sets[0] = set
        return config
    }

    func testMouseRegionPlacesThePointerWhereTheThumbIs() throws {
        var engine = SteamInputEngine(config: try SteamInputConfig(vdf: Self.layout))
        // The right trackpad covers the whole screen: up and to the right of centre on the pad
        // is up and to the right of centre on the screen.
        var output = engine.apply(report([.rightPadTouch]) { $0.rightPad = .init(x: 0.5, y: 0.5) }, at: 0)
        XCTAssertEqual(try XCTUnwrap(output.absolute).x, 0.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(output.absolute).y, 0.25, accuracy: 0.001)
        XCTAssertEqual(output.mouse, .zero)
        // A thumb that has not moved sends nothing more.
        output = engine.apply(report([.rightPadTouch]) { $0.rightPad = .init(x: 0.5, y: 0.5) }, at: 0.01)
        XCTAssertNil(output.absolute)

        // A region can be a smaller part of the screen, placed off centre.
        engine = SteamInputEngine(config: config([.rightTrackpad: .init(
            id: 0, mode: .mouseRegion, settings: ["scale": 50, "position_x": 25, "position_y": 80])]))
        output = engine.apply(report([.rightPadTouch]) { $0.rightPad = .init(x: 1, y: -1) }, at: 0)
        XCTAssertEqual(try XCTUnwrap(output.absolute).x, 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(output.absolute).y, 1, accuracy: 0.001)
    }

    func testTwoWayScrollAndCalibrationScaleWhatTheLayoutAsksFor() {
        var engine = SteamInputEngine(config: config([
            .leftTrackpad: .init(id: 0, mode: .scroll2D), .rightTrackpad: .init(id: 1, mode: .absoluteMouse)]))
        func swipe(_ engine: inout SteamInputEngine) -> SteamInputEngine.Output {
            _ = engine.apply(report([.leftPadTouch, .rightPadTouch]), at: 0)
            return engine.apply(report([.leftPadTouch, .rightPadTouch]) {
                $0.leftPad = .init(x: 0.2, y: -0.1)
                $0.rightPad = .init(x: 0.1, y: 0)
            }, at: 0.01)
        }
        var output = swipe(&engine)
        XCTAssertEqual(output.wheelX, 240)
        XCTAssertEqual(output.wheel, -120)
        XCTAssertEqual(output.mouse.x, 60, accuracy: 0.001)

        engine = SteamInputEngine(config: engine.config)
        engine.tuning.scroll = 50
        engine.tuning.trackpadMouse = 200
        output = swipe(&engine)
        XCTAssertEqual(output.wheelX, 120)
        XCTAssertEqual(output.wheel, -60)
        XCTAssertEqual(output.mouse.x, 120, accuracy: 0.001)
    }

    func testFlickStickTurnsToFaceWhereItIsPushedAndFollowsASweep() {
        var engine = SteamInputEngine(config: config([.rightJoystick: .init(id: 0, mode: .flickStick)]))
        engine.tuning.flickTurn = 4_000
        _ = engine.apply(report(), at: 0)
        // Pushed straight right: a quarter turn, 1000 counts, spread over a tenth of a second.
        var travel = engine.apply(report { $0.rightStick = .init(x: 1, y: 0) }, at: 0.01).mouse.x
        for tick in 2...15 { travel += engine.advance(to: Double(tick) * 0.01).mouse.x }
        XCTAssertEqual(travel, 1_000, accuracy: 0.5)
        // Swept from right round to straight back: another quarter turn, at once.
        let sweep = engine.apply(report { $0.rightStick = .init(x: 0, y: -1) }, at: 0.2).mouse.x
        XCTAssertEqual(sweep, 1_000, accuracy: 0.5)
        // Let go and pushed left: a quarter turn the other way. The stick itself sends nothing.
        _ = engine.apply(report(), at: 0.3)
        var back = engine.apply(report { $0.rightStick = .init(x: -1, y: 0) }, at: 0.31)
        XCTAssertEqual(back.pad, SteamInputEngine.Pad())
        var total = back.mouse.x
        for tick in 32...45 {
            back = engine.advance(to: Double(tick) * 0.01)
            total += back.mouse.x
        }
        XCTAssertEqual(total, -1_000, accuracy: 0.5)
    }

    func testGyroButtonSetCanToggleOrPauseTheGyro() throws {
        func layout(_ settings: String) -> String {
            #""controller_mappings" { "group" { "id" "0" "mode" "gyro_to_mouse" "settings" { \#(settings) } }"#
                + #" "preset" { "id" "0" "name" "Default" "group_source_bindings" { "0" "gyro active" } } }"#
        }
        let turning: (inout SteamControllerReport) -> Void = { $0.gyroYaw = 1; $0.gyroInterval = 0.01 }
        func moves(_ engine: inout SteamInputEngine, _ buttons: SteamControllerButtons, at time: TimeInterval) -> Bool {
            engine.apply(report(buttons, turning), at: time).mouse != .zero
        }

        // Bit 16 is the right back button; setting 2 makes it a toggle.
        var config = try SteamInputConfig(vdf: layout(#""gyro_ratchet_button_mask" "65536" "gyro_button_invert" "2""#))
        XCTAssertEqual(config.groups[0]?.gyroActivators, [.init(source: .switches, input: "button_back_right")])
        var engine = SteamInputEngine(config: config)
        XCTAssertFalse(moves(&engine, [], at: 0))
        XCTAssertTrue(moves(&engine, [.r5], at: 0.01))
        XCTAssertTrue(moves(&engine, [], at: 0.02))
        XCTAssertFalse(moves(&engine, [.r5], at: 0.03))

        // Setting 1 turns it round: the gyro works until the button is held.
        config = try SteamInputConfig(vdf: layout(#""gyro_ratchet_button_mask" "64" "gyro_button_invert" "1""#))
        XCTAssertEqual(config.groups[0]?.gyroActivators, [.init(source: .buttonDiamond, input: "button_x")])
        engine = SteamInputEngine(config: config)
        XCTAssertTrue(moves(&engine, [], at: 0))
        XCTAssertFalse(moves(&engine, [.x], at: 0.01))

        // A button the pad report has no place for is said so, and the rest still applies.
        config = try SteamInputConfig(vdf: layout(#""gyro_ratchet_button_mask" "140737488355332""#))
        XCTAssertEqual(config.groups[0]?.gyroActivators, [.init(source: .switches, input: "right_bumper")])
        XCTAssertTrue(config.notes.contains { $0.contains("button 47") })
    }

    func testMenuItemsWithoutALabelShowWhatTheySend() throws {
        let config = try SteamInputConfig(vdf: Self.layout)
        XCTAssertEqual(config.groups[5]?.inputs["touch_menu_button_3"]?.first?.displayLabel, "M")
        XCTAssertEqual(SteamInputConfig.Activator(bindings: [.key(0xa3), .key(0x31)]).displayLabel, "Ctrl+1")
    }

    // MARK: Library

    func testWorkshopIdentifiersAreFoundInLinksAndPlainNumbers() {
        XCTAssertEqual(SteamLayoutLibrary.workshopID(in: "steam://controllerconfig/413080/2866090215"), "2866090215")
        XCTAssertEqual(SteamLayoutLibrary.workshopID(in: "https://steamcommunity.com/sharedfiles/filedetails/?id=2866090215&searchtext="), "2866090215")
        XCTAssertEqual(SteamLayoutLibrary.workshopID(in: "  2866090215 "), "2866090215")
        XCTAssertNil(SteamLayoutLibrary.workshopID(in: "steam://controllerconfig/42/7"))
        XCTAssertNil(SteamLayoutLibrary.workshopID(in: "no numbers here"))
    }

    func testLibraryKeepsImportedLayoutsAcrossLaunchesAndChoosesByGame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steam-layouts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SteamLayoutLibrary(directory: directory)
        XCTAssertThrowsError(try library.add(vdf: "nothing useful")) {
            XCTAssertEqual($0 as? SteamLayoutLibrary.ImportFailure, .notALayout)
        }
        let entry = try library.add(vdf: Self.layout, workshopID: "2866090215", fallbackTitle: "Fallback")
        XCTAssertEqual(entry.title, "Test Layout")
        XCTAssertEqual(entry.notes.count, 2)
        // The same Workshop layout imported again replaces the first copy.
        XCTAssertEqual(try library.add(vdf: Self.layout, workshopID: "2866090215").id, entry.id)
        XCTAssertEqual(library.entries.count, 1)

        // Re-binding one control changes that set only and leaves the published file as it was.
        library.setOverride(.key(0x51), layout: entry.id, set: 0, source: .buttonDiamond, input: "button_a")
        library.setOverride(.pad(.x), layout: entry.id, set: 0, source: .switches, input: "button_back_left_upper")
        var changed = SteamInputEngine(config: try XCTUnwrap(library.config(for: entry.id)))
        XCTAssertEqual(pressed(changed.apply(report([.a]), at: 0)), [0x51])
        XCTAssertEqual(changed.apply(report([.a, .l4]), at: 0.01).pad.buttons, 0x4000)
        XCTAssertEqual(library.published(entry.id)?.groups[0]?.inputs["button_a"]?.first?.bindings, [.key(0x20)])
        // A fresh import of the same layout keeps the player's changes.
        XCTAssertEqual(try library.add(vdf: Self.layout, workshopID: "2866090215").overrides.count, 2)

        let reopened = SteamLayoutLibrary(directory: directory)
        XCTAssertEqual(reopened.entries, library.entries)
        XCTAssertEqual(reopened.config(for: entry.id)?.title, "Test Layout")
        reopened.setOverride(nil, layout: entry.id, set: 0, source: .buttonDiamond, input: "button_a")
        XCTAssertEqual(reopened.config(for: entry.id)?.sets[0]?.groups[.buttonDiamond], 0)
        XCTAssertNil(reopened.config(for: "missing"))
        reopened.remove(entry.id)
        XCTAssertTrue(SteamLayoutLibrary(directory: directory).entries.isEmpty)

        var settings = AppSettings.default
        settings.steamControllerActiveLayout = "general"
        settings.steamControllerGameLayouts[SteamLayoutLibrary.gameKey(" World of Warcraft ")] = "wow"
        XCTAssertEqual(settings.steamControllerLayoutID(forGame: "world of warcraft"), "wow")
        XCTAssertEqual(settings.steamControllerLayoutID(forGame: "Another Game"), "general")
        XCTAssertEqual(settings.steamControllerLayoutID(forGame: nil), "general")
        // An unknown layout falls back to the one made in OpenNOW.
        XCTAssertEqual(settings.steamControllerConfig(forGame: nil), settings.steamControllerLayout.steamInputConfig)
    }

    // MARK: Search

    func testSearchAsksForOneGamesPublicLayoutsAndReadsWhatSteamSendsBack() throws {
        var query = SteamLayoutSearch.query(app: "world of warcraft", text: "", controllerType: "controller_triton")
        XCTAssertEqual(query["appid"] as? Int, 241100)
        XCTAssertEqual(query["filetype"] as? Int, 15)
        XCTAssertEqual(query["query_type"] as? Int, 9)
        XCTAssertNil(query["search_text"])
        XCTAssertEqual(query["requiredtags"] as? [String], ["controller_triton"])
        XCTAssertEqual(query["required_kv_tags"] as? [[String: String]],
                       [["key": "app", "value": "world of warcraft"], ["key": "visibility", "value": "public"]])
        query = SteamLayoutSearch.query(app: "1245620", text: " healer ", controllerType: nil)
        XCTAssertEqual(query["query_type"] as? Int, 12)
        XCTAssertEqual(query["search_text"] as? String, "healer")
        XCTAssertNil(query["requiredtags"])

        // Steam sends numbers as text in these responses, and failed entries with no result.
        let response = #"""
        {"response":{"total":3,"publishedfiledetails":[
          {"result":"1","publishedfileid":"3841056311","title":"MMO layout","short_description":"For MMOs.",
           "lifetime_subscriptions":"42","tags":[{"tag":"hasactivators"},{"tag":"controller_triton"},
           {"tag":"feature_gyro"},{"tag":"feature_touchmenu"}]},
          {"result":1,"publishedfileid":"275850","title":"Official","lifetime_subscriptions":7,
           "tags":[{"tag":"controller_native"},{"tag":"controller_neptune"}]},
          {"result":"9","publishedfileid":"1"},
          {"result":"1","publishedfileid":"not-a-number"}
        ]}}
        """#
        let results = SteamLayoutSearch.results(from: Data(response.utf8))
        XCTAssertEqual(results, [
            .init(id: "3841056311", title: "MMO layout", summary: "For MMOs.", controllerType: "controller_triton",
                  features: ["gyro", "touch menu"], usesNativeActions: false, subscriptions: 42),
            .init(id: "275850", title: "Official", summary: "", controllerType: "controller_neptune",
                  features: [], usesNativeActions: true, subscriptions: 7)
        ])
        XCTAssertEqual(results.first?.controllerName, "Steam Controller")
        XCTAssertTrue(SteamLayoutSearch.results(from: Data(#"{"response":{}}"#.utf8)).isEmpty)
    }
}
