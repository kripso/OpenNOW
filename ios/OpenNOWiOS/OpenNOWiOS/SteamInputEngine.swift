import CoreGraphics
import Foundation

/// Runs a layout: turns pad reports into what the host understands — a gamepad packet plus key,
/// mouse-button, pointer and wheel input. It holds no connection or timer; the caller feeds it
/// reports and the current time and sends what comes back.
struct SteamInputEngine {
    typealias Source = SteamInputConfig.Source
    typealias Mode = SteamInputConfig.Mode
    typealias Binding = SteamInputConfig.Binding
    typealias Activator = SteamInputConfig.Activator
    typealias Ref = SteamInputConfig.InputRef

    struct Pad: Equatable {
        var buttons: UInt16 = 0
        var leftTrigger: UInt8 = 0
        var rightTrigger: UInt8 = 0
        var leftStickX: Int16 = 0
        var leftStickY: Int16 = 0
        var rightStickX: Int16 = 0
        var rightStickY: Int16 = 0
    }

    struct KeyEvent: Equatable {
        let virtualKey: UInt16
        let pressed: Bool
        /// Shift 0x01, Control 0x02, Alt 0x04, as held once this event has applied.
        let modifiers: UInt16
    }

    struct MouseButtonEvent: Equatable {
        let button: Int
        let pressed: Bool
    }

    struct Output: Equatable {
        var pad = Pad()
        var keys: [KeyEvent] = []
        var mouseButtons: [MouseButtonEvent] = []
        /// Pointer travel in screen direction: y grows downward.
        var mouse = CGPoint.zero
        /// 120 is one notch and positive scrolls up.
        var wheel = 0
        /// Sideways scrolling in the same units; positive scrolls right.
        var wheelX = 0
        /// Where to put the pointer, as a fraction of the screen from its top left.
        var absolute: CGPoint?
        var shortcuts: [NativeStreamControllerShortcutAction] = []
    }

    /// A radial or touch menu that is open on a stick or trackpad, for drawing over the game.
    struct Menu: Equatable, Identifiable {
        var source: Source
        var radial: Bool
        var title: String
        var items: [String]
        var selected: Int?

        var id: String { source.rawValue }
    }

    private enum Direction: CaseIterable {
        case up, down, left, right

        var input: String {
            switch self {
            case .up: return "dpad_north"
            case .down: return "dpad_south"
            case .left: return "dpad_west"
            case .right: return "dpad_east"
            }
        }
    }

    private struct Latched {
        var activator: Activator
        var wasActive = false
    }

    /// One pressable input and the activators it took on when it was last pressed. They stay
    /// until it is let go, so a layer that appears mid-press does not change what the press means.
    private struct Slot {
        var down = false
        var soft = false
        var pressedAt: TimeInterval = -.infinity
        var releasedAt: TimeInterval = -.infinity
        var doublePress = false
        var needsLatch = false
        var activators: [Latched] = []
        var toggled: Set<Int> = []
    }

    private struct Surface {
        var anchor: SteamControllerVector?
        var directions: Set<Direction> = []
        var angle: Double?
        var turned = 0.0
        var menuItem: Int?
        var menuGroup: Int?
        var clicked = false
        var deflection = SteamControllerVector.zero
        var flickAngle: Double?
        var flickPending = 0.0
        var flickTotal = 0.0
        var region: CGPoint?
    }

    private static let softPull: Float = 0.3
    private static let softRelease: Float = 0.2
    private static let fullPull: Float = 0.95
    private static let stickMousePixelsPerSecond = 1080.0
    private static let stickWheelUnitsPerSecond = 720.0
    private static let padMouseCountsPerUnit = 600.0
    private static let padWheelUnitsPerUnit = 1200.0
    private static let padStickReach: Float = 1.25
    private static let padUnitsPerSecondForFullStick: Float = 3
    private static let gyroMouseCountsPerDegree = 20.0
    private static let gyroStickFullScaleDegreesPerSecond = 180.0
    private static let gyroSoftThresholdDegreesPerSecond = 1.0
    private static let maximumStep: TimeInterval = 0.05
    private static let wheelNotch = 120
    private static let tapDuration: TimeInterval = 0.04
    private static let defaultScrollAngle = 30.0
    private static let menuCentre: Float = 0.3
    private static let flickPress: Float = 0.9
    private static let flickRelease: Float = 0.8
    private static let flickDuration: TimeInterval = 0.1
    private static let mouseJoystickMinimum: Float = 0.15

    var config: SteamInputConfig {
        didSet {
            guard config != oldValue else { return }
            baseSet = config.defaultSet
            layers = []
            heldLayers = []
            modeShifts = [:]
            for key in slots.keys {
                slots[key]?.activators = []
                slots[key]?.toggled = []
                slots[key]?.needsLatch = true
            }
        }
    }

