import AVFoundation
import GameController
import SwiftUI
import TwilightKit

/// The window that shows the stream. Resize it to make the screen as big as you like.
struct StreamWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = model.session {
                StreamContent(session: session, settings: model.settings) { quitApp in
                    Task {
                        await model.endSession(quitApp: quitApp)
                        dismissWindow(id: "stream")
                    }
                }
            } else {
                // visionOS can restore this window on relaunch with no stream behind it; close it
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { dismissWindow(id: "stream") }
            }
        }
        .onDisappear {
            Task { await model.endSession(quitApp: false) }
        }
    }
}

private struct StreamContent: View {
    let session: StreamSession
    let settings: StreamSettings
    var end: (_ quitApp: Bool) -> Void

    @State private var rightClickMode = false
    @State private var showKeyboard = false
    @State private var showStats: Bool
    @State private var mouseDown = false
    @State private var trackpad = TrackpadState()

    init(session: StreamSession, settings: StreamSettings, end: @escaping (Bool) -> Void) {
        self.session = session
        self.settings = settings
        self.end = end
        _showStats = State(initialValue: settings.showPerformanceOverlay)
    }

    /// Height of the black margin under the video, as a fraction of the video's height.
    /// visionOS reserves the window's bottom edge for its own controls, which swallowed pinches
    /// on the host's taskbar. The margin moves that edge off the picture, and pinches in the
    /// margin count as the bottom row of the screen.
    static let bottomMarginFraction: CGFloat = 0.025

