import Foundation

/// Valve's text key-value format, which Steam Input layouts are saved in: quoted or bare strings,
/// nested objects in braces, and keys that may repeat.
enum SteamVDF {
    indirect enum Value: Equatable {
        case string(String)
        case object([Entry])

        var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var entries: [Entry] {
            if case .object(let entries) = self { return entries }
            return []
        }

        /// The first child with this key; keys compare without regard to case, as Steam's do.
        subscript(key: String) -> Value? {
            entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        func all(_ key: String) -> [Value] {
            entries.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
        }
    }

    struct Entry: Equatable {
        let key: String
        let value: Value
    }

    /// Returns nil when the text is not well-formed. Nesting is limited so a hostile file cannot
    /// exhaust the stack.
    static func parse(_ text: String) -> Value? {
        var scanner = Scanner(characters: Array(text.unicodeScalars))
        guard let entries = scanner.entries(depth: 0, untilClose: false) else { return nil }
        return .object(entries)
    }

    private struct Scanner {
        let characters: [Unicode.Scalar]
        var index = 0
        static let maximumDepth = 32

        private enum Token {
            case open, close, string(String)
        }

        private mutating func next() -> Token? {
            while index < characters.count {
                let scalar = characters[index]
                if scalar.properties.isWhitespace || scalar == "\u{feff}" {
                    index += 1
                } else if scalar == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                } else {
                    break
                }
            }
            guard index < characters.count else { return nil }
            let scalar = characters[index]
            if scalar == "{" { index += 1; return .open }
            if scalar == "}" { index += 1; return .close }
            var text = String.UnicodeScalarView()
            if scalar == "\"" {
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    text.append(characters[index])
                    index += 1
                }
                index += 1
            } else {
                while index < characters.count {
                    let current = characters[index]
                    if current.properties.isWhitespace || current == "{" || current == "}" || current == "\"" { break }
                    text.append(current)
                    index += 1
                }
            }
            return .string(String(text))
        }

        mutating func entries(depth: Int, untilClose: Bool) -> [Entry]? {
            guard depth <= Self.maximumDepth else { return nil }
            var result: [Entry] = []
            while let token = next() {
                switch token {
                case .close:
                    return untilClose ? result : nil
                case .open:
                    return nil
                case .string(let key):
                    guard let value = next() else { return nil }
                    switch value {
                    case .string(let text):
                        result.append(Entry(key: key, value: .string(text)))
                    case .open:
                        guard let children = entries(depth: depth + 1, untilClose: true) else { return nil }
                        result.append(Entry(key: key, value: .object(children)))
                    case .close:
                        return nil
                    }
                }
            }
            return untilClose ? nil : result
        }
    }
}

/// A controller layout in Steam Input's own terms: action sets and layers, each assigning a
/// group to a source on the pad; a group's mode says how the source behaves and its inputs carry
/// activators with bindings. Layouts made in OpenNOW and layouts imported from Steam both become
/// one of these, so one engine runs them all.
struct SteamInputConfig: Equatable {
    enum Source: String, CaseIterable, Hashable {
        case buttonDiamond = "button_diamond"
        case dpad
        case joystick
        case rightJoystick = "right_joystick"
        case leftTrackpad = "left_trackpad"
        case rightTrackpad = "right_trackpad"
        case leftTrigger = "left_trigger"
        case rightTrigger = "right_trigger"
        case gyro
        case switches = "switch"
        /// The Steam button and the grip sensors, which Steam's own layouts cannot bind.
        case system = "opennow_system"

        var isSurface: Bool {
            [.joystick, .rightJoystick, .leftTrackpad, .rightTrackpad].contains(self)
        }

        var isTrackpad: Bool { self == .leftTrackpad || self == .rightTrackpad }
    }

