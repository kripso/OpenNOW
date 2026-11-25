import CoreGraphics
import Foundation

/// Every control on the pad that can be pressed or held, including its touch sensors.
enum SteamControl: String, CaseIterable, Codable, Identifiable {
    case a, b, x, y
    case leftBumper, rightBumper, leftTrigger, rightTrigger
    case view, menu, steam, quickAccess
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftStickClick, rightStickClick
    case l4, l5, r4, r5
    case leftPadClick, rightPadClick
    case leftPadTouch, rightPadTouch, leftStickTouch, rightStickTouch, leftGrip, rightGrip

    var id: String { rawValue }

    /// The report flag for this control; the triggers are analog and have none.
    var button: SteamControllerButtons? {
        switch self {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .leftBumper: return .leftBumper
        case .rightBumper: return .rightBumper
        case .leftTrigger, .rightTrigger: return nil
        case .view: return .view
        case .menu: return .menu
        case .steam: return .steam
        case .quickAccess: return .quickAccess
        case .dpadUp: return .dpadUp
        case .dpadDown: return .dpadDown
        case .dpadLeft: return .dpadLeft
        case .dpadRight: return .dpadRight
        case .leftStickClick: return .leftStickClick
        case .rightStickClick: return .rightStickClick
        case .l4: return .l4
        case .l5: return .l5
        case .r4: return .r4
        case .r5: return .r5
        case .leftPadClick: return .leftPadClick
        case .rightPadClick: return .rightPadClick
        case .leftPadTouch: return .leftPadTouch
        case .rightPadTouch: return .rightPadTouch
        case .leftStickTouch: return .leftStickTouch
        case .rightStickTouch: return .rightStickTouch
        case .leftGrip: return .leftGrip
        case .rightGrip: return .rightGrip
        }
    }

    /// What the control does until the player chooses otherwise: the pad behaves as an ordinary
    /// gamepad, the Steam button opens the stream controls, and the right trackpad clicks.
    var defaultAction: ControllerAction {
        switch self {
        case .a: return .pad(.a)
        case .b: return .pad(.b)
        case .x: return .pad(.x)
        case .y: return .pad(.y)
        case .leftBumper: return .pad(.lb)
        case .rightBumper: return .pad(.rb)
        case .leftTrigger: return .pad(.lt)
        case .rightTrigger: return .pad(.rt)
        case .view: return .pad(.back)
        case .menu: return .pad(.start)
        case .steam: return .shortcut(.controls)
        case .dpadUp: return .pad(.up)
        case .dpadDown: return .pad(.down)
        case .dpadLeft: return .pad(.left)
        case .dpadRight: return .pad(.right)
        case .leftStickClick: return .pad(.ls)
        case .rightStickClick: return .pad(.rs)
        case .rightPadClick: return .mouse(1)
        case .quickAccess, .l4, .l5, .r4, .r5, .leftPadClick,
             .leftPadTouch, .rightPadTouch, .leftStickTouch, .rightStickTouch, .leftGrip, .rightGrip:
            return .none
        }
    }
}

enum ControllerPadButton: String, CaseIterable, Identifiable {
    case a, b, x, y, lb, rb, lt, rt, ls, rs, back, start, guide, up, down, left, right

    var id: String { rawValue }

    /// The bit in the gamepad packet; the triggers are separate analog fields.
    var mask: UInt16 {
        switch self {
        case .a: return 0x1000
        case .b: return 0x2000
        case .x: return 0x4000
        case .y: return 0x8000
        case .lb: return 0x0100
        case .rb: return 0x0200
        case .ls: return 0x0040
        case .rs: return 0x0080
        case .back: return 0x0020
        case .start: return 0x0010
        case .guide: return 0x0400
        case .up: return 0x0001
        case .down: return 0x0002
        case .left: return 0x0004
        case .right: return 0x0008
        case .lt, .rt: return 0
        }
    }
}