    /// The player's own scaling on top of whatever the layout asks for.
    var tuning = SteamControllerTuning()

    private var stickDeadZone: Float { Float(tuning.stickDeadZone) / 100 }

    /// Menus currently open, after the latest report.
    private(set) var menus: [Menu] = []

    private var report = SteamControllerReport()
    private var slots: [Ref: Slot] = [:]
    private var physicalDown: Set<Ref> = []
    private var softTriggers: Set<Source> = []
    /// Inputs held while the stream did not own the pad; ignored until they are let go.
    private var blocked: Set<Ref> = []
    private var baseSet: Int
    private var layers: [Int] = []
    private var heldLayers: [Int] = []
    private var modeShifts: [Source: Int] = [:]
    private var heldBindings: Set<Binding> = []
    private var taps: [(bindings: [Binding], until: TimeInterval)] = []
    private var heldKeys: Set<UInt16> = []
    private var heldMouseButtons: Set<Int> = []
    private var surfaces: [Source: Surface] = [:]
    private var gyroStick = SteamControllerVector.zero
    private var gyroHeld = false
    private var gyroToggled = false
    private var wheelRemainder = 0.0
    private var wheelXRemainder = 0.0
    private var lastStep: TimeInterval?

    init(config: SteamInputConfig) {
        self.config = config
        baseSet = config.defaultSet
    }

    init(layout: SteamControllerLayout = SteamControllerLayout()) {
        self.init(config: layout.steamInputConfig)
    }

    /// Whether the layout needs gyro readings from the pad.
    var wantsGyro: Bool { config.usesGyro }

    /// The name of the action set in use, when the layout has more than one.
    var actionSetTitle: String? {
        let named = config.sets.values.filter { !$0.isLayer }
        return named.count > 1 ? config.sets[baseSet]?.title : nil
    }

    /// Takes a new report. While `suspended` (the stream does not own the pad) everything is
    /// released and only shortcuts are reported, so the pad can still close the overlay it opened.
    mutating func apply(_ next: SteamControllerReport, at now: TimeInterval, suspended: Bool = false) -> Output {
        report = next
        var output = Output()
        guard suspended else {
            evaluate(now: now, fresh: true, into: &output)
            return output
        }
        let digital = physicalInputs()
        for (ref, state) in digital where state.down {
            if !physicalDown.contains(ref) {
                for activator in resolve(ref) where activator.kind == .fullPress || activator.kind == .startPress {
                    for case .shortcut(let action) in activator.bindings where !output.shortcuts.contains(action) {
                        output.shortcuts.append(action)
                    }
                }
            }
            blocked.insert(ref)
        }
        physicalDown = Set(digital.filter(\.value.down).keys)
        release(into: &output)
        return output
    }

    /// Lets time pass between reports: sticks keep driving the pointer, long presses come due and
    /// brief taps end.
    mutating func advance(to now: TimeInterval) -> Output {
        var output = Output()
        evaluate(now: now, fresh: false, into: &output)
        return output
    }

    /// Lets go of everything, for when the pad disconnects or the stream ends.
    mutating func releaseAll() -> Output {
        var output = Output()
        release(into: &output)
        report = SteamControllerReport()
        physicalDown = []
        blocked = []
        slots = [:]
        baseSet = config.defaultSet
        layers = []
        gyroToggled = false
        return output
    }

    private mutating func release(into output: inout Output) {
        setHeld(keys: [], mouseButtons: [], into: &output)
        for key in slots.keys {
            slots[key]?.down = false
            slots[key]?.soft = false
            slots[key]?.activators = []
        }
        heldBindings = []
        heldLayers = []
        modeShifts = [:]
        taps = []
        surfaces = [:]
        softTriggers = []
        menus = []
        gyroStick = .zero
        gyroHeld = false
        wheelRemainder = 0
        wheelXRemainder = 0
        lastStep = nil
        output.pad = Pad()
    }

    // MARK: Layout lookup

    /// The groups that apply to a source, topmost first: a mode shift, then layers, then the set.
    private func stack(for source: Source) -> [SteamInputConfig.Group] {
        var result: [SteamInputConfig.Group] = []
        if let shifted = modeShifts[source], let group = config.groups[shifted] { result.append(group) }
        for layer in (layers + heldLayers).reversed() {
            if let id = config.sets[layer]?.groups[source], let group = config.groups[id] { result.append(group) }
        }
        if let id = config.sets[baseSet]?.groups[source], let group = config.groups[id] { result.append(group) }
        return result
    }

    private func mode(for source: Source) -> Mode {
        stack(for: source).first?.mode ?? .disabled
    }

    /// A layer only lists what it changes, so anything it leaves out comes from below, as long as
    /// the source is still in the same mode there.
    private func resolve(_ ref: Ref) -> [Activator] {
        let groups = stack(for: ref.source)
        guard let mode = groups.first?.mode else { return [] }
        for group in groups where group.mode == mode {
            if let activators = group.inputs[ref.input] { return activators }
        }
        return []
    }