    private var aspect: CGFloat {
        CGFloat(settings.width) / CGFloat(settings.height)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VideoLayerView(layer: session.video.displayLayer, bottomMarginFraction: Self.bottomMarginFraction,
                               streamAspect: aspect, onPointer: handlePointer)

                if showStats, case .streaming = session.state {
                    StatsHUD(stats: session.stats, poor: session.connectionPoor, hostHdr: session.hostHdrActive)
                        .padding(24)
                }

                if session.connectionPoor && !showStats {
                    Label("Poor connection", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                        .padding(12)
                        .glassBackgroundEffect()
                        .padding(24)
                }

                statusOverlay
            }
        }
        .background(.black)
        .clipShape(.rect(cornerRadius: 24))
        // The window itself is sized to this shape (see LayerHostView.applyWindowShape); if it's
        // ever briefly off, the leftover space stays transparent rather than showing black bars.
        .aspectRatio(aspect / (1 + Self.bottomMarginFraction), contentMode: .fit)
        .preferredSurroundingsEffect(settings.dimSurroundings && session.state == .streaming ? .systemDark : nil)
        .persistentSystemOverlays(.hidden)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controls
        }
    }

    // MARK: Pointer

    private func handlePointer(_ event: PointerEvent) {
        guard session.state == .streaming else { return }
        switch settings.pointerMode {
        case .trackpad: handleTrackpad(event)
        case .direct: handleDirect(event)
        }
    }

    /// Trackpad mode: pinch and drag moves the cursor, a quick pinch clicks, and pinch-hold-move drags.
    /// Uses relative mouse motion, which every host honours (Twilight's default mouse mode).
    private func handleTrackpad(_ event: PointerEvent) {
        let t = trackpad
        let input = session.input
        switch event {
        case .hover(let point, let size):
            if let last = t.lastHover {
                moveRelative(from: last, to: point, in: size)
            }
            t.lastHover = point

        case .down(let point, _):
            t.lastHover = nil
            t.start = point
            t.last = point
            t.startTime = CACurrentMediaTime()
            t.travelled = 0
            t.dragging = false
            t.button = rightClickMode ? 3 : 1 // BUTTON_RIGHT : BUTTON_LEFT
            t.holdTimer?.invalidate()
            // Holding still for a moment starts a drag (button held while you move)
            t.holdTimer = Timer.scheduledTimer(withTimeInterval: TrackpadState.holdDelay, repeats: false) { _ in
                guard t.travelled < TrackpadState.tapSlop, !t.dragging else { return }
                t.dragging = true
                input.sendMouseButton(t.button, pressed: true)
            }

        case .moved(let point, let size):
            t.travelled += hypot(point.x - t.last.x, point.y - t.last.y)
            moveRelative(from: t.last, to: point, in: size)
            t.last = point

        case .up(let point, let size):
            t.holdTimer?.invalidate()
            t.holdTimer = nil
            moveRelative(from: t.last, to: point, in: size)
            TwilightLog.debug("Trackpad gesture: travelled \(Int(t.travelled)) pt, sent (\(t.sentX), \(t.sentY)) px, \(t.dragging ? "drag" : t.travelled < TrackpadState.tapSlop ? "click" : "move")")
            t.sentX = 0
            t.sentY = 0
            if t.dragging {
                input.sendMouseButton(t.button, pressed: false)
                rightClickMode = false
            } else if t.travelled < TrackpadState.tapSlop {
                // A quick pinch: click where the cursor is
                input.sendMouseButton(t.button, pressed: true)
                input.sendMouseButton(t.button, pressed: false)
                rightClickMode = false
            }
            t.dragging = false
        }
    }

    private func moveRelative(from a: CGPoint, to b: CGPoint, in size: CGSize) {
        guard size.width > 0 else { return }
        // Map view points to host pixels, then apply the pointer speed
        let scale = Double(settings.width) / size.width * settings.pointerSpeed
        let t = trackpad
        let fx = (b.x - a.x) * scale + t.remainder.x
        let fy = (b.y - a.y) * scale + t.remainder.y
        let dx = Int(fx.rounded(.towardZero))
        let dy = Int(fy.rounded(.towardZero))
        t.remainder = CGPoint(x: fx - Double(dx), y: fy - Double(dy))
        t.sentX += dx
        t.sentY += dy
        session.input.sendMouseMove(dx: dx, dy: dy)
    }

    /// Direct mode: look and pinch moves the host's cursor there and clicks; pinch and drag drags.
    /// Uses absolute positioning, which some hosts ignore.
    private func handleDirect(_ event: PointerEvent) {
        let button: Int32 = rightClickMode ? 3 : 1 // BUTTON_RIGHT : BUTTON_LEFT
        switch event {
        case .hover(let point, let size):
            moveCursor(to: point, in: size)
        case .down(let point, let size):
            moveCursor(to: point, in: size, log: true)
            if !mouseDown {
                mouseDown = true
                session.input.sendMouseButton(button, pressed: true)
            }
        case .moved(let point, let size):
            moveCursor(to: point, in: size)
        case .up(let point, let size):
            guard mouseDown else { return }
            moveCursor(to: point, in: size, log: true)
            session.input.sendMouseButton(button, pressed: false)
            mouseDown = false
            rightClickMode = false
        }
    }

    private func moveCursor(to point: CGPoint, in size: CGSize, log: Bool = false) {
        guard size.width > 0, size.height > 0 else {
            TwilightLog.error("Pointer at \(point) ignored: video view has no size (\(size))")
            return
        }
        let x = max(0, min(1, point.x / size.width)) * Double(settings.width)
        let y = max(0, min(1, point.y / size.height)) * Double(settings.height)
        if log {
            TwilightLog.debug("Pointer at \(point) in view \(size) -> host (\(Int(x)), \(Int(y))) of \(settings.width)x\(settings.height)")
        }
        session.input.sendMousePosition(x: x, y: y, streamWidth: settings.width, streamHeight: settings.height)
    }

    // MARK: Overlays

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.state {
        case .idle, .starting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(statusText)
                    .font(.title3)
                Button("Cancel") { end(false) }
            }
            .padding(40)
            .glassBackgroundEffect()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ended(let message?):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
                Button("Close") { end(false) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .glassBackgroundEffect()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ended(nil):
            Color.clear.onAppear { end(false) }
        case .streaming:
            EmptyView()
        }
    }

    private var statusText: String {
        if case .starting(let text) = session.state { return text }
        return "Starting \(session.appName)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("End Stream", systemImage: "xmark") { end(false) }
                .help("Disconnect. The game keeps running on the host.")
            Button("Quit Game", systemImage: "power") { end(true) }
                .help("Disconnect and quit the game on the host.")

            Divider().frame(height: 32)

            Toggle(isOn: $rightClickMode) {
                Label("Right Click", systemImage: "cursorarrow.click.2")
            }
            .toggleStyle(.button)
            .help("Make the next pinch a right click")

            Toggle(isOn: $showKeyboard) {
                Label("Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)

            Toggle(isOn: $showStats) {
                Label("Stats", systemImage: "chart.bar.xaxis")
            }
            .toggleStyle(.button)

            if showKeyboard {
                KeyboardField(input: session.input)
            }
        }
        .labelStyle(.iconOnly)
        .padding(12)
        .glassBackgroundEffect()
    }
}

/// Twilight's HUD: frame rate, bitrate and latency.
private struct StatsHUD: View {
    let stats: StreamStats
    let poor: Bool
    let hostHdr: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(stats.width)×\(stats.height) · \(stats.codec)")
            Text("Colour: \(stats.colorDescription.isEmpty ? "–" : stats.colorDescription) · Host HDR \(hostHdr ? "on" : "off")")
            Text(String(format: "%.0f FPS · %.1f Mbps", stats.receivedFps, stats.bitrateMbps))
            Text("Network \(stats.rttMs) ms ± \(stats.rttVarianceMs) · Host \(String(format: "%.1f", stats.hostLatencyMs)) ms")
            Text("Dropped frames: \(stats.droppedFrames) · Client \(String(format: "%.2f", stats.frameProcessingMs)) ms/frame")
            if poor {
                Text("Poor connection").foregroundStyle(.yellow)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .padding(14)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

/// A text field that forwards typing to the host as it happens.
private struct KeyboardField: View {
    let input: InputManager
    // A sentinel character lets us notice Backspace on an otherwise empty field
    @State private var text = " "
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Type to send", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .frame(width: 220)
            .onAppear { focused = true }
            .onSubmit {
                tap(0x28) // Return
                focused = true
            }
            .onChange(of: text) { _, newValue in
                if newValue.isEmpty {
                    tap(0x2A) // Backspace
                } else if newValue.count > 1 {
                    input.sendText(String(newValue.dropFirst()))
                }
                if newValue != " " { text = " " }
            }
    }

    private func tap(_ hidUsage: Int) {
        input.sendKey(hidUsage: hidUsage, pressed: true)
        input.sendKey(hidUsage: hidUsage, pressed: false)
    }
}

/// Per-gesture state for trackpad mode. A class so updates don't re-render the view.
final class TrackpadState {
    static let tapSlop: CGFloat = 12
    static let holdDelay: TimeInterval = 0.45