/// What one control sends. Stored as a short token so layouts stay readable and tolerate
/// values a later version adds.
enum ControllerAction: Hashable {
    case none
    case pad(ControllerPadButton)
    /// A Windows virtual-key code.
    case key(UInt16)
    /// 1 left, 2 middle, 3 right.
    case mouse(Int)
    /// One notch per press: +1 up, -1 down.
    case wheel(Int)
    case shortcut(NativeStreamControllerShortcutAction)

    init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return nil }
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "none":
            self = .none
        case "pad":
            guard let button = ControllerPadButton(rawValue: value) else { return nil }
            self = .pad(button)
        case "key":
            guard let code = UInt16(value), (1...254).contains(code) else { return nil }
            self = .key(code)
        case "mouse":
            switch value {
            case "left": self = .mouse(1)
            case "middle": self = .mouse(2)
            case "right": self = .mouse(3)
            default: return nil
            }
        case "wheel":
            switch value {
            case "up": self = .wheel(1)
            case "down": self = .wheel(-1)
            default: return nil
            }
        case "app":
            guard let action = NativeStreamControllerShortcutAction(rawValue: value), action != .none else { return nil }
            self = .shortcut(action)
        default:
            return nil
        }
    }

    var token: String {
        switch self {
        case .none: return "none"
        case .pad(let button): return "pad:\(button.rawValue)"
        case .key(let code): return "key:\(code)"
        case .mouse(let button): return "mouse:\(button == 2 ? "middle" : button == 3 ? "right" : "left")"
        case .wheel(let direction): return "wheel:\(direction < 0 ? "down" : "up")"
        case .shortcut(let action): return "app:\(action.rawValue)"
        }
    }
}

/// The four analog surfaces.
enum SteamSurface: String, CaseIterable, Identifiable {
    case leftStick, rightStick, leftPad, rightPad

    var id: String { rawValue }
    var isPad: Bool { self == .leftPad || self == .rightPad }

    var defaultMode: ControllerSurfaceMode {
        switch self {
        case .leftStick: return .leftStick
        case .rightStick: return .rightStick
        case .leftPad: return .scroll
        case .rightPad: return .mouse
        }
    }
}

enum ControllerSurfaceMode: String, CaseIterable, Identifiable {
    case none, leftStick, rightStick, mouse, scroll, dpad, wasd, arrows

    var id: String { rawValue }
}

enum ControllerGyroMode: String, CaseIterable, Identifiable {
    case off, mouse, rightStick

    var id: String { rawValue }
}

/// How the player wants the pad to behave. Anything missing or unknown means the default, so a
/// saved layout keeps loading as controls and options are added.
struct SteamControllerLayout: Codable, Equatable {
    static let sensitivityRange = 10...500
    static let gyroSensitivityKey = "gyro"