    private func setting(_ key: String, for source: Source) -> Double? {
        let groups = stack(for: source)
        guard let mode = groups.first?.mode else { return nil }
        for group in groups where group.mode == mode {
            if let value = group.settings[key] { return value }
        }
        return nil
    }

    // MARK: Evaluation

    private func vector(of source: Source) -> SteamControllerVector {
        switch source {
        case .joystick: return report.leftStick
        case .rightJoystick: return report.rightStick
        case .leftTrackpad: return report.leftPad
        case .rightTrackpad: return report.rightPad
        default: return .zero
        }
    }

    private func touched(_ source: Source) -> Bool {
        switch source {
        case .leftTrackpad: return report.buttons.contains(.leftPadTouch)
        case .rightTrackpad: return report.buttons.contains(.rightPadTouch)
        default: return true
        }
    }

    /// Everything that is simply pressed or not, read straight from the report.
    private mutating func physicalInputs() -> [Ref: (down: Bool, soft: Bool)] {
        var result: [Ref: (down: Bool, soft: Bool)] = [:]
        func set(_ source: Source, _ input: String, _ button: SteamControllerButtons) {
            let down = report.buttons.contains(button)
            result[Ref(source: source, input: input)] = (down, down)
        }
        set(.buttonDiamond, "button_a", .a)
        set(.buttonDiamond, "button_b", .b)
        set(.buttonDiamond, "button_x", .x)
        set(.buttonDiamond, "button_y", .y)
        set(.switches, "button_escape", .menu)
        set(.switches, "button_menu", .view)
        set(.switches, "left_bumper", .leftBumper)
        set(.switches, "right_bumper", .rightBumper)
        set(.switches, "button_back_left", .l5)
        set(.switches, "button_back_left_upper", .l4)
        set(.switches, "button_back_right", .r5)
        set(.switches, "button_back_right_upper", .r4)
        set(.switches, "button_capture", .quickAccess)
        set(.dpad, "dpad_north", .dpadUp)
        set(.dpad, "dpad_south", .dpadDown)
        set(.dpad, "dpad_west", .dpadLeft)
        set(.dpad, "dpad_east", .dpadRight)
        set(.joystick, "click", .leftStickClick)
        set(.joystick, "touch", .leftStickTouch)
        set(.rightJoystick, "click", .rightStickClick)
        set(.rightJoystick, "touch", .rightStickTouch)
        set(.leftTrackpad, "click", .leftPadClick)
        set(.leftTrackpad, "touch", .leftPadTouch)
        set(.rightTrackpad, "click", .rightPadClick)
        set(.rightTrackpad, "touch", .rightPadTouch)
        set(.system, "steam", .steam)
        set(.system, "left_grip", .leftGrip)
        set(.system, "right_grip", .rightGrip)
        for (source, value, click) in [(Source.leftTrigger, report.leftTrigger, SteamControllerButtons.leftTriggerClick),
                                       (.rightTrigger, report.rightTrigger, .rightTriggerClick)] {
            let soft = value >= (softTriggers.contains(source) ? Self.softRelease : Self.softPull)
            if soft { softTriggers.insert(source) } else { softTriggers.remove(source) }
            let full = report.buttons.contains(click) || value >= Self.fullPull
            result[Ref(source: source, input: "click")] = (full, soft)
            result[Ref(source: source, input: "edge")] = (soft, soft)
        }
        return result
    }

