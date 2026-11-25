#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension SteamControl {
    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftBumper: return String(localized: "Left Bumper")
        case .rightBumper: return String(localized: "Right Bumper")
        case .leftTrigger: return String(localized: "Left Trigger")
        case .rightTrigger: return String(localized: "Right Trigger")
        case .view: return String(localized: "View")
        case .menu: return String(localized: "Menu")
        case .steam: return String(localized: "Steam Button")
        case .quickAccess: return String(localized: "Quick Access Button")
        case .dpadUp: return String(localized: "D-pad Up")
        case .dpadDown: return String(localized: "D-pad Down")
        case .dpadLeft: return String(localized: "D-pad Left")
        case .dpadRight: return String(localized: "D-pad Right")
        case .leftStickClick: return String(localized: "Left Stick Click")
        case .rightStickClick: return String(localized: "Right Stick Click")
        case .l4: return "L4"
        case .l5: return "L5"
        case .r4: return "R4"
        case .r5: return "R5"
        case .leftPadClick: return String(localized: "Left Trackpad Click")
        case .rightPadClick: return String(localized: "Right Trackpad Click")
        case .leftPadTouch: return String(localized: "Left Trackpad Touch")
        case .rightPadTouch: return String(localized: "Right Trackpad Touch")
        case .leftStickTouch: return String(localized: "Left Stick Touch")
        case .rightStickTouch: return String(localized: "Right Stick Touch")
        case .leftGrip: return String(localized: "Left Grip")
        case .rightGrip: return String(localized: "Right Grip")
        }
    }
}

extension ControllerPadButton {
    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .lt: return "LT"
        case .rt: return "RT"
        case .ls: return String(localized: "Left Stick Click")
        case .rs: return String(localized: "Right Stick Click")
        case .back: return String(localized: "View")
        case .start: return String(localized: "Menu")
        case .guide: return String(localized: "Home")
        case .up: return String(localized: "D-pad Up")
        case .down: return String(localized: "D-pad Down")
        case .left: return String(localized: "D-pad Left")
        case .right: return String(localized: "D-pad Right")
        }
    }
}

extension ControllerAction {
    var title: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .pad(let button): return String(localized: "Gamepad \(button.title)")
        case .key(let code): return String(localized: "Key \(ControllerBindableKey.name(code))")
        case .mouse(let button):
            switch button {
            case 2: return String(localized: "Middle Click")
            case 3: return String(localized: "Right Click")
            default: return String(localized: "Left Click")
            }
        case .wheel(let direction): return direction < 0 ? String(localized: "Scroll Down") : String(localized: "Scroll Up")
        case .shortcut(let action): return action.label
        }
    }
}

extension SteamSurface {
    var title: String {
        switch self {
        case .leftStick: return String(localized: "Left Stick")
        case .rightStick: return String(localized: "Right Stick")
        case .leftPad: return String(localized: "Left Trackpad")
        case .rightPad: return String(localized: "Right Trackpad")
        }
    }
}

extension ControllerSurfaceMode {
    var title: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .leftStick: return String(localized: "Left Stick")
        case .rightStick: return String(localized: "Right Stick")
        case .mouse: return String(localized: "Mouse")
        case .scroll: return String(localized: "Scroll Wheel")
        case .dpad: return String(localized: "D-pad")
        case .wasd: return String(localized: "W A S D Keys")
        case .arrows: return String(localized: "Arrow Keys")
        }
    }

    /// Whether the sensitivity setting changes anything in this mode on the given surface.
    func usesSensitivity(on surface: SteamSurface) -> Bool {
        switch self {
        case .mouse, .scroll: return true
        case .leftStick, .rightStick: return surface.isPad
        case .none, .dpad, .wasd, .arrows: return false
        }
    }
}

/// Lets the player turn the direct Steam Controller connection on, see that the pad is found,
/// and choose what each control sends. Used from Settings and from the stream controls.
struct SteamControllerSettingsView: View {
    @Binding var settings: AppSettings
    /// The game being played, when opened from a stream; offers a layout for that game alone.
    let gameTitle: String?
    @ObservedObject private var link = SteamControllerLink.shared
    @ObservedObject private var library = SteamLayoutLibrary.shared
    @StateObject private var presence = Presence()
    @State private var reference = ""
    @State private var importing = false
    @State private var importMessage: String?
    @State private var filePickerPresented = false

    init(settings: Binding<AppSettings>, gameTitle: String? = nil) {
        _settings = settings
        self.gameTitle = gameTitle
    }

    /// Keeps the Bluetooth link alive while this screen is showing.
    private final class Presence: ObservableObject {}

