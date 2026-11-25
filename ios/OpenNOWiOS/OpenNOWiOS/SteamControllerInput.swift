#if os(iOS)
import Combine
import Foundation

/// The Steam Controller as a source of stream input: it listens to the Bluetooth link while a
/// stream wants it, runs every report through the player's layout, and hands the result to the
/// input bridge, which owns sending it.
final class SteamControllerInputSource {
    /// Each report together with what it maps to. Called on the main queue.
    var onReport: ((SteamControllerReport, SteamInputEngine.Output) -> Void)?
    /// The on-screen menus the layout has open, whenever that changes.
    var onMenusChanged: (([SteamInputEngine.Menu]) -> Void)?
    /// The name of the action set the layout switched to.
    var onActionSetChanged: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private(set) var connected = false

    /// True while the stream does not own the pad, such as when the stream controls are open.
    /// Everything held is released on entry, and controls still down on exit stay ignored until
    /// they are let go.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            previousReportAt = nil
            updateAdvancing()
            guard suspended, let lastReport else { return }
            deliver(lastReport, mapper.apply(lastReport, at: Self.now, suspended: true))
        }
    }

    private static let advanceInterval: TimeInterval = 1.0 / 60.0
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let link = SteamControllerLink.shared
    private var mapper = SteamInputEngine()
    private var lastReport: SteamControllerReport?
    private var menus: [SteamInputEngine.Menu] = []
    private var actionSet: String?
    private var enabled = false
    private var attached = false
    private var listening = false
    private var status: AnyCancellable?
    private var advanceTimer: Timer?
    private var previousReportAt: TimeInterval?
    private var callbackGaps = NativeStreamInputTiming()
    private var handlingTime = NativeStreamInputTiming()

    var timingSummary: String {
        guard handlingTime.count > 0 else { return "" }
        return " steamCallbackGap[\(callbackGaps.summary)] steamHandling[\(handlingTime.summary)]"
    }

    func configure(enabled: Bool, config: SteamInputConfig, tuning: SteamControllerTuning) {
        if mapper.config != config { actionSet = nil }
        mapper.config = config
        mapper.tuning = tuning
        self.enabled = enabled
        updateListening()
        link.gyroEnabled = listening && mapper.wantsGyro
        updateAdvancing()
    }

    func attach() {
        guard !attached else { return }
        callbackGaps = NativeStreamInputTiming()
        handlingTime = NativeStreamInputTiming()
        previousReportAt = nil
        attached = true
        updateListening()
    }

    func detach() {
        attached = false
        updateListening()
    }

    /// Motor speeds as the host sends them, 0...65535, before the player's strength setting.
    func setRumble(strongMagnitude: Int, weakMagnitude: Int, gain: Double) {
        func speed(_ magnitude: Int) -> UInt16 { UInt16(min(max(Double(magnitude) * gain, 0), 65_535)) }
        link.setRumble(lowFrequency: speed(strongMagnitude), highFrequency: speed(weakMagnitude))
    }

    private func updateListening() {
        let wanted = enabled && attached
        guard wanted != listening else { return }
        listening = wanted
        if wanted {
            status = link.$status.sink { [weak self] status in
                if case .connected = status { self?.setConnected(true) } else { self?.setConnected(false) }
            }
            link.attach(self) { [weak self] report in self?.handle(report) }
            link.gyroEnabled = mapper.wantsGyro
        } else {
            status = nil
            link.setRumble(lowFrequency: 0, highFrequency: 0)
            link.gyroEnabled = false
            link.detach(self)
            setConnected(false)
        }
    }

    private func setConnected(_ next: Bool) {
        guard next != connected else { return }
        connected = next
        if !next {
            previousReportAt = nil
            lastReport = nil
            deliver(SteamControllerReport(), mapper.releaseAll())
        }
        updateAdvancing()
        onConnectionChanged?(next)
    }

    private func handle(_ report: SteamControllerReport) {
        guard connected else { return }
        lastReport = report
        let arrivedAt = Self.now
        let playing = !suspended
        if playing {
            if let previousReportAt { callbackGaps.record(arrivedAt - previousReportAt) }
            previousReportAt = arrivedAt
        }
        deliver(report, mapper.apply(report, at: arrivedAt, suspended: suspended))
        if playing { handlingTime.record(Self.now - arrivedAt) }
    }

    private func deliver(_ report: SteamControllerReport, _ output: SteamInputEngine.Output) {
        onReport?(report, output)
        if mapper.actionSetTitle != actionSet {
            let first = actionSet == nil
            actionSet = mapper.actionSetTitle
            if !first, let actionSet { onActionSetChanged?(actionSet) }
        }
        guard mapper.menus != menus else { return }
        menus = mapper.menus
        onMenusChanged?(menus)
    }

    /// Time has to pass even when no report arrives: a held stick keeps moving the pointer, long
    /// presses come due and taps end.
    private func updateAdvancing() {
        let wanted = connected && !suspended
        guard wanted != (advanceTimer != nil) else { return }
        advanceTimer?.invalidate()
        advanceTimer = nil
        guard wanted else { return }
        advanceTimer = Timer.scheduledTimer(withTimeInterval: Self.advanceInterval, repeats: true) { [weak self] _ in
            guard let self, let report = self.lastReport else { return }
            self.deliver(report, self.mapper.advance(to: Self.now))
        }
    }
}
#endif
