#if os(iOS)
import SwiftUI

/// The outputs a control can be given, as the content of a picker.
struct ControllerActionOptions: View {
    var body: some View {
        Section {
            Text(ControllerAction.none.title).tag(ControllerAction.none)
        }
        Section("Gamepad") {
            ForEach(ControllerPadButton.allCases) { button in
                Text(button.title).tag(ControllerAction.pad(button))
            }
        }
        Section("Mouse") {
            ForEach([ControllerAction.mouse(1), .mouse(3), .mouse(2), .wheel(1), .wheel(-1)], id: \.self) { action in
                Text(action.title).tag(action)
            }
        }
        Section("OpenNOW") {
            ForEach([NativeStreamControllerShortcutAction.controls, .stats]) { action in
                Text(action.label).tag(ControllerAction.shortcut(action))
            }
        }
        ForEach(ControllerBindableKey.groups) { group in
            Section("Keyboard") {
                ForEach(group.keys, id: \.code) { key in
                    Text(key.name).tag(ControllerAction.key(key.code))
                }
            }
        }
    }
}

extension SteamInputConfig.Source {
    var title: String {
        switch self {
        case .buttonDiamond: return String(localized: "Face Buttons")
        case .dpad: return String(localized: "D-pad")
        case .joystick: return String(localized: "Left Stick")
        case .rightJoystick: return String(localized: "Right Stick")
        case .leftTrackpad: return String(localized: "Left Trackpad")
        case .rightTrackpad: return String(localized: "Right Trackpad")
        case .leftTrigger: return String(localized: "Left Trigger")
        case .rightTrigger: return String(localized: "Right Trigger")
        case .gyro: return String(localized: "Gyro")
        case .switches: return String(localized: "Bumpers, Back and Centre Buttons")
        case .system: return String(localized: "Steam Button and Grips")
        }
    }
}

extension SteamInputConfig.Mode {
    var title: String {
        switch self {
        case .fourButtons, .switches: return String(localized: "Buttons")
        case .dpad: return String(localized: "Directional Pad")
        case .singleButton: return String(localized: "Single Button")
        case .trigger: return String(localized: "Trigger")
        case .joystickMove: return String(localized: "Joystick")
        case .joystickCamera: return String(localized: "Camera Joystick")
        case .joystickMouse, .absoluteMouse, .gyroToMouse: return String(localized: "Mouse")
        case .mouseJoystick: return String(localized: "Mouse-Like Joystick")
        case .scrollWheel, .linearScroll: return String(localized: "Scroll Wheel")
        case .scroll2D: return String(localized: "Two-Way Scroll")
        case .gyroToJoystick: return String(localized: "Joystick")
        case .flickStick: return String(localized: "Flick Stick")
        case .mouseRegion: return String(localized: "Mouse Region")
        case .radialMenu: return String(localized: "Radial Menu")
        case .touchMenu: return String(localized: "Touch Menu")
        case .disabled: return String(localized: "Off")
        }
    }
}

extension SteamInputConfig.InputRef {
    var title: String {
        if input.hasPrefix("dpad_") {
            switch input {
            case "dpad_north": return String(localized: "Up")
            case "dpad_south": return String(localized: "Down")
            case "dpad_west": return String(localized: "Left")
            default: return String(localized: "Right")
            }
        }
        if let control = SteamControl.allCases.first(where: { $0.inputRef == self }) { return control.title }
        if input.hasPrefix("touch_menu_button_"), let index = Int(input.dropFirst("touch_menu_button_".count)) {
            return String(localized: "Menu Item \(index + 1)")
        }
        switch input {
        case "click": return String(localized: "Full Pull")
        case "edge": return String(localized: "Outer Ring")
        case "scroll_clockwise": return String(localized: "Turn Clockwise")
        case "scroll_counterclockwise": return String(localized: "Turn Anticlockwise")
        default: return input
        }
    }
}

extension SteamInputConfig.Activator {
    /// What this press does, such as "Long press: Ctrl+1".
    func summary(in config: SteamInputConfig) -> String {
        let sends = bindings.map { binding -> String in
            switch binding {
            case .changeSet(let set): return String(localized: "Switch to \(config.sets[set]?.title ?? "")")
            case .holdLayer(let layer): return String(localized: "Hold layer \(config.sets[layer]?.title ?? "")")
            case .addLayer(let layer): return String(localized: "Add layer \(config.sets[layer]?.title ?? "")")
            case .removeLayer(let layer): return String(localized: "Remove layer \(config.sets[layer]?.title ?? "")")
            case .modeShift(let source, let group):
                return String(localized: "\(source.title) becomes \(config.groups[group]?.mode.title ?? "")")
            default: return binding.shortTitle
            }
        }.joined(separator: "+")
        let text = sends.isEmpty ? String(localized: "Nothing") : sends
        let prefix: String
        switch kind {
        case .fullPress: prefix = toggle ? String(localized: "Toggle: ") : holdRepeats ? String(localized: "Turbo: ") : ""
        case .softPress: prefix = String(localized: "Soft press: ")
        case .longPress: prefix = String(localized: "Long press: ")
        case .doublePress: prefix = String(localized: "Double press: ")
        case .startPress: prefix = String(localized: "On press: ")
        case .release: prefix = String(localized: "On release: ")
        }
        return label.isEmpty ? prefix + text : "\(prefix)\(text) (\(label))"
    }
}