    enum Mode: String {
        case fourButtons = "four_buttons"
        case switches
        case dpad
        case singleButton = "single_button"
        case trigger
        case joystickMove = "joystick_move"
        case joystickCamera = "joystick_camera"
        case joystickMouse = "joystick_mouse"
        case absoluteMouse = "absolute_mouse"
        case mouseJoystick = "mouse_joystick"
        case scrollWheel = "scrollwheel"
        /// A swipe up or down the pad turns the wheel; Steam's own wheel mode is circular.
        case linearScroll = "opennow_scroll"
        case gyroToMouse = "gyro_to_mouse"
        case gyroToJoystick = "gyro_to_joystick"
        case flickStick = "flickstick"
        /// The surface stands for an area of the screen: where the thumb is, the pointer goes.
        case mouseRegion = "mouse_region"
        /// A swipe scrolls both ways.
        case scroll2D = "2dscroll"
        case radialMenu = "radial_menu"
        case touchMenu = "touch_menu"
        case disabled
    }

    enum Binding: Hashable {
        /// A Windows virtual-key code.
        case key(UInt16)
        /// 1 left, 2 middle, 3 right, 4 back, 5 forward.
        case mouseButton(Int)
        /// One notch: +1 up, -1 down.
        case wheel(Int)
        case pad(ControllerPadButton)
        case changeSet(Int)
        case holdLayer(Int)
        case addLayer(Int)
        case removeLayer(Int)
        /// While held, the source uses another group.
        case modeShift(Source, Int)
        case shortcut(NativeStreamControllerShortcutAction)
    }

    struct Activator: Equatable {
        enum Kind: Equatable {
            case fullPress, softPress, longPress, doublePress, startPress, release
        }

        var kind: Kind = .fullPress
        var bindings: [Binding] = []
        /// The author's name for what this does, shown in on-screen menus.
        var label = ""
        var toggle = false
        var holdRepeats = false
        var repeatInterval: TimeInterval = 0.1
        var longPressTime: TimeInterval = 0.15
        var doubleTapTime: TimeInterval = 0.25
        var delayStart: TimeInterval = 0
        var delayEnd: TimeInterval = 0
        /// Bound to one of the game's own Steam Input actions, which cannot be sent from here.
        var nativeAction = false
    }

    enum GyroActivation: Equatable {
        case whileHeld, whileReleased, toggle
    }

    struct InputRef: Hashable {
        var source: Source
        var input: String
    }

    struct Group: Equatable {
        var id: Int
        var mode: Mode
        var name = ""
        var inputs: [String: [Activator]] = [:]
        var settings: [String: Double] = [:]
        /// For gyro groups: the inputs that switch the gyro; none means it is always on.
        var gyroActivators: [InputRef] = []
        var gyroActivation: GyroActivation = .whileHeld
    }

    struct ActionSet: Equatable {
        var id: Int
        var title = ""
        var isLayer = false
        var groups: [Source: Int] = [:]
    }

    var title = ""
    var controllerType = ""
    var sets: [Int: ActionSet] = [:]
    var defaultSet = 0
    var groups: [Int: Group] = [:]
    /// What the layout asks for that OpenNOW cannot do, in words for the player.
    var notes: [String] = []

    /// Whether any gyro group is in use, so the pad is only asked for readings when needed.
    var usesGyro: Bool {
        sets.values.contains { set in
            guard let id = set.groups[.gyro], let mode = groups[id]?.mode else { return false }
            return mode != .disabled
        }
    }
}

extension SteamInputConfig.Binding {
    /// A few words for what this sends, for menus and summaries.
    var shortTitle: String {
        switch self {
        case .key(let code): return ControllerBindableKey.name(code)
        case .mouseButton(let button):
            switch button {
            case 1: return String(localized: "Left Click")
            case 2: return String(localized: "Middle Click")
            case 3: return String(localized: "Right Click")
            default: return String(localized: "Mouse \(button)")
            }
        case .wheel(let direction): return direction < 0 ? String(localized: "Scroll Down") : String(localized: "Scroll Up")
        case .pad(let button): return button.rawValue.uppercased()
        case .changeSet: return String(localized: "Change Action Set")
        case .holdLayer: return String(localized: "Hold Layer")
        case .addLayer: return String(localized: "Add Layer")
        case .removeLayer: return String(localized: "Remove Layer")
        case .modeShift: return String(localized: "Mode Shift")
        case .shortcut(let action): return action.label
        }
    }
}

extension SteamInputConfig.Activator {
    /// The author's label, or failing that what it sends, such as "Ctrl+1".
    var displayLabel: String {
        label.isEmpty ? bindings.map(\.shortTitle).joined(separator: "+") : label
    }
}