    private mutating func evaluate(now: TimeInterval, fresh: Bool, into output: inout Output) {
        let step = lastStep.map { min(max(now - $0, 0), Self.maximumStep) } ?? 0
        lastStep = now

        var digital = physicalInputs()
        physicalDown = Set(digital.filter(\.value.down).keys)
        blocked.formIntersection(physicalDown)
        for ref in blocked { digital[ref] = (false, false) }

        var leftStick = SteamControllerVector.zero
        var rightStick = SteamControllerVector.zero
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var wheel = CGPoint.zero
        var openMenus: [Menu] = []

        for source in Source.allCases where source.isSurface {
            evaluateSurface(source, step: step, fresh: fresh, now: now, digital: &digital,
                            leftStick: &leftStick, rightStick: &rightStick, wheel: &wheel,
                            menus: &openMenus, output: &output)
        }
        menus = openMenus

        for (source, value) in [(Source.leftTrigger, report.leftTrigger), (.rightTrigger, report.rightTrigger)]
        where mode(for: source) == .trigger && !blocked.contains(Ref(source: source, input: "edge")) {
            switch setting("output_trigger", for: source) {
            case 1: leftTrigger = max(leftTrigger, value)
            case 2: rightTrigger = max(rightTrigger, value)
            default: break
            }
        }

        evaluateGyro(digital: digital, fresh: fresh, rightStick: &rightStick, output: &output)

        // Slots: latch on press, then work out which activators are in effect.
        var held: [Binding] = []
        for ref in Set(digital.keys).union(slots.keys) {
            let state = digital[ref] ?? (false, false)
            var slot = slots[ref] ?? Slot()
            let engaged = state.down || state.soft
            let wasEngaged = slot.down || slot.soft
            if engaged, !wasEngaged || slot.needsLatch {
                let silent = wasEngaged
                slot.activators = resolve(ref).map { Latched(activator: $0, wasActive: false) }
                slot.needsLatch = false
                if !silent {
                    let window = slot.activators.filter { $0.activator.kind == .doublePress }.map(\.activator.doubleTapTime).max()
                    slot.doublePress = window.map { now - slot.pressedAt <= $0 } ?? false
                    slot.pressedAt = now
                }
            }
            if state.down, !slot.down, !slot.needsLatch {
                for (index, latched) in slot.activators.enumerated() {
                    if latched.activator.kind == .startPress { tap([latched.activator], at: now, output: &output) }
                    if latched.activator.kind == .fullPress, latched.activator.toggle {
                        if slot.toggled.contains(index) { slot.toggled.remove(index) } else { slot.toggled.insert(index) }
                    }
                }
            }
            if !state.down, slot.down {
                slot.releasedAt = now
                tap(slot.activators.map(\.activator).filter { $0.kind == .release }, at: now, output: &output)
            }
            slot.down = state.down
            slot.soft = state.soft
            for index in slot.activators.indices {
                let activator = slot.activators[index].activator
                let active: Bool
                switch activator.kind {
                case .fullPress:
                    if activator.toggle {
                        active = slot.toggled.contains(index)
                    } else {
                        var pressed = state.down && now - slot.pressedAt >= activator.delayStart
                        if pressed, activator.holdRepeats, activator.repeatInterval > 0 {
                            pressed = Int((now - slot.pressedAt) / activator.repeatInterval) % 2 == 0
                        }
                        active = pressed || (!state.down && activator.delayEnd > 0 && now - slot.releasedAt < activator.delayEnd)
                    }
                case .softPress:
                    active = state.soft
                case .longPress:
                    active = state.down && now - slot.pressedAt >= activator.longPressTime
                case .doublePress:
                    active = state.down && slot.doublePress
                case .startPress, .release:
                    active = false
                }
                if active { held.append(contentsOf: activator.bindings) }
            }
            let lingering = slot.activators.contains { $0.activator.delayEnd > 0 && now - slot.releasedAt < $0.activator.delayEnd }
            if !engaged, !lingering, slot.toggled.isEmpty { slot.activators = [] }
            slots[ref] = slot
        }
        taps.removeAll { $0.until <= now }
        for tap in taps { held.append(contentsOf: tap.bindings) }

        // Bindings: what is newly held acts once, the rest acts for as long as it is held.
        var next = Pad()
        var keys: Set<UInt16> = []
        var mouseButtons: Set<Int> = []
        var nextLayers: [Int] = []
        var nextShifts: [Source: Int] = [:]
        let heldSet = Set(held)
        for binding in held {
            let new = !heldBindings.contains(binding)
            switch binding {
            case .key(let code): keys.insert(code)
            case .mouseButton(let button): mouseButtons.insert(button)
            case .pad(.lt): leftTrigger = 1
            case .pad(.rt): rightTrigger = 1
            case .pad(let button): next.buttons |= button.mask
            case .holdLayer(let layer): if !nextLayers.contains(layer) { nextLayers.append(layer) }
            case .modeShift(let source, let group): nextShifts[source] = group
            case .wheel(let direction): if new { output.wheel += direction * Self.wheelNotch }
            case .shortcut(let action): if new, !output.shortcuts.contains(action) { output.shortcuts.append(action) }
            case .changeSet(let set):
                if new, config.sets[set]?.isLayer == false {
                    baseSet = set
                    layers = []
                }
            case .addLayer(let layer): if new, config.sets[layer] != nil, !layers.contains(layer) { layers.append(layer) }
            case .removeLayer(let layer): if new { layers.removeAll { $0 == layer } }
            }
        }
        heldBindings = heldSet
        heldLayers = nextLayers.filter { config.sets[$0] != nil }
        modeShifts = nextShifts

        let scroll = Double(tuning.scroll) / 100
        wheelRemainder += Double(wheel.y) * scroll
        let wholeWheel = wheelRemainder.rounded(.towardZero)
        wheelRemainder -= wholeWheel
        output.wheel += Int(wholeWheel)
        wheelXRemainder += Double(wheel.x) * scroll
        let wholeWheelX = wheelXRemainder.rounded(.towardZero)
        wheelXRemainder -= wholeWheelX
        output.wheelX += Int(wholeWheelX)

        next.leftTrigger = Self.byte(leftTrigger)
        next.rightTrigger = Self.byte(rightTrigger)
        (next.leftStickX, next.leftStickY) = Self.axes(leftStick)
        (next.rightStickX, next.rightStickY) = Self.axes(rightStick)
        output.pad = next
        setHeld(keys: keys, mouseButtons: mouseButtons, into: &output)
    }