/// Shows what every control of an imported layout does, set by set, and lets single inputs be
/// given something else.
struct SteamLayoutDetailView: View {
    let layoutID: String
    /// Called after a re-binding so a running stream picks it up.
    let onChange: () -> Void
    @ObservedObject private var library = SteamLayoutLibrary.shared

    init(layoutID: String, onChange: @escaping () -> Void) {
        self.layoutID = layoutID
        self.onChange = onChange
    }

    private static let sourceOrder: [SteamInputConfig.Source] = [
        .buttonDiamond, .switches, .dpad, .leftTrigger, .rightTrigger, .joystick, .rightJoystick,
        .leftTrackpad, .rightTrackpad, .gyro, .system
    ]

    var body: some View {
        Form {
            if let published = library.published(layoutID), let entry = library.entries.first(where: { $0.id == layoutID }) {
                let sets = published.sets.values.sorted { ($0.isLayer ? 1 : 0, $0.id) < ($1.isLayer ? 1 : 0, $1.id) }
                ForEach(sets, id: \.id) { set in
                    ForEach(Self.sourceOrder.filter { set.groups[$0] != nil }, id: \.self) { source in
                        section(set: set, source: source, published: published, entry: entry)
                    }
                }
            } else {
                Text("This layout is no longer in the library.")
            }
        }
        .navigationTitle(library.entries.first { $0.id == layoutID }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func inputs(for source: SteamInputConfig.Source, group: SteamInputConfig.Group) -> [String] {
        // What the layout binds, plus the pad's own buttons there so an unused one can be given a job.
        var names = SteamControl.allCases.map(\.inputRef).filter { $0.source == source }.map(\.input)
        if source == .leftTrigger || source == .rightTrigger { names = ["edge", "click"] }
        for name in group.inputs.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private func section(set: SteamInputConfig.ActionSet, source: SteamInputConfig.Source,
                         published: SteamInputConfig, entry: SteamLayoutLibrary.Entry) -> some View {
        let group = set.groups[source].flatMap { published.groups[$0] } ?? .init(id: -1, mode: .disabled)
        return Section {
            LabeledContent("Behaves As", value: group.name.isEmpty ? group.mode.title : "\(group.mode.title) – \(group.name)")
            ForEach(inputs(for: source, group: group), id: \.self) { input in
                let key = SteamInputConfig.overrideKey(set: set.id, source: source, input: input)
                let ref = SteamInputConfig.InputRef(source: source, input: input)
                let summary = (group.inputs[input] ?? []).map { $0.summary(in: published) }.joined(separator: "\n")
                let override = entry.overrides[key].flatMap(ControllerAction.init(token:))
                NavigationLink {
                    OverrideEditor(title: ref.title, published: summary.isEmpty ? String(localized: "Nothing") : summary,
                                   override: override) { action in
                        library.setOverride(action, layout: layoutID, set: set.id, source: source, input: input)
                        onChange()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ref.title)
                        Text(override.map { String(localized: "Changed to \($0.title)") }
                             ?? (summary.isEmpty ? String(localized: "Nothing") : summary))
                            .font(.caption)
                            .foregroundStyle(override == nil ? Color.secondary : Color.accentColor)
                    }
                }
            }
        } header: {
            Text(set.isLayer ? "\(set.title) (Layer) · \(source.title)" : "\(set.title) · \(source.title)")
        }
    }

    private struct OverrideEditor: View {
        let title: String
        let published: String
        @State var override: ControllerAction?
        let save: (ControllerAction?) -> Void

        var body: some View {
            Form {
                Section("As Published") {
                    Text(published)
                }
                Section {
                    Toggle("Replace", isOn: Binding(
                        get: { override != nil },
                        set: { override = $0 ? (override ?? ControllerAction.none) : nil }
                    ))
                    if override != nil {
                        Picker("Sends", selection: Binding(
                            get: { override ?? .none },
                            set: { override = $0 }
                        )) {
                            ControllerActionOptions()
                        }
                        .pickerStyle(.navigationLink)
                    }
                } footer: {
                    Text("A replacement is one ordinary press. It takes the place of everything the layout does with this control in this action set, including long and double presses.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: override) { save($0) }
        }
    }
}
#endif