    var start = CGPoint.zero
    var last = CGPoint.zero
    var startTime: CFTimeInterval = 0
    var travelled: CGFloat = 0
    var dragging = false
    var button: Int32 = 1
    var holdTimer: Timer?
    var remainder = CGPoint.zero
    var lastHover: CGPoint?
    var sentX = 0
    var sentY = 0
}

enum PointerEvent {
    case hover(CGPoint, CGSize)
    case down(CGPoint, CGSize)
    case moved(CGPoint, CGSize)
    case up(CGPoint, CGSize)
}

/// Hosts the AVSampleBufferDisplayLayer that VideoToolbox renders into, and turns
/// look-and-pinch (and trackpad/mouse) input on it into pointer events.
///
/// Input is handled in UIKit rather than with a SwiftUI gesture: UIKit reliably receives
/// visionOS's indirect pinch as touches on the view under the user's gaze.
struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var bottomMarginFraction: CGFloat = 0
    /// The stream's width / height, used to give the window the stream's shape.
    var streamAspect: CGFloat = 16.0 / 9.0
    var onPointer: (PointerEvent) -> Void

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = false
        view.hostedLayer = layer
        view.bottomMarginFraction = bottomMarginFraction
        view.streamAspect = streamAspect
        view.onPointer = onPointer
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: view, action: #selector(LayerHostView.hover(_:))))
        // By default visionOS turns game controller input into pinches and scrolling for whatever
        // you're looking at, so the thumbsticks never reach the Game Controller framework. This
        // hands the whole controller to the app while the stream is in view.
        let controllerInteraction = GCEventInteraction()
        controllerInteraction.handledEventTypes = .gamepad
        view.addInteraction(controllerInteraction)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.hostedLayer = layer
        uiView.bottomMarginFraction = bottomMarginFraction
        uiView.streamAspect = streamAspect
        uiView.onPointer = onPointer
        uiView.applyWindowShape()
    }

    final class LayerHostView: UIView {
        var onPointer: ((PointerEvent) -> Void)?
        var bottomMarginFraction: CGFloat = 0 {
            didSet { if oldValue != bottomMarginFraction { setNeedsLayout() } }
        }
        var streamAspect: CGFloat = 16.0 / 9.0
        private weak var activeTouch: UITouch?
        private var appliedShape: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            appliedShape = 0
            applyWindowShape()
        }

        /// Sizes the window to the stream's shape plus the bottom margin, and locks its proportions
        /// so resizing never adds bars. (The window otherwise takes the library window's proportions
        /// when it replaces it.)
        func applyWindowShape() {
            let shape = streamAspect / (1 + bottomMarginFraction)
            guard shape > 0, shape != appliedShape, let window, let scene = window.windowScene else { return }
            appliedShape = shape
            let width = max(window.bounds.width, 1920)
            let preferences = UIWindowScene.GeometryPreferences.Vision(
                size: CGSize(width: width, height: (width / shape).rounded()),
                minimumSize: nil, maximumSize: nil, resizingRestrictions: .uniform)
            scene.requestGeometryUpdate(preferences) { error in
                TwilightLog.error("Stream window resize was refused: \(error.localizedDescription)")
            }
        }

        /// The part of the view showing video; the rest is the bottom margin. Pointer events are
        /// reported against this size, so points in the margin clamp to the bottom row.
        private var videoSize: CGSize {
            CGSize(width: bounds.width, height: bounds.height / (1 + bottomMarginFraction))
        }

        var hostedLayer: CALayer? {
            didSet {
                guard oldValue !== hostedLayer else { return }
                oldValue?.removeFromSuperlayer()
                if let hostedLayer { layer.addSublayer(hostedLayer) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = CGRect(origin: .zero, size: videoSize)
            CATransaction.commit()
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            activeTouch = touch
            onPointer?(.down(touch.location(in: self), videoSize))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            onPointer?(.moved(touch.location(in: self), videoSize))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            activeTouch = nil
            onPointer?(.up(touch.location(in: self), videoSize))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesEnded(touches, with: event)
        }

        @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onPointer?(.hover(recognizer.location(in: self), videoSize))
            default:
                break
            }
        }
    }
}