    /// Presses bindings briefly, for things that happen at a moment rather than while held.
    private mutating func tap(_ activators: [Activator], at now: TimeInterval, output: inout Output) {
        for activator in activators {
            var bindings: [Binding] = []
            for binding in activator.bindings {
                // Wheel notches are counted one by one; holding them would merge quick turns.
                if case .wheel(let direction) = binding { output.wheel += direction * Self.wheelNotch } else { bindings.append(binding) }
            }
            if !bindings.isEmpty { taps.append((bindings, now + Self.tapDuration)) }
        }
    }

    private mutating func evaluateSurface(
        _ source: Source, step: TimeInterval, fresh: Bool, now: TimeInterval,
        digital: inout [Ref: (down: Bool, soft: Bool)],
        leftStick: inout SteamControllerVector, rightStick: inout SteamControllerVector,
        wheel: inout CGPoint, menus: inout [Menu], output: inout Output
    ) {
        let mode = mode(for: source)
        let isPad = source.isTrackpad
        let touched = touched(source)
        let position = vector(of: source)
        var surface = surfaces[source] ?? Surface()
        let previous = surface.anchor
        if isPad { surface.anchor = touched ? position : nil }
        let scale = (setting("sensitivity", for: source) ?? 100) / 100
        let clickRef = Ref(source: source, input: "click")
        let clicked = digital[clickRef]?.down ?? false
        var directions: Set<Direction> = []
        var deflection = SteamControllerVector.zero

        func addStick(_ value: SteamControllerVector, right: Bool) {
            if right {
                rightStick.x += value.x
                rightStick.y += value.y
            } else {
                leftStick.x += value.x
                leftStick.y += value.y
            }
        }
        func mouseFromSwipe() {
            guard fresh, touched, let previous else { return }
            let counts = Self.padMouseCountsPerUnit * scale * Double(tuning.trackpadMouse) / 100
            output.mouse.x += Double(position.x - previous.x) * counts
            output.mouse.y -= Double(position.y - previous.y) * counts
        }
        func mouseFromDeflection() {
            let curved = Self.curved(position, deadZone: stickDeadZone)
            let speed = Self.stickMousePixelsPerSecond * scale * step * Double(tuning.stickMouse) / 100
            output.mouse.x += Double(curved.x) * speed
            output.mouse.y -= Double(curved.y) * speed
        }

        switch mode {
        case .flickStick:
            // Pushing the stick out turns the view to face that way; sweeping it round turns the
            // view by the same angle. Both become sideways pointer travel.
            let countsPerRadian = Double(tuning.flickTurn) / (2 * .pi)
            if touched, position.length >= (surface.flickAngle == nil ? Self.flickPress : Self.flickRelease) {
                let angle = atan2(Double(position.x), Double(position.y))
                if let last = surface.flickAngle {
                    var change = angle - last
                    if change > .pi { change -= 2 * .pi }
                    if change < -.pi { change += 2 * .pi }
                    output.mouse.x += change * countsPerRadian
                } else {
                    surface.flickTotal = angle * countsPerRadian
                    surface.flickPending = surface.flickTotal
                }
                surface.flickAngle = angle
            } else {
                surface.flickAngle = nil
            }
            if surface.flickPending != 0 {
                let portion = abs(surface.flickTotal) * step / Self.flickDuration
                let spent = surface.flickPending < 0 ? max(surface.flickPending, -portion) : min(surface.flickPending, portion)
                surface.flickPending -= spent
                output.mouse.x += spent
            }
        case .mouseRegion:
            // The surface stands for a rectangle on the screen, centred where the layout says.
            if fresh, touched, isPad || position.length >= stickDeadZone {
                let half = (setting("scale", for: source) ?? 100) / 100 / 2
                let centreX = (setting("position_x", for: source) ?? 50) / 100
                let centreY = (setting("position_y", for: source) ?? 50) / 100
                let point = CGPoint(x: min(max(centreX + Double(position.x) * half, 0), 1),
                                    y: min(max(centreY - Double(position.y) * half, 0), 1))
                if point != surface.region {
                    surface.region = point
                    output.absolute = point
                }
            } else if !touched {
                surface.region = nil
            }
            let edge = Float((setting("edge_binding_radius", for: source) ?? 29500) / 32767)
            let outer = touched && position.length >= edge
            digital[Ref(source: source, input: "edge")] = (outer, outer)
        case .scroll2D:
            if isPad {
                if fresh, touched, let previous {
                    wheel.x += CGFloat(Double(position.x - previous.x) * Self.padWheelUnitsPerUnit * scale)
                    wheel.y += CGFloat(Double(position.y - previous.y) * Self.padWheelUnitsPerUnit * scale)
                }
            } else {
                let curved = Self.curved(position, deadZone: stickDeadZone)
                wheel.x += CGFloat(Double(curved.x) * Self.stickWheelUnitsPerSecond * scale * step)
                wheel.y += CGFloat(Double(curved.y) * Self.stickWheelUnitsPerSecond * scale * step)
            }
        case .joystickMove, .joystickCamera:
            let defaultsRight = mode != .joystickMove || source == .rightJoystick || source == .rightTrackpad
            let target = setting("output_joystick", for: source)
            if target == 2 {
                if isPad { mouseFromSwipe() } else { mouseFromDeflection() }
            } else {
                var value = Self.rescaled(position, deadZone: stickDeadZone)
                if isPad {
                    value = touched ? SteamControllerVector(x: position.x * Self.padStickReach * Float(scale),
                                                            y: position.y * Self.padStickReach * Float(scale)) : .zero
                }
                addStick(value, right: target.map { $0 == 1 } ?? defaultsRight)
            }
            let edge = Float((setting("edge_binding_radius", for: source) ?? 29500) / 32767)
            let outer = touched && position.length >= edge
            digital[Ref(source: source, input: "edge")] = (outer, outer)
        case .joystickMouse, .absoluteMouse:
            if isPad { mouseFromSwipe() } else { mouseFromDeflection() }
        case .mouseJoystick:
            if isPad {
                // The faster the thumb moves, the further the stick is pushed. The push is
                // smoothed over neighbouring reports and never falls inside a game's dead zone.
                if fresh, touched, let previous, step > 0 {
                    let speed = Float(scale) * Float(tuning.trackpadMouse) / 100
                        / (Float(step) * Self.padUnitsPerSecondForFullStick)
                    var target = SteamControllerVector(x: (position.x - previous.x) * speed, y: (position.y - previous.y) * speed)
                    let length = target.length
                    if length > 0.001 {
                        let pushed = min(Self.mouseJoystickMinimum + length * (1 - Self.mouseJoystickMinimum), 1)
                        target = SteamControllerVector(x: target.x / length * pushed, y: target.y / length * pushed)
                    } else {
                        target = .zero
                    }
                    deflection = SteamControllerVector(x: (surface.deflection.x + target.x) / 2,
                                                       y: (surface.deflection.y + target.y) / 2)
                    if deflection.length < 0.02 { deflection = .zero }
                } else if !fresh, touched {
                    deflection = surface.deflection
                }
                addStick(deflection, right: true)
            } else {
                addStick(Self.rescaled(position, deadZone: stickDeadZone), right: true)
            }
        case .linearScroll:
            if isPad {
                if fresh, touched, let previous {
                    wheel.y += CGFloat(Double(position.y - previous.y) * Self.padWheelUnitsPerUnit * scale)
                }
            } else {
                wheel.y += CGFloat(Double(Self.curved(position, deadZone: stickDeadZone).y) * Self.stickWheelUnitsPerSecond * scale * step)
            }
        case .scrollWheel:
            // Circling the pad or stick turns the wheel a step for every so many degrees.
            if touched, position.length >= Self.menuCentre {
                let angle = atan2(Double(position.x), Double(position.y))
                if let last = surface.angle {
                    var change = angle - last
                    if change > .pi { change -= 2 * .pi }
                    if change < -.pi { change += 2 * .pi }
                    surface.turned += change * 180 / .pi
                    let stepAngle = max(setting("scroll_angle", for: source) ?? Self.defaultScrollAngle, 5)
                    while abs(surface.turned) >= stepAngle {
                        let clockwise = surface.turned > 0
                        surface.turned += clockwise ? -stepAngle : stepAngle
                        tap(resolve(Ref(source: source, input: clockwise ? "scroll_clockwise" : "scroll_counterclockwise")),
                            at: now, output: &output)
                    }
                }
                surface.angle = angle
            } else {
                surface.angle = nil
                surface.turned = 0
            }
        case .dpad:
            let requiresClick = setting("requires_click", for: source) == 1
            if touched, !requiresClick || clicked {
                let press = setting("deadzone", for: source).map { Float($0 / 32767) } ?? (isPad ? 0.3 : 0.5)
                directions = Self.heldDirections(position, previous: surface.directions, press: press, release: press * 0.7)
            }
            if requiresClick { digital[clickRef] = (false, false) }
            for direction in Direction.allCases {
                let down = directions.contains(direction)
                digital[Ref(source: source, input: direction.input)] = (down, down)
            }
        case .radialMenu, .touchMenu:
            let groups = stack(for: source)
            guard let group = groups.first else { break }
            let count = (group.inputs.keys.compactMap { key -> Int? in
                key.hasPrefix("touch_menu_button_") ? Int(key.dropFirst("touch_menu_button_".count)) : nil
            }.max() ?? -1) + 1
            guard count > 0 else { break }
            var selected: Int?
            if touched {
                selected = mode == .radialMenu
                    ? Self.radialItem(position, count: count)
                    : Self.gridItem(position, count: count)
            }
            // Trackpads choose on a click unless the layout says on release; sticks on release.
            let fireType = setting("touchmenu_button_fire_type", for: source)
            let onClick = fireType.map { $0 == 0 } ?? isPad
            let item = selected ?? surface.menuItem
            var fire = false
            if onClick {
                fire = clicked && !surface.clicked && selected != nil
            } else {
                fire = selected == nil && surface.menuItem != nil && surface.menuGroup == group.id
            }
            if fire, let item {
                tap(resolve(Ref(source: source, input: "touch_menu_button_\(item)")), at: now, output: &output)
            }
            digital[clickRef] = (false, false)
            surface.menuItem = selected
            surface.menuGroup = group.id
            if selected != nil || isPad && touched {
                let items = (0..<count).map { index in
                    group.inputs["touch_menu_button_\(index)"]?.first?.displayLabel ?? ""
                }
                menus.append(Menu(source: source, radial: mode == .radialMenu, title: group.name, items: items, selected: selected))
            }
        case .fourButtons, .switches, .singleButton, .trigger, .gyroToMouse, .gyroToJoystick, .disabled:
            break
        }
        if mode != .flickStick {
            surface.flickAngle = nil
            surface.flickPending = 0
        }
        if mode != .radialMenu, mode != .touchMenu {
            // Leaving a menu with an item still chosen picks it, as when a mode shift is let go.
            if let item = surface.menuItem, let group = surface.menuGroup.flatMap({ config.groups[$0] }),
               !(group.settings["touchmenu_button_fire_type"].map { $0 == 0 } ?? isPad),
               let activators = group.inputs["touch_menu_button_\(item)"] {
                tap(activators, at: now, output: &output)
            }
            surface.menuItem = nil
            surface.menuGroup = nil
        }
        if mode == .disabled {
            digital[clickRef] = (false, false)
            digital[Ref(source: source, input: "touch")] = (false, false)
        }
        surface.directions = directions
        surface.deflection = deflection
        surface.clicked = clicked
        surfaces[source] = surface
    }