// MARK: Reading Steam's files

extension SteamInputConfig {
    enum ImportError: Error, Equatable {
        case notALayout
    }

    /// Reads a Steam Input layout file (`controller_mappings`). Anything it uses that has no
    /// equivalent outside Steam is left out and described in `notes`.
    init(vdf text: String) throws {
        guard let root = SteamVDF.parse(text)?["controller_mappings"], !root.entries.isEmpty else {
            throw ImportError.notALayout
        }
        var notes = ImportNotes()
        controllerType = root["controller_type"]?.string ?? ""
        title = Self.localized(root["title"]?.string ?? "", in: root)

        var rawGroups: [Int: SteamVDF.Value] = [:]
        for group in root.all("group") {
            if let id = group["id"]?.string.flatMap(Int.init) { rawGroups[id] = group }
        }
        for (id, raw) in rawGroups {
            // A reference group stands for another one, so menus can be shared between sets.
            var resolved = raw
            if raw["mode"]?.string == "reference",
               let target = raw["settings"]?["referenced_mode"]?.string.flatMap(Int.init), let other = rawGroups[target] {
                resolved = other
            }
            groups[id] = Self.group(id: id, from: resolved, notes: &notes)
        }

        var titles: [String: (title: String, layer: Bool)] = [:]
        for entry in root["actions"]?.entries ?? [] {
            titles[entry.key.lowercased()] = (Self.localized(entry.value["title"]?.string ?? entry.key, in: root), false)
        }
        for entry in root["action_layers"]?.entries ?? [] {
            titles[entry.key.lowercased()] = (Self.localized(entry.value["title"]?.string ?? entry.key, in: root), true)
        }
        var firstSet: Int?
        for preset in root.all("preset") {
            guard let id = preset["id"]?.string.flatMap(Int.init) else { continue }
            let name = preset["name"]?.string ?? ""
            let known = titles[name.lowercased()]
            var set = ActionSet(id: id, title: known?.title ?? name, isLayer: known?.layer ?? false)
            for binding in preset["group_source_bindings"]?.entries ?? [] {
                let words = (binding.value.string ?? "").split(separator: " ").map(String.init)
                guard let groupID = Int(binding.key), words.count >= 2, words[1] == "active",
                      !words.contains("modeshift") else { continue }
                guard let source = Source(rawValue: words[0]), source != .system else {
                    notes.unsupportedSources.insert(words[0])
                    continue
                }
                set.groups[source] = groupID
            }
            sets[id] = set
            if firstSet == nil, !set.isLayer { firstSet = id }
        }
        guard !sets.isEmpty else { throw ImportError.notALayout }
        defaultSet = firstSet ?? sets.keys.min() ?? 0
        sendNativeActionsAsGamepad()
        addSystemDefaults()
        self.notes = notes.sentences
    }

    /// A game with its own Steam Input actions still gets a plain gamepad from the host, and
    /// Steam on the host maps that to the game's actions. So a control bound to a native action is
    /// sent as the gamepad control of the same name, where there is one.
    private mutating func sendNativeActionsAsGamepad() {
        for set in sets.values {
            for (source, id) in set.groups {
                guard var group = groups[id] else { continue }
                var native = group.settings["opennow_native_actions"] == 1
                for (input, activators) in group.inputs {
                    for index in activators.indices where activators[index].nativeAction && activators[index].bindings.isEmpty {
                        native = true
                        if let button = Self.gamepadEquivalent(source: source, input: input) {
                            group.inputs[input]?[index].bindings = [.pad(button)]
                        }
                    }
                }
                if native, group.mode == .trigger, group.settings["output_trigger"] == nil {
                    if source == .leftTrigger { group.settings["output_trigger"] = 1 }
                    if source == .rightTrigger { group.settings["output_trigger"] = 2 }
                }
                groups[id] = group
            }
        }
    }

