import SwiftUI
import UIKit

/// A full-screen controller owns the stream's pointer and status bar preferences.
/// An embedded SwiftUI video view cannot override the app's root controller.
struct NativeStreamPresentation<Content: View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let content: Content
    /// Called with `true` when a stream's controller is made and with `false` once UIKit has
    /// finished taking it down, exactly once each. In between UIKit refuses any other
    /// presentation, such as a sheet over the catalog.
    let onCoverChange: (Bool) -> Void

    init(onCoverChange: @escaping (Bool) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.onCoverChange = onCoverChange
        self.content = content()
    }

    func makeUIViewController(context: Context) -> NativeStreamPresentationController {
        let controller = NativeStreamPresentationController(content: AnyView(content.environment(\.scenePhase, scenePhase)))
        controller.onCoverChange = onCoverChange
        // Not from inside the view update that is making this controller.
        DispatchQueue.main.async { [onCoverChange] in onCoverChange(true) }
        return controller
    }

    func updateUIViewController(_ controller: NativeStreamPresentationController, context: Context) {
        controller.host.rootView = AnyView(content.environment(\.scenePhase, scenePhase))
        controller.onCoverChange = onCoverChange
    }

    static func dismantleUIViewController(_ controller: NativeStreamPresentationController, coordinator: ()) {
        controller.tearDown()
    }
}

final class NativeStreamPresentationController: UIViewController {
    let host: NativeStreamHostingController
    var onCoverChange: (Bool) -> Void = { _ in }
    private var dismantled = false
    private let orientationBeforePresentation: UIInterfaceOrientationMask

    init(content: AnyView) {
        orientationBeforePresentation = StreamOrientation.currentOrientation
        host = NativeStreamHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        host.modalPresentationStyle = .fullScreen
        host.isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentHost()
    }

    /// UIKit refuses to present over a controller that is already presenting and reports it only
    /// in the log, which would leave this controller's empty view on screen. A sheet over the
    /// catalog can still be up when a stream opens, so it goes first.
    private func presentHost() {
        guard !dismantled, host.presentingViewController == nil, let window = view.window else { return }
        if let blocking = window.rootViewController?.presentedViewController {
            if !blocking.isBeingDismissed {
                blocking.dismiss(animated: false) { [weak self] in self?.presentHost() }
            } else if let coordinator = blocking.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.presentHost() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.presentHost() }
            }
            return
        }
        StreamOrientation.setStreaming(true, restoring: orientationBeforePresentation)
        present(host, animated: false)
    }

    func tearDown() {
        guard !dismantled else { return }
        dismantled = true
        host.releaseSystemPreferences(restoreOrientation: false)
        if host.presentingViewController != nil {
            // SwiftUI lets go of this controller before UIKit is done, so the callback is held
            // on its own rather than reached through `self`.
            host.dismiss(animated: false) { [weak self, onCoverChange] in
                StreamOrientation.setStreaming(false)
                self?.setNeedsStatusBarAppearanceUpdate()
                onCoverChange(false)
            }
        } else {
            StreamOrientation.setStreaming(false)
            setNeedsStatusBarAppearanceUpdate()
            DispatchQueue.main.async { [onCoverChange] in onCoverChange(false) }
        }
    }
}

/// What iOS answered the last time the stream asked for pointer lock. The in-game menu releases
/// the lock while it is open, so the readout there needs the answer from before it opened.
enum NativeStreamPointerLockDiagnostics {
    enum Outcome {
        case notRequested, granted, refused
        var label: String {
            switch self {
            case .notRequested: return "Not requested yet"
            case .granted: return "Granted by iOS"
            case .refused: return "Refused by iOS"
            }
        }
    }
    static private(set) var lastOutcome: Outcome = .notRequested
    static func record(locked: Bool) { lastOutcome = locked ? .granted : .refused }
}

final class NativeStreamHostingController: UIHostingController<AnyView> {
    var pointerCaptureRequested = false {
        didSet {
            guard oldValue != pointerCaptureRequested else { return }
            setNeedsUpdateOfPrefersPointerLocked()
            guard pointerCaptureRequested else { return }
            // iOS answers asynchronously and posts nothing when it refuses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.recordPointerLock() }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(recordPointerLock),
            name: UIPointerLockState.didChangeNotification, object: nil)
    }

    @objc private func recordPointerLock() {
        guard pointerCaptureRequested, let state = view.window?.windowScene?.pointerLockState else { return }
        NativeStreamPointerLockDiagnostics.record(locked: state.isLocked)
    }

    override var prefersPointerLocked: Bool { pointerCaptureRequested }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        statusBarHidden ? .landscape : StreamOrientation.supportedOrientations
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if statusBarHidden { StreamOrientation.setStreaming(true) }
    }

    private(set) var statusBarHidden = true {
        didSet {
            guard oldValue != statusBarHidden else { return }
            // Invalidate outside a SwiftUI transaction when returning to the catalog.
            DispatchQueue.main.async { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    func releaseSystemPreferences(restoreOrientation: Bool = true) {
        pointerCaptureRequested = false
        statusBarHidden = false
        if restoreOrientation { StreamOrientation.setStreaming(false) }
    }

    override var prefersStatusBarHidden: Bool { statusBarHidden }

    // The full-screen container owns this preference, independent of SwiftUI children.
    override var childForStatusBarHidden: UIViewController? { nil }
}

struct NativeStreamPresentationPreferences: UIViewControllerRepresentable {
    let pointerCaptureRequested: Bool

    func makeUIViewController(context: Context) -> PreferenceController {
        PreferenceController()
    }

    func updateUIViewController(_ controller: PreferenceController, context: Context) {
        controller.pointerCaptureRequested = pointerCaptureRequested
        controller.applyPreferences()
    }

    static func dismantleUIViewController(_ controller: PreferenceController, coordinator: ()) {
        controller.pointerCaptureRequested = false
        controller.applyPreferences()
    }

    final class PreferenceController: UIViewController {
        var pointerCaptureRequested = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyPreferences()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyPreferences()
        }

        func applyPreferences() {
            var ancestor = parent
            while let controller = ancestor {
                if let host = controller as? NativeStreamHostingController {
                    host.pointerCaptureRequested = pointerCaptureRequested
                    return
                }
                ancestor = controller.parent
            }
        }
    }
}

enum NativeStreamPointerCapturePolicy {
    static func shouldCapture(videoActive: Bool, sceneActive: Bool, controlsVisible: Bool,
                              editing: Bool, guidanceVisible: Bool, pipActive: Bool) -> Bool {
        videoActive && sceneActive && !controlsVisible && !editing && !guidanceVisible && !pipActive
    }
}