    private mutating func evaluateGyro(
        digital: [Ref: (down: Bool, soft: Bool)], fresh: Bool,
        rightStick: inout SteamControllerVector, output: inout Output
    ) {
        let groups = stack(for: .gyro)
        guard let group = groups.first, group.mode != .disabled else {
            gyroStick = .zero
            return
        }
        let asMouse = group.mode == .gyroToMouse || group.mode == .absoluteMouse || group.mode == .joystickMouse
        let held = group.gyroActivators.contains { digital[$0]?.soft ?? false }
        if held, !gyroHeld { gyroToggled.toggle() }
        gyroHeld = held
        let active: Bool
        if group.gyroActivators.isEmpty {
            active = true
        } else {
            switch group.gyroActivation {
            case .whileHeld: active = held
            case .whileReleased: active = !held
            case .toggle: active = gyroToggled
            }
        }
        if !active {
            gyroStick = .zero
        } else if fresh, report.gyroInterval > 0 {
            let rate = Self.gyroScreenRate(pitch: report.gyroPitch, yaw: report.gyroYaw)
            let scale = (group.settings["sensitivity"] ?? 100) / 100 * Double(tuning.gyro) / 100
            if asMouse {
                let interval = min(report.gyroInterval, Self.maximumStep)
                output.mouse.x += rate.x * interval * Self.gyroMouseCountsPerDegree * scale
                output.mouse.y += rate.y * interval * Self.gyroMouseCountsPerDegree * scale
            } else {
                // Screen y grows downward and a stick's grows upward.
                gyroStick = SteamControllerVector(
                    x: Float(rate.x * scale / Self.gyroStickFullScaleDegreesPerSecond),
                    y: Float(-rate.y * scale / Self.gyroStickFullScaleDegreesPerSecond))
            }
        }
        if !asMouse {
            rightStick.x += gyroStick.x
            rightStick.y += gyroStick.y
        }
    }