    private(set) var buttons: [String: String] = [:]
    private(set) var surfaces: [String: String] = [:]
    private(set) var sensitivities: [String: Int] = [:]
    private(set) var gyro: String = ControllerGyroMode.off.rawValue
    /// The control that must be held for the gyro to act; empty means always.
    private(set) var gyroActivation: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: String].self, forKey: .buttons) ?? [:]
        surfaces = try container.decodeIfPresent([String: String].self, forKey: .surfaces) ?? [:]
        sensitivities = try container.decodeIfPresent([String: Int].self, forKey: .sensitivities) ?? [:]
        gyro = try container.decodeIfPresent(String.self, forKey: .gyro) ?? ControllerGyroMode.off.rawValue
        gyroActivation = try container.decodeIfPresent(String.self, forKey: .gyroActivation) ?? ""
    }

    func action(for control: SteamControl) -> ControllerAction {
        buttons[control.rawValue].flatMap(ControllerAction.init(token:)) ?? control.defaultAction
    }

    mutating func setAction(_ action: ControllerAction, for control: SteamControl) {
        buttons[control.rawValue] = action == control.defaultAction ? nil : action.token
    }

    func mode(for surface: SteamSurface) -> ControllerSurfaceMode {
        surfaces[surface.rawValue].flatMap(ControllerSurfaceMode.init(rawValue:)) ?? surface.defaultMode
    }

    mutating func setMode(_ mode: ControllerSurfaceMode, for surface: SteamSurface) {
        surfaces[surface.rawValue] = mode == surface.defaultMode ? nil : mode.rawValue
    }

    var gyroMode: ControllerGyroMode {
        get { ControllerGyroMode(rawValue: gyro) ?? .off }
        set { gyro = newValue.rawValue }
    }

    var gyroActivator: SteamControl? {
        get { SteamControl(rawValue: gyroActivation) }
        set { gyroActivation = newValue?.rawValue ?? "" }
    }

    /// A percentage; `key` is a surface's raw value or `gyroSensitivityKey`.
    func sensitivity(_ key: String) -> Int {
        let range = Self.sensitivityRange
        return min(max(sensitivities[key] ?? 100, range.lowerBound), range.upperBound)
    }

    mutating func setSensitivity(_ value: Int, for key: String) {
        let range = Self.sensitivityRange
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        sensitivities[key] = clamped == 100 ? nil : clamped
    }

    /// A starting point for games played with mouse and keyboard: the left stick walks, the right
    /// stick and trackpad aim, and the triggers click.
    static var keyboardAndMouse: SteamControllerLayout {
        var layout = SteamControllerLayout()
        layout.setMode(.wasd, for: .leftStick)
        layout.setMode(.mouse, for: .rightStick)
        layout.setAction(.mouse(1), for: .rightTrigger)
        layout.setAction(.mouse(3), for: .leftTrigger)
        layout.setAction(.key(0x20), for: .a)
        layout.setAction(.key(0x09), for: .b)
        layout.setAction(.key(0x45), for: .x)
        layout.setAction(.key(0x46), for: .y)
        layout.setAction(.key(0xa0), for: .leftBumper)
        layout.setAction(.key(0xa2), for: .rightBumper)
        layout.setAction(.key(0x4d), for: .view)
        layout.setAction(.key(0x1b), for: .menu)
        layout.setAction(.key(0x31), for: .dpadUp)
        layout.setAction(.key(0x32), for: .dpadRight)
        layout.setAction(.key(0x33), for: .dpadDown)
        layout.setAction(.key(0x34), for: .dpadLeft)
        layout.setAction(.mouse(2), for: .rightStickClick)
        return layout
    }
}

extension ControllerAction {
    /// This action as a Steam Input layout expresses it.
    var bindings: [SteamInputConfig.Binding] {
        switch self {
        case .none: return []
        case .pad(let button): return [.pad(button)]
        case .key(let code): return [.key(code)]
        case .mouse(let button): return [.mouseButton(button)]
        case .wheel(let direction): return [.wheel(direction)]
        case .shortcut(let shortcut): return [.shortcut(shortcut)]
        }
    }
}

extension SteamControl {
    /// Where this control lives in a Steam Input layout.
    var inputRef: SteamInputConfig.InputRef {
        typealias Ref = SteamInputConfig.InputRef
        switch self {
        case .a: return Ref(source: .buttonDiamond, input: "button_a")
        case .b: return Ref(source: .buttonDiamond, input: "button_b")
        case .x: return Ref(source: .buttonDiamond, input: "button_x")
        case .y: return Ref(source: .buttonDiamond, input: "button_y")
        case .leftBumper: return Ref(source: .switches, input: "left_bumper")
        case .rightBumper: return Ref(source: .switches, input: "right_bumper")
        case .leftTrigger: return Ref(source: .leftTrigger, input: "edge")
        case .rightTrigger: return Ref(source: .rightTrigger, input: "edge")
        case .view: return Ref(source: .switches, input: "button_menu")
        case .menu: return Ref(source: .switches, input: "button_escape")
        case .steam: return Ref(source: .system, input: "steam")
        case .quickAccess: return Ref(source: .switches, input: "button_capture")
        case .dpadUp: return Ref(source: .dpad, input: "dpad_north")
        case .dpadDown: return Ref(source: .dpad, input: "dpad_south")
        case .dpadLeft: return Ref(source: .dpad, input: "dpad_west")
        case .dpadRight: return Ref(source: .dpad, input: "dpad_east")
        case .leftStickClick: return Ref(source: .joystick, input: "click")
        case .rightStickClick: return Ref(source: .rightJoystick, input: "click")
        case .l4: return Ref(source: .switches, input: "button_back_left_upper")
        case .l5: return Ref(source: .switches, input: "button_back_left")
        case .r4: return Ref(source: .switches, input: "button_back_right_upper")
        case .r5: return Ref(source: .switches, input: "button_back_right")
        case .leftPadClick: return Ref(source: .leftTrackpad, input: "click")
        case .rightPadClick: return Ref(source: .rightTrackpad, input: "click")
        case .leftPadTouch: return Ref(source: .leftTrackpad, input: "touch")
        case .rightPadTouch: return Ref(source: .rightTrackpad, input: "touch")
        case .leftStickTouch: return Ref(source: .joystick, input: "touch")
        case .rightStickTouch: return Ref(source: .rightJoystick, input: "touch")
        case .leftGrip: return Ref(source: .system, input: "left_grip")
        case .rightGrip: return Ref(source: .system, input: "right_grip")
        }
    }
}