    private static func gamepadEquivalent(source: Source, input: String) -> ControllerPadButton? {
        switch (source, input) {
        case (.buttonDiamond, "button_a"): return .a
        case (.buttonDiamond, "button_b"): return .b
        case (.buttonDiamond, "button_x"): return .x
        case (.buttonDiamond, "button_y"): return .y
        case (.dpad, "dpad_north"): return .up
        case (.dpad, "dpad_south"): return .down
        case (.dpad, "dpad_west"): return .left
        case (.dpad, "dpad_east"): return .right
        case (.switches, "left_bumper"): return .lb
        case (.switches, "right_bumper"): return .rb
        case (.switches, "button_escape"): return .start
        case (.switches, "button_menu"): return .back
        case (.joystick, "click"): return .ls
        case (.rightJoystick, "click"): return .rs
        default: return nil
        }
    }

    /// The key an override is stored under.
    static func overrideKey(set: Int, source: Source, input: String) -> String {
        "\(set)|\(source.rawValue)|\(input)"
    }

    /// Replaces what single inputs do, as the player chose after importing. Each override gives
    /// the input one ordinary press; a group shared with other sets is copied first so only the
    /// chosen set changes.
    mutating func apply(overrides: [String: String]) {
        for (key, token) in overrides.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let setID = Int(parts[0]), let source = Source(rawValue: parts[1]),
                  let action = ControllerAction(token: token), var set = sets[setID] else { continue }
            let id = (groups.keys.max() ?? 0) + 1
            var group = set.groups[source].flatMap { groups[$0] } ?? Group(id: id, mode: .switches)
            group.id = id
            group.inputs[parts[2]] = [Activator(bindings: action.bindings)]
            groups[id] = group
            set.groups[source] = id
            sets[setID] = set
        }
    }

    /// Gives every set the Steam button, which Steam reserves and its layouts therefore never bind.
    private mutating func addSystemDefaults() {
        let id = (groups.keys.max() ?? 0) + 1
        var group = Group(id: id, mode: .switches)
        group.inputs["steam"] = [Activator(bindings: [.shortcut(.controls)])]
        groups[id] = group
        for key in sets.keys where sets[key]?.isLayer == false {
            sets[key]?.groups[.system] = id
        }
    }

    private static func localized(_ text: String, in root: SteamVDF.Value) -> String {
        guard text.hasPrefix("#") else { return text }
        return root["localization"]?["english"]?[String(text.dropFirst())]?.string ?? String(text.dropFirst())
    }

    private struct ImportNotes {
        var gameActions = 0
        var unknownBindings: Set<String> = []
        var unsupportedModes: Set<String> = []
        var unsupportedSources: Set<String> = []
        var unsupportedActivators: Set<String> = []
        var gyroButtons: Set<String> = []
        var approximatedModes: Set<String> = []

        var sentences: [String] {
            var result: [String] = []
            if gameActions > 0 {
                result.append("Some controls (\(gameActions)) are bound to the game's own Steam Input actions. They are sent as the matching gamepad button so the game's own layout on the host handles them; those with no gamepad equivalent do nothing.")
            }
            if !unsupportedModes.isEmpty {
                result.append("Not supported yet, so these do nothing: \(unsupportedModes.sorted().joined(separator: ", ")).")
            }
            if !approximatedModes.isEmpty {
                result.append("Approximated: \(approximatedModes.sorted().joined(separator: ", ")).")
            }
            if !unsupportedActivators.isEmpty {
                result.append("Ignored press types: \(unsupportedActivators.sorted().joined(separator: ", ")).")
            }
            if !unknownBindings.isEmpty {
                result.append("Ignored Steam-only actions: \(unknownBindings.sorted().joined(separator: ", ")).")
            }
            if !unsupportedSources.isEmpty {
                result.append("This controller has no \(unsupportedSources.sorted().joined(separator: ", ")).")
            }
            if !gyroButtons.isEmpty {
                result.append("Part of the gyro's enable button setting could not be read (\(gyroButtons.sorted().joined(separator: ", "))).")
            }
            return result
        }
    }

    private static func group(id: Int, from raw: SteamVDF.Value, notes: inout ImportNotes) -> Group {
        let modeName = raw["mode"]?.string ?? ""
        var mode = Mode(rawValue: modeName)
        if mode == .linearScroll { mode = nil }
        switch modeName {
        case "gyro_to_camera_angles":
            mode = .gyroToMouse
        case "gyro_to_joystick_deflection":
            mode = .gyroToJoystick
            notes.approximatedModes.insert("gyro tilt as a stick (follows turning speed instead)")
        default:
            break
        }
        if mode == nil, !modeName.isEmpty, modeName != "reference" { notes.unsupportedModes.insert(modeName) }
        if modeName == "mouse_joystick" { notes.approximatedModes.insert("mouse-like joystick") }
        var group = Group(id: id, mode: mode ?? .disabled, name: raw["name"]?.string ?? "")
        for setting in raw["settings"]?.entries ?? [] {
            guard let text = setting.value.string else { continue }
            if let number = Double(text) {
                group.settings[setting.key.lowercased()] = number
            } else if text == "true" || text == "false" {
                group.settings[setting.key.lowercased()] = text == "true" ? 1 : 0
            }
        }
        for input in raw["inputs"]?.entries ?? [] {
            var activators: [Activator] = []
            for entry in input.value["activators"]?.entries ?? [] {
                // The same press type may be listed more than once, each with its own bindings.
                if let activator = activator(named: entry.key, from: entry.value, notes: &notes) {
                    activators.append(activator)
                }
            }
            group.inputs[input.key.lowercased()] = activators
        }
        if !(raw["gameactions"]?.entries.isEmpty ?? true) { group.settings["opennow_native_actions"] = 1 }
        // Newer files name the gyro's buttons as a set of bits; older ones as one number.
        let mask = raw["settings"]?["gyro_ratchet_button_mask"]?.string.flatMap(UInt64.init) ?? 0
        if mask != 0 {
            for bit in 0..<64 where mask & (1 << UInt64(bit)) != 0 {
                if let button = gyroMaskButtons[bit] {
                    group.gyroActivators.append(button)
                } else {
                    notes.gyroButtons.insert("button \(bit)")
                }
            }
        } else if let code = group.settings["gyro_button"], code != 0, abs(code) < 1_000 {
            if let button = gyroButton(Int(code)) {
                group.gyroActivators = [button]
            } else {
                notes.gyroButtons.insert("code \(Int(code))")
            }
        }
        switch group.settings["gyro_button_invert"] {
        case 1: group.gyroActivation = .whileReleased
        case 2: group.gyroActivation = .toggle
        default: break
        }
        return group
    }

    /// The buttons in a gyro button set, by bit. They follow the first Steam Controller's button
    /// report, with the triggers' soft pulls added above it.
    private static let gyroMaskButtons: [Int: InputRef] = [
        0: InputRef(source: .rightTrigger, input: "click"), 1: InputRef(source: .leftTrigger, input: "click"),
        2: InputRef(source: .switches, input: "right_bumper"), 3: InputRef(source: .switches, input: "left_bumper"),
        4: InputRef(source: .buttonDiamond, input: "button_y"), 5: InputRef(source: .buttonDiamond, input: "button_b"),
        6: InputRef(source: .buttonDiamond, input: "button_x"), 7: InputRef(source: .buttonDiamond, input: "button_a"),
        8: InputRef(source: .dpad, input: "dpad_north"), 9: InputRef(source: .dpad, input: "dpad_east"),
        10: InputRef(source: .dpad, input: "dpad_west"), 11: InputRef(source: .dpad, input: "dpad_south"),
        12: InputRef(source: .switches, input: "button_menu"), 14: InputRef(source: .switches, input: "button_escape"),
        15: InputRef(source: .switches, input: "button_back_left"), 16: InputRef(source: .switches, input: "button_back_right"),
        17: InputRef(source: .leftTrackpad, input: "click"), 18: InputRef(source: .rightTrackpad, input: "click"),
        19: InputRef(source: .leftTrackpad, input: "touch"), 20: InputRef(source: .rightTrackpad, input: "touch"),
        22: InputRef(source: .joystick, input: "click"),
        24: InputRef(source: .rightTrigger, input: "edge"), 25: InputRef(source: .leftTrigger, input: "edge")
    ]

    /// Steam stores the gyro's enable button as a number from the list its configurator shows.
    private static func gyroButton(_ code: Int) -> InputRef? {
        switch code {
        case 1: return InputRef(source: .rightTrackpad, input: "touch")
        case 2: return InputRef(source: .leftTrackpad, input: "touch")
        case 3: return InputRef(source: .rightTrackpad, input: "click")
        case 4: return InputRef(source: .leftTrackpad, input: "click")
        case 5: return InputRef(source: .switches, input: "right_bumper")
        case 6: return InputRef(source: .switches, input: "left_bumper")
        case 7: return InputRef(source: .switches, input: "button_back_right")
        case 8: return InputRef(source: .switches, input: "button_back_left")
        case 9: return InputRef(source: .rightTrigger, input: "click")
        case 10: return InputRef(source: .leftTrigger, input: "click")
        case 11: return InputRef(source: .rightTrigger, input: "edge")
        case 12: return InputRef(source: .leftTrigger, input: "edge")
        case 13: return InputRef(source: .buttonDiamond, input: "button_a")
        case 14: return InputRef(source: .buttonDiamond, input: "button_b")
        case 15: return InputRef(source: .buttonDiamond, input: "button_x")
        case 16: return InputRef(source: .buttonDiamond, input: "button_y")
        case 17: return InputRef(source: .joystick, input: "click")
        default: return nil
        }
    }

    private static func activator(named name: String, from raw: SteamVDF.Value, notes: inout ImportNotes) -> Activator? {
        var activator = Activator()
        switch name.lowercased() {
        case "full_press": activator.kind = .fullPress
        case "soft_press": activator.kind = .softPress
        case "long_press": activator.kind = .longPress
        case "double_press": activator.kind = .doublePress
        case "start_press": activator.kind = .startPress
        case "release": activator.kind = .release
        default:
            notes.unsupportedActivators.insert(name)
            return nil
        }
        for binding in raw["bindings"]?.all("binding") ?? [] {
            guard let text = binding.string else { continue }
            let fields = text.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if activator.label.isEmpty, fields.count > 1, !fields[1].isEmpty { activator.label = fields[1] }
            if (fields.first ?? "").lowercased().hasPrefix("game_action") { activator.nativeAction = true }
            if let parsed = self.binding(fields.first ?? "", notes: &notes) { activator.bindings.append(parsed) }
        }
        func setting(_ key: String) -> Double? { raw["settings"]?[key]?.string.flatMap(Double.init) }
        activator.toggle = setting("toggle") == 1
        activator.holdRepeats = setting("hold_repeats") == 1
        // Steam's repeat rate runs from slow to fast on an undocumented scale; this spreads it
        // between two and twenty presses a second.
        if let rate = setting("repeat_rate") { activator.repeatInterval = 1 / (2 + min(max(rate, 0), 100) * 0.18) }
        if let time = setting("long_press_time") { activator.longPressTime = max(time, 0) / 1000 }
        if let time = setting("doubetap_max_duration") { activator.doubleTapTime = max(time, 0) / 1000 }
        if let time = setting("delay_start") { activator.delayStart = max(time, 0) / 1000 }
        if let time = setting("delay_end") { activator.delayEnd = max(time, 0) / 1000 }
        return activator
    }

    private static func binding(_ text: String, notes: inout ImportNotes) -> Binding? {
        let words = text.split(separator: " ").map(String.init)
        guard let verb = words.first?.lowercased() else { return nil }
        let argument = words.count > 1 ? words[1].uppercased() : ""
        switch verb {
        case "key_press":
            if let code = virtualKeys[argument] { return .key(code) }
            notes.unknownBindings.insert("key \(argument)")
        case "mouse_button":
            switch argument {
            case "LEFT": return .mouseButton(1)
            case "MIDDLE": return .mouseButton(2)
            case "RIGHT": return .mouseButton(3)
            case "BACK": return .mouseButton(4)
            case "FORWARD": return .mouseButton(5)
            default: notes.unknownBindings.insert("mouse button \(argument)")
            }
        case "mouse_wheel":
            if argument == "SCROLL_UP" { return .wheel(1) }
            if argument == "SCROLL_DOWN" { return .wheel(-1) }
        case "xinput_button":
            if let button = padButtons[argument] { return .pad(button) }
            notes.unknownBindings.insert("gamepad \(argument)")
        case "mode_shift":
            if words.count > 2, let source = Source(rawValue: words[1].lowercased()), let group = Int(words[2]) {
                return .modeShift(source, group)
            }
        case "game_action":
            notes.gameActions += 1
        case "controller_action":
            // Sets and layers are numbered from one in bindings and from zero in the file.
            let target = words.count > 2 ? Int(words[2]).map { $0 - 1 } : nil
            switch argument {
            case "CHANGE_PRESET": if let target { return .changeSet(target) }
            case "HOLD_LAYER": if let target { return .holdLayer(target) }
            case "ADD_LAYER": if let target { return .addLayer(target) }
            case "REMOVE_LAYER": if let target { return .removeLayer(target) }
            case "EMPTY_BINDING", "EMPTY_SUB_COMMAND", "": break
            default: notes.unknownBindings.insert(words[1].lowercased())
            }
        default:
            notes.unknownBindings.insert(verb)
        }
        return nil
    }

    private static let padButtons: [String: ControllerPadButton] = [
        "A": .a, "B": .b, "X": .x, "Y": .y,
        "SHOULDER_LEFT": .lb, "SHOULDER_RIGHT": .rb, "TRIGGER_LEFT": .lt, "TRIGGER_RIGHT": .rt,
        "JOYSTICK_LEFT": .ls, "JOYSTICK_RIGHT": .rs, "SELECT": .back, "START": .start, "GUIDE": .guide,
        "DPAD_UP": .up, "DPAD_DOWN": .down, "DPAD_LEFT": .left, "DPAD_RIGHT": .right
    ]

    /// Steam's key names, as Windows virtual-key codes.
    private static let virtualKeys: [String: UInt16] = {
        var keys: [String: UInt16] = [
            "SPACE": 0x20, "RETURN": 0x0d, "ENTER": 0x0d, "ESCAPE": 0x1b, "TAB": 0x09, "BACKSPACE": 0x08,
            "LEFT_SHIFT": 0xa0, "RIGHT_SHIFT": 0xa1, "LEFT_CONTROL": 0xa2, "RIGHT_CONTROL": 0xa3,
            "LEFT_ALT": 0xa4, "RIGHT_ALT": 0xa5, "LEFT_WINDOWS": 0x5b, "RIGHT_WINDOWS": 0x5c,
            "UP_ARROW": 0x26, "DOWN_ARROW": 0x28, "LEFT_ARROW": 0x25, "RIGHT_ARROW": 0x27,
            "HOME": 0x24, "END": 0x23, "PAGE_UP": 0x21, "PAGE_DOWN": 0x22, "INSERT": 0x2d, "DELETE": 0x2e,
            "CAPSLOCK": 0x14, "NUM_LOCK": 0x90, "SCROLL_LOCK": 0x91, "PRINT_SCREEN": 0x2c, "BREAK": 0x13,
            "PAUSE": 0x13, "VOLUME_MUTE": 0xad, "VOLUME_DOWN": 0xae, "VOLUME_UP": 0xaf,
            "BACK_TICK": 0xc0, "DASH": 0xbd, "EQUALS": 0xbb, "LEFT_BRACKET": 0xdb, "RIGHT_BRACKET": 0xdd,
            "BACKSLASH": 0xdc, "SEMICOLON": 0xba, "SINGLE_QUOTE": 0xde, "COMMA": 0xbc, "PERIOD": 0xbe,
            "FORWARD_SLASH": 0xbf, "KEYPAD_FORWARD_SLASH": 0x6f, "KEYPAD_ASTERISK": 0x6a, "KEYPAD_DASH": 0x6d,
            "KEYPAD_PLUS": 0x6b, "KEYPAD_ENTER": 0x0d, "KEYPAD_PERIOD": 0x6e
        ]
        for code in 0x41...0x5a { keys[String(UnicodeScalar(UInt8(code)))] = UInt16(code) }
        for digit in 0...9 {
            keys["\(digit)"] = UInt16(0x30 + digit)
            keys["KEYPAD_\(digit)"] = UInt16(0x60 + digit)
        }
        for number in 1...12 { keys["F\(number)"] = UInt16(0x6f + number) }
        return keys
    }()
}