    /// Emits the transitions between what was held and what should be. Modifier keys go down
    /// first and come up last so a chord such as Shift+1 arrives as one.
    private mutating func setHeld(keys: Set<UInt16>, mouseButtons: Set<Int>, into output: inout Output) {
        func order(_ codes: Set<UInt16>, modifiersFirst: Bool) -> [UInt16] {
            codes.sorted {
                let left = Self.modifierFlag($0) != 0
                let right = Self.modifierFlag($1) != 0
                if left != right { return left == modifiersFirst }
                return $0 < $1
            }
        }
        for code in order(heldKeys.subtracting(keys), modifiersFirst: false) {
            heldKeys.remove(code)
            output.keys.append(KeyEvent(virtualKey: code, pressed: false, modifiers: modifierFlags))
        }
        for code in order(keys.subtracting(heldKeys), modifiersFirst: true) {
            heldKeys.insert(code)
            output.keys.append(KeyEvent(virtualKey: code, pressed: true, modifiers: modifierFlags))
        }
        for button in heldMouseButtons.subtracting(mouseButtons).sorted() {
            output.mouseButtons.append(MouseButtonEvent(button: button, pressed: false))
        }
        for button in mouseButtons.subtracting(heldMouseButtons).sorted() {
            output.mouseButtons.append(MouseButtonEvent(button: button, pressed: true))
        }
        heldMouseButtons = mouseButtons
    }