extension SteamSurface {
    var source: SteamInputConfig.Source {
        switch self {
        case .leftStick: return .joystick
        case .rightStick: return .rightJoystick
        case .leftPad: return .leftTrackpad
        case .rightPad: return .rightTrackpad
        }
    }
}

extension SteamControllerLayout {
    /// This layout in Steam Input's terms, which is what the engine runs.
    var steamInputConfig: SteamInputConfig {
        typealias Config = SteamInputConfig
        var config = Config()
        var set = Config.ActionSet(id: 0)

        func bindings(_ action: ControllerAction) -> [Config.Binding] { action.bindings }
        func add(_ source: Config.Source, mode: Config.Mode, settings: [String: Double] = [:],
                 controls: [SteamControl] = [], configure: (inout Config.Group) -> Void = { _ in }) {
            var group = Config.Group(id: config.groups.count, mode: mode, settings: settings)
            for control in controls where control.inputRef.source == source {
                group.inputs[control.inputRef.input] = [Config.Activator(bindings: bindings(action(for: control)))]
            }
            configure(&group)
            config.groups[group.id] = group
            set.groups[source] = group.id
        }

        add(.buttonDiamond, mode: .fourButtons, controls: SteamControl.allCases)
        add(.switches, mode: .switches, controls: SteamControl.allCases)
        add(.dpad, mode: .dpad, controls: SteamControl.allCases)
        add(.system, mode: .switches, controls: SteamControl.allCases)
        for (source, control) in [(Config.Source.leftTrigger, SteamControl.leftTrigger), (.rightTrigger, .rightTrigger)] {
            // A trigger that still drives a trigger keeps its analog travel; anything else is a press.
            switch action(for: control) {
            case .pad(.lt): add(source, mode: .trigger, settings: ["output_trigger": 1])
            case .pad(.rt): add(source, mode: .trigger, settings: ["output_trigger": 2])
            default: add(source, mode: .trigger, controls: [control])
            }
        }
        for surface in SteamSurface.allCases {
            let source = surface.source
            var settings = ["sensitivity": Double(sensitivity(surface.rawValue))]
            let mode: Config.Mode
            var directions: [Config.Binding]?
            switch self.mode(for: surface) {
            case .none: mode = .singleButton
            case .leftStick:
                mode = .joystickMove
                settings["output_joystick"] = 0
            case .rightStick:
                mode = .joystickMove
                settings["output_joystick"] = 1
            case .mouse: mode = surface.isPad ? .absoluteMouse : .joystickMouse
            case .scroll: mode = .linearScroll
            case .dpad:
                mode = .dpad
                directions = [.pad(.up), .pad(.down), .pad(.left), .pad(.right)]
            case .wasd:
                mode = .dpad
                directions = [.key(0x57), .key(0x53), .key(0x41), .key(0x44)]
            case .arrows:
                mode = .dpad
                directions = [.key(0x26), .key(0x28), .key(0x25), .key(0x27)]
            }
            add(source, mode: mode, settings: settings, controls: SteamControl.allCases) { group in
                guard let directions else { return }
                for (input, binding) in zip(["dpad_north", "dpad_south", "dpad_west", "dpad_east"], directions) {
                    group.inputs[input] = [Config.Activator(bindings: [binding])]
                }
            }
        }
        if gyroMode != .off {
            add(.gyro, mode: gyroMode == .mouse ? .gyroToMouse : .gyroToJoystick,
                settings: ["sensitivity": Double(sensitivity(Self.gyroSensitivityKey))]) { group in
                group.gyroActivators = gyroActivator.map { [$0.inputRef] } ?? []
            }
        }
        config.sets[0] = set
        return config
    }
}