    private static let controlGroups: [(title: LocalizedStringKey, controls: [SteamControl])] = [
        ("Face Buttons", [.a, .b, .x, .y]),
        ("Bumpers and Triggers", [.leftBumper, .rightBumper, .leftTrigger, .rightTrigger]),
        ("Back Buttons", [.l4, .l5, .r4, .r5]),
        ("Centre Buttons", [.view, .menu, .steam, .quickAccess]),
        ("D-pad", [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
        ("Stick and Trackpad Clicks", [.leftStickClick, .rightStickClick, .leftPadClick, .rightPadClick]),
        ("Touch Sensors", [.leftGrip, .rightGrip, .leftStickTouch, .rightStickTouch, .leftPadTouch, .rightPadTouch])
    ]

    var body: some View {
        Form {
            connectionSection
            if settings.steamControllerEnabled {
                if let report = link.preview { liveSection(report) }
                layoutSection
                importSection
                if let imported = activeImport {
                    importedSection(imported)
                } else {
                    presetSection
                    ForEach(Self.controlGroups, id: \.controls) { group in
                        Section(group.title) {
                            ForEach(group.controls) { control in actionPicker(control) }
                        }
                    }
                    surfaceSection
                    gyroSection
                }
                calibrationSection
                if !link.events.isEmpty { eventsSection }
            }
        }
        .navigationTitle("Steam Controller")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { updatePresence(settings.steamControllerEnabled) }
        .onChange(of: settings.steamControllerEnabled) { enabled in updatePresence(enabled) }
        .onDisappear { link.detach(presence) }
        .fileImporter(isPresented: $filePickerPresented, allowedContentTypes: [.data, .text]) { result in
            importFile(result)
        }
    }

    private func updatePresence(_ enabled: Bool) {
        if enabled { link.attach(presence) } else { link.detach(presence) }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            Toggle("Use Trackpads, Back Buttons and Gyro", isOn: $settings.steamControllerEnabled)
            if settings.steamControllerEnabled {
                LabeledContent("Status", value: statusText)
                switch link.status {
                case .searching:
                    Button(link.scanning ? "Searching…" : "Search for a Controller") { link.scan() }
                        .disabled(link.scanning)
                case .notAllowed:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                default:
                    EmptyView()
                }
            }
        } footer: {
            Text("Pair the Steam Controller with this device in Bluetooth settings first. OpenNOW then reads it directly, which is the only way to reach its trackpads, back buttons, grip sensors and gyro, and asks for Bluetooth access to do so. While a game is running the controller stops moving the system pointer and follows the layout below.")
        }
    }

    private var statusText: String {
        switch link.status {
        case .off: return String(localized: "Off")
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .notAllowed: return String(localized: "Bluetooth access is not allowed")
        case .unsupported: return String(localized: "Bluetooth is not available")
        case .searching: return String(localized: "Looking for a paired controller")
        case .connecting(let name): return String(localized: "Connecting to \(name)")
        case .connected(let name): return String(localized: "Connected to \(name)")
        }
    }

    // MARK: Live input

    private func liveSection(_ report: SteamControllerReport) -> some View {
        let pressed = SteamControl.allCases.filter { control in
            if let button = control.button { return report.buttons.contains(button) }
            return (control == .leftTrigger ? report.leftTrigger : report.rightTrigger) >= 0.3
        }
        return Section {
            LabeledContent("Pressed", value: pressed.isEmpty ? String(localized: "Nothing") : pressed.map(\.title).joined(separator: ", "))
            LabeledContent("Sticks", value: "\(point(report.leftStick))   \(point(report.rightStick))")
            LabeledContent("Trackpads", value: "\(pad(report.leftPad, touched: report.buttons.contains(.leftPadTouch)))   \(pad(report.rightPad, touched: report.buttons.contains(.rightPadTouch)))")
            LabeledContent("Triggers", value: "\(percent(report.leftTrigger))   \(percent(report.rightTrigger))")
        } header: {
            Text("Live Input")
        } footer: {
            Text("Press and move the controls to check that each one is seen.")
        }
        .monospacedDigit()
    }

    private func point(_ value: SteamControllerVector) -> String {
        String(format: "%+.2f, %+.2f", value.x, value.y)
    }

    private func pad(_ value: SteamControllerVector, touched: Bool) -> String {
        touched ? point(value) : "–"
    }

    private func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: Layout library

    /// The imported layout in effect here, or nil when the layout made in OpenNOW is.
    private var activeImport: SteamLayoutLibrary.Entry? {
        let id = settings.steamControllerLayoutID(forGame: gameTitle)
        return library.entries.first { $0.id == id }
    }

    private var layoutSection: some View {
        Section {
            Picker("Layout", selection: $settings.steamControllerActiveLayout) {
                Text("Made in OpenNOW").tag("")
                ForEach(library.entries) { entry in Text(entry.title).tag(entry.id) }
            }
            if let gameTitle {
                let key = SteamLayoutLibrary.gameKey(gameTitle)
                Picker("For \(gameTitle)", selection: Binding<String?>(
                    get: { settings.steamControllerGameLayouts[key] },
                    set: { settings.steamControllerGameLayouts[key] = $0 }
                )) {
                    Text("Same as Other Games").tag(String?.none)
                    Text("Made in OpenNOW").tag(String?.some(""))
                    ForEach(library.entries) { entry in Text(entry.title).tag(String?.some(entry.id)) }
                }
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("A layout chosen for one game is used whenever that game is played. Open this screen from the stream controls to choose one for the game you are in.")
        }
    }

    private var importSection: some View {
        Section {
            NavigationLink("Find Layouts for a Game") {
                SteamLayoutSearchView(gameTitle: gameTitle) { finishImport($0) }
            }
            TextField("Steam layout link or ID", text: $reference)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { importFromSteam() }
            Button(importing ? "Importing…" : "Import from Steam") { importFromSteam() }
                .disabled(importing || SteamLayoutLibrary.workshopID(in: reference) == nil)
            Button("Import a Layout File…") { filePickerPresented = true }
            if let importMessage {
                Text(importMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(library.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                    Text(entry.controllerType.replacingOccurrences(of: "controller_", with: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for id in offsets.map({ library.entries[$0].id }) { removeLayout(id) }
            }
        } header: {
            Text("Community Layouts")
        } footer: {
            Text("Search Steam for a game's community layouts, or paste a layout's share link from Steam (steam://controllerconfig/…), a Steam Workshop link, or just its ID. Layouts made for the Steam Deck, the Steam Controller or other pads all work; controls this pad does not have are skipped. A layout file exported from a computer can be imported from Files. Swipe a layout to remove it.")
        }
    }

    private func importedSection(_ entry: SteamLayoutLibrary.Entry) -> some View {
        Section {
            LabeledContent("In Use", value: entry.title)
            NavigationLink("See and Change What Each Control Does") {
                SteamLayoutDetailView(layoutID: entry.id) { settings.steamControllerLayoutRevision &+= 1 }
            }
            if entry.notes.isEmpty {
                Text("Everything in this layout is supported.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.notes, id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Imported Layout")
        } footer: {
            Text("Imported layouts run as published, including their action sets, layers, long and double presses and on-screen menus, and single controls can be given something else. The Steam button opens the stream controls unless you change it.")
        }
    }

    private func importFromSteam() {
        guard !importing, SteamLayoutLibrary.workshopID(in: reference) != nil else { return }
        importing = true
        importMessage = nil
        let text = reference
        Task { @MainActor in
            defer { importing = false }
            do {
                finishImport(try await library.importFromSteam(text))
                reference = ""
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= SteamLayoutLibrary.maximumFileBytes else { throw SteamLayoutLibrary.ImportFailure.tooLarge }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            finishImport(try library.add(vdf: text, fallbackTitle: url.deletingPathExtension().lastPathComponent))
        } catch {
            importMessage = error.localizedDescription
        }
    }

    /// A newly imported layout is put to use straight away: for this game when there is one.
    private func finishImport(_ entry: SteamLayoutLibrary.Entry) {
        if let gameTitle {
            settings.steamControllerGameLayouts[SteamLayoutLibrary.gameKey(gameTitle)] = entry.id
        } else {
            settings.steamControllerActiveLayout = entry.id
        }
        importMessage = entry.notes.isEmpty
            ? String(localized: "Imported \(entry.title).")
            : String(localized: "Imported \(entry.title). Some of it is not supported; see below.")
    }

    private func removeLayout(_ id: String) {
        library.remove(id)
        if settings.steamControllerActiveLayout == id { settings.steamControllerActiveLayout = "" }
        settings.steamControllerGameLayouts = settings.steamControllerGameLayouts.filter { $0.value != id }
    }

    // MARK: Layout made in OpenNOW

    private var presetSection: some View {
        Section {
            Button("Gamepad") { settings.steamControllerLayout = SteamControllerLayout() }
            Button("Keyboard and Mouse") { settings.steamControllerLayout = .keyboardAndMouse }
        } header: {
            Text("Start From a Layout")
        } footer: {
            Text("Gamepad sends the usual controller buttons, with the right trackpad as a mouse. Keyboard and Mouse suits games without controller support: the left stick walks with W A S D, the right stick and trackpad aim, and the triggers click. Choosing one replaces the layout below.")
        }
    }

    private func actionPicker(_ control: SteamControl) -> some View {
        Picker(control.title, selection: Binding(
            get: { settings.steamControllerLayout.action(for: control) },
            set: { settings.steamControllerLayout.setAction($0, for: control) }
        )) {
            ControllerActionOptions()
        }
        .pickerStyle(.navigationLink)
    }

    private var surfaceSection: some View {
        Section {
            ForEach(SteamSurface.allCases) { surface in
                let mode = settings.steamControllerLayout.mode(for: surface)
                Picker(surface.title, selection: Binding(
                    get: { settings.steamControllerLayout.mode(for: surface) },
                    set: { settings.steamControllerLayout.setMode($0, for: surface) }
                )) {
                    ForEach(ControllerSurfaceMode.allCases) { Text($0.title).tag($0) }
                }
                if mode.usesSensitivity(on: surface) {
                    sensitivitySlider(String(localized: "\(surface.title) Sensitivity"), key: surface.rawValue)
                }
            }
        } header: {
            Text("Sticks and Trackpads")
        } footer: {
            Text("A trackpad set to a stick deflects it by where your thumb rests. Set to W A S D, arrow keys or the D-pad, it presses the direction you touch.")
        }
    }

    private var gyroSection: some View {
        Section {
            Picker("Gyro", selection: $settings.steamControllerLayout.gyroMode) {
                Text("Off").tag(ControllerGyroMode.off)
                Text("Mouse").tag(ControllerGyroMode.mouse)
                Text("Right Stick").tag(ControllerGyroMode.rightStick)
            }
            if settings.steamControllerLayout.gyroMode != .off {
                Picker("Active", selection: $settings.steamControllerLayout.gyroActivator) {
                    Text("Always").tag(SteamControl?.none)
                    ForEach(SteamControl.allCases) { control in
                        Text("While Holding \(control.title)").tag(SteamControl?.some(control))
                    }
                }
                .pickerStyle(.navigationLink)
                sensitivitySlider(String(localized: "Gyro Sensitivity"), key: SteamControllerLayout.gyroSensitivityKey)
            }
        } header: {
            Text("Gyro")
        } footer: {
            Text("Turning and tilting the controller aims. Holding a grip sensor to activate it lets you rest the controller without moving the view.")
        }
    }

    private func sensitivitySlider(_ title: String, key: String) -> some View {
        let range = SteamControllerLayout.sensitivityRange
        let value = Binding<Double>(
            get: { Double(settings.steamControllerLayout.sensitivity(key)) },
            set: { settings.steamControllerLayout.setSensitivity(Int($0.rounded()), for: key) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text("\(Int(value.wrappedValue))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound), step: 10)
                .accessibilityLabel(title)
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        Section {
            tuningSlider("Trackpad Pointer Speed", value: $settings.steamControllerTuning.trackpadMouse)
            tuningSlider("Stick Pointer Speed", value: $settings.steamControllerTuning.stickMouse)
            tuningSlider("Gyro Speed", value: $settings.steamControllerTuning.gyro)
            tuningSlider("Scroll Speed", value: $settings.steamControllerTuning.scroll)
            tuningSlider("Stick Dead Zone", value: $settings.steamControllerTuning.stickDeadZone,
                         range: SteamControllerTuning.stickDeadZoneRange, step: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Flick Stick Full Turn")
                    Spacer(minLength: 12)
                    Text("\(settings.steamControllerTuning.flickTurn)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(settings.steamControllerTuning.flickTurn) },
                    set: { settings.steamControllerTuning.flickTurn = Int($0.rounded()) }
                ), in: Double(SteamControllerTuning.flickTurnRange.lowerBound)...Double(SteamControllerTuning.flickTurnRange.upperBound),
                   step: 100)
                    .accessibilityLabel("Flick Stick Full Turn")
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("These scale whichever layout is in use, on top of its own settings. A layout does not know how fast a game moves its pointer, so set these to taste, or to match how the same layout feels in Steam. Stick Dead Zone is how far a stick must move before it counts, whether it steers, moves the pointer or scrolls; raise it if a stick drifts. For flick stick, raise or lower the full turn until pushing the stick straight back turns the view exactly halfway round.")
        }
    }

    private func tuningSlider(_ title: LocalizedStringKey, value: Binding<Int>,
                              range: ClosedRange<Int> = SteamControllerTuning.percentRange,
                              step: Double = 10) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text("\(value.wrappedValue)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: step)
                .accessibilityLabel(title)
        }
    }

    // MARK: Connection log

    private var eventsSection: some View {
        Section {
            DisclosureGroup("Connection Log") {
                ForEach(Array(link.events.enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("If the controller is not found, this shows how far the connection got.")
        }
    }
}
#endif