    private var modifierFlags: UInt16 {
        heldKeys.reduce(0) { $0 | Self.modifierFlag($1) }
    }

    private static func modifierFlag(_ virtualKey: UInt16) -> UInt16 {
        switch virtualKey {
        case 0x10, 0xa0, 0xa1: return 0x01
        case 0x11, 0xa2, 0xa3: return 0x02
        case 0x12, 0xa4, 0xa5: return 0x04
        default: return 0
        }
    }

    // MARK: Geometry

    /// Squares the travel past the dead zone: fine near the centre, full speed at the rim.
    private static func curved(_ value: SteamControllerVector, deadZone: Float) -> SteamControllerVector {
        let length = value.length
        guard length.isFinite, length > deadZone else { return .zero }
        let scaled = min((length - deadZone) / (1 - deadZone), 1)
        let factor = scaled * scaled / length
        return SteamControllerVector(x: value.x * factor, y: value.y * factor)
    }

    /// Drops the travel inside the dead zone and stretches the rest back to the full range, so the
    /// stick still starts moving just past the dead zone and still reaches full deflection.
    private static func rescaled(_ value: SteamControllerVector, deadZone: Float) -> SteamControllerVector {
        let length = value.length
        guard length.isFinite, length > deadZone else { return .zero }
        let factor = min((length - deadZone) / (1 - deadZone), 1) / length
        return SteamControllerVector(x: value.x * factor, y: value.y * factor)
    }

    private static func heldDirections(_ value: SteamControllerVector, previous: Set<Direction>,
                                       press: Float, release: Float) -> Set<Direction> {
        var held: Set<Direction> = []
        func threshold(_ direction: Direction) -> Float { previous.contains(direction) ? release : press }
        if value.y >= threshold(.up) { held.insert(.up) }
        if value.y <= -threshold(.down) { held.insert(.down) }
        if value.x <= -threshold(.left) { held.insert(.left) }
        if value.x >= threshold(.right) { held.insert(.right) }
        return held
    }

    /// The slice a direction points at: the first item is at the top and they run clockwise.
    static func radialItem(_ value: SteamControllerVector, count: Int) -> Int? {
        guard count > 0, value.length >= menuCentre else { return nil }
        let slice = 2 * Double.pi / Double(count)
        var angle = atan2(Double(value.x), Double(value.y))
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + slice / 2) / slice) % count
    }

    /// The cell under the thumb, with items filling rows from the top left.
    static func gridItem(_ value: SteamControllerVector, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let column = min(max(Int((value.x + 1) / 2 * Float(columns)), 0), columns - 1)
        let row = min(max(Int((1 - value.y) / 2 * Float(rows)), 0), rows - 1)
        let index = row * columns + column
        return index < count ? index : nil
    }

    /// The number of columns `gridItem` lays a touch menu out in.
    static func gridColumns(count: Int) -> Int {
        max(Int(Double(count).squareRoot().rounded(.up)), 1)
    }

    /// Degrees per second in screen direction, with resting noise faded out near zero.
    private static func gyroScreenRate(pitch: Float, yaw: Float) -> (x: Double, y: Double) {
        let x = -Double(yaw) * 180 / .pi
        let y = -Double(pitch) * 180 / .pi
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return (0, 0) }
        let scale = min(1, magnitude / gyroSoftThresholdDegreesPerSecond)
        return (x * scale, y * scale)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(Int((value * 255).rounded()), 0), 255))
    }

    private static func axes(_ value: SteamControllerVector) -> (Int16, Int16) {
        let length = value.length
        guard length.isFinite else { return (0, 0) }
        let factor = length > 1 ? 1 / length : 1
        func axis(_ component: Float) -> Int16 { Int16(max(-32767, min(32767, (component * factor * 32767).rounded()))) }
        return (axis(value.x), axis(value.y))
    }
}