/// The player's own scaling of pointer, gyro and wheel output, applied to whichever layout is in
/// use. Layouts do not carry the game's pointer speed, so matching the feel of another device is
/// done here.
struct SteamControllerTuning: Codable, Equatable {
    static let percentRange = 10...500
    static let flickTurnRange = 500...20_000
    static let stickDeadZoneRange = 0...40

    /// Percentages.
    var trackpadMouse = 100
    var stickMouse = 100
    var gyro = 100
    var scroll = 100
    /// How far the pointer must travel to turn the view once round, for flick stick.
    var flickTurn = 4_000
    /// Percent of stick travel ignored around the centre, whatever the stick drives.
    var stickDeadZone = 12

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func percent(_ key: CodingKeys) throws -> Int {
            let value = try container.decodeIfPresent(Int.self, forKey: key) ?? 100
            return min(max(value, Self.percentRange.lowerBound), Self.percentRange.upperBound)
        }
        trackpadMouse = try percent(.trackpadMouse)
        stickMouse = try percent(.stickMouse)
        gyro = try percent(.gyro)
        scroll = try percent(.scroll)
        let turn = try container.decodeIfPresent(Int.self, forKey: .flickTurn) ?? 4_000
        flickTurn = min(max(turn, Self.flickTurnRange.lowerBound), Self.flickTurnRange.upperBound)
        let deadZone = try container.decodeIfPresent(Int.self, forKey: .stickDeadZone) ?? 12
        stickDeadZone = min(max(deadZone, Self.stickDeadZoneRange.lowerBound), Self.stickDeadZoneRange.upperBound)
    }
}

/// The keys offered for binding, by Windows virtual-key code.
enum ControllerBindableKey {
    struct Group: Identifiable {
        let id: String
        let keys: [(code: UInt16, name: String)]
    }

    static let groups: [Group] = [
        Group(id: "common", keys: [
            (0x20, "Space"), (0x0d, "Enter"), (0x1b, "Esc"), (0x09, "Tab"), (0x08, "Backspace"),
            (0xa0, "Shift"), (0xa2, "Ctrl"), (0xa4, "Alt")
        ]),
        Group(id: "letters", keys: (0x41...0x5a).map { (UInt16($0), String(UnicodeScalar(UInt8($0)))) }),
        Group(id: "digits", keys: (0x30...0x39).map { (UInt16($0), String(UnicodeScalar(UInt8($0)))) }),
        Group(id: "function", keys: (1...12).map { (UInt16(0x6f + $0), "F\($0)") }),
        Group(id: "navigation", keys: [
            (0x26, "Up"), (0x28, "Down"), (0x25, "Left"), (0x27, "Right"),
            (0x24, "Home"), (0x23, "End"), (0x21, "Page Up"), (0x22, "Page Down"), (0x2d, "Insert"), (0x2e, "Delete")
        ]),
        Group(id: "symbols", keys: [
            (0xc0, "`"), (0xbd, "-"), (0xbb, "="), (0xdb, "["), (0xdd, "]"), (0xdc, "\\"),
            (0xba, ";"), (0xde, "'"), (0xbc, ","), (0xbe, "."), (0xbf, "/")
        ])
    ]

    static func name(_ code: UInt16) -> String {
        // The right-hand modifiers read the same as the left-hand ones that are offered.
        let code: UInt16 = [0xa1: 0xa0, 0xa3: 0xa2, 0xa5: 0xa4][code] ?? code
        for group in groups {
            if let key = group.keys.first(where: { $0.code == code }) { return key.name }
        }
        return "Key \(code)"
    }
}
