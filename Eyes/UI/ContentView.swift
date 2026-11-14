import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var pressed = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mainScreen
                // Under the introduction it is there to be seen arriving, not to be used.
                .accessibilityHidden(model.onboarding)
            if model.onboarding {
                OnboardingView(settings: .shared) { model.finishOnboarding() }
                    // Leaves by zooming on into the camera view.
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.12)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.25 : 0.45), value: model.onboarding)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showingMemory) { MemoryView(model: model) }
        // Camera Control and the volume buttons act like a finger on the screen: hold to ask, click
        // for a description.
        .hardwareTrigger(
            onDown: {
                pressed = true
                model.pressDown()
            },
            onUp: {
                pressed = false
                model.pressUp()
            })
        .statusBarHidden()
        .defersSystemGestures(on: .all)
        .sensoryFeedback(.impact, trigger: pressed)
        // VoiceOver's two-finger double-tap, wherever its focus is on this screen.
        .accessibilityAction(.magicTap, toggleListening)
        // What a sighted user reads off the button, posted for assistive technology. Nothing is said
        // on entering `listening`: the microphone is open and would record it.
        .onChange(of: model.phase) { old, new in
            if case .failed = new {
                announce("Model failed to load")
            } else if old == .loading, new == .idle, !model.onboarding {
                announce("Ready")
            }
        }
        .onChange(of: model.onboarding) { _, showing in
            if !showing, model.phase == .idle { announce("Ready") }
        }
        .task(id: model.phase == .thinking) {
            // Only worth saying when the answer is slow in coming.
            guard model.phase == .thinking, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            announce("Thinking")
        }
    }

    /// The app itself: the camera, the press surface and what is drawn over them.
    private var mainScreen: some View {
        ZStack {
            cameraView

            // The whole screen is the button: tap for a description, hold to ask.
            PressSurface(
                onDown: {
                    pressed = true
                    model.pressDown()
                },
                onUp: {
                    pressed = false
                    model.pressUp()
                })
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // Drawn above the press surface but transparent to touches, which fall through to it. Two
            // things here take touches of their own: the memories button, and captions too long to fit.
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    statusBar
                    memoriesButton
                }
                // Secondary to the captions: these stop growing at about twice their size.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                Spacer(minLength: 0)
                captions
                talkButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    /// The camera picture and everything drawn on it, as one element for assistive technology. A
    /// picture cannot be read out, so its value is the measured description a tap would speak.
    private var cameraView: some View {
        ZStack {
            CameraPreview(session: model.camera.session, ready: model.cameraReady)
            DetectionOverlay(detections: model.detections, mask: model.maskImage, frameSize: model.frameSize)
            FaceOverlay(faces: model.faces, frameSize: model.frameSize)
            BelongingOverlay(found: model.belongingsInView, frameSize: model.frameSize)
        }
        .ignoresSafeArea()
        // Tags grow to about twice their size; any larger and they bury the picture they label.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera view")
        .accessibilityValue(sceneInWords)
        .accessibilityAddTraits(.isImage)
        .accessibilitySortPriority(2)
    }

    private var sceneInWords: String {
        // What the app knows without asking the model; the description itself is what a tap is for.
        let seen = SceneDescription.known(detections: model.detections, faces: model.faces, belongings: model.belongingsInView)
        return seen.isEmpty ? "No one in view" : seen
    }

    /// Opens the screen listing remembered people and things.
    private var memoriesButton: some View {
        Button {
            model.refreshMemory()
            model.showingMemory = true
        } label: {
            Image(systemName: "tray.full.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .frame(minWidth: 52, minHeight: 52)
                .background(.black.opacity(backing(0.7)), in: Circle())
        }
        .accessibilityLabel("Memories")
        .accessibilitySortPriority(3)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%@ · detector %.0f ms · %d objects", statusText, model.detectorMs, model.detections.count)
                 + (model.centerDistance.map { " · ahead \(Surroundings.tag($0))" } ?? ""))
            if !model.llmInfo.isEmpty { Text(model.llmInfo) }
        }
        .font(.caption.weight(.medium).monospaced())
        .foregroundStyle(.white)
        // Wraps to as many lines as it needs, however much room the captions ask for.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(backing(0.55)), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(statusInWords)
        .accessibilitySortPriority(1)
    }

    /// The status line as it should be read out: the same facts, with the units in words.
    private var statusInWords: String {
        var parts = [statusText, String(format: "detector %.0f milliseconds", model.detectorMs), "\(model.detections.count) objects"]
        if let ahead = model.centerDistance { parts.append("\(Surroundings.spoken(ahead)) ahead") }
        if !model.llmInfo.isEmpty { parts.append(model.llmInfo) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var captions: some View {
        if !model.question.isEmpty || !model.answer.isEmpty {
            // A reply too long for the room left scrolls, with its newest words in view. Only then do
            // the captions take touches: a drag there scrolls, a tap still describes, and a hold has
            // to start anywhere else.
            ViewThatFits(in: .vertical) {
                captionBox(captionText)
                    .allowsHitTesting(false)
                captionBox(ScrollView { captionText }.defaultScrollAnchor(.bottom))
                    .onTapGesture { model.describeNow() }
            }
            // Offered all the height the status bar and button leave, before the spacer gets any.
            .layoutPriority(1)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(4)
        }
    }

    private var captionText: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.question.isEmpty {
                Text(model.question)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.75))
                    .accessibilityLabel("You asked: \(model.question)")
            }
            if !model.answer.isEmpty {
                Text(model.answer)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Answer: \(model.answer)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captionBox(_ content: some View) -> some View {
        content
            .padding(14)
            .background(.black.opacity(backing(0.65)), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The picture of the button. Touches pass through it to the press surface; assistive technology
    /// acts on it instead, since it cannot hold a finger down: activating it describes (or, while
    /// listening, stops and answers), and asking a question is an action of its own.
    private var talkButton: some View {
        VStack(spacing: 6) {
            // The icon repeats the title; at the largest text sizes the room goes to the words.
            if !typeSize.isAccessibilitySize {
                Image(systemName: buttonIcon)
                    .font(.system(size: 40, weight: .semibold))
            }
            VStack(spacing: 2) {
                Text(buttonTitle)
                    .font(.title3.bold())
                // Keeps its place when hidden, so the button does not change height with its state.
                Text("Tap anywhere · hold to ask")
                    .font(.subheadline.weight(.medium))
                    .opacity(describes ? 1 : 0)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(buttonColor, in: RoundedRectangle(cornerRadius: 28))
        // As tall as its words need, however much room the captions ask for.
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        // Twice its size is as far as the button grows; the rest of the screen is for the captions.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        // The visible title, so that what Voice Control hears matches what is on screen.
        .accessibilityLabel(buttonTitle.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
        .accessibilityHint(buttonHint)
        // Starting to listen records audio: VoiceOver should not talk into it.
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityAction {
            if model.phase == .listening { model.pressUp() } else { model.describeNow() }
        }
        .accessibilityActions {
            if ready, model.phase != .listening { Button("Ask a question", action: toggleListening) }
        }
        .accessibilitySortPriority(5)
        .disabled(!ready)
    }

    /// Starts listening without a finger held down, or stops and answers: the same request the "Ask a
    /// Question" shortcut sends, which also plays the tone that says recording began.
    private func toggleListening() {
        // A request sent while the model loads would be kept, and open the microphone unasked later.
        guard ready else { return }
        IntentTrigger.send(.toggleListening)
    }

    /// Posts a change of state to VoiceOver (and a braille display) without moving its focus. Queued
    /// behind whatever it is saying rather than cutting in.
    private func announce(_ status: String) {
        var text = AttributedString(status)
        text.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(text).post()
    }

    /// Opacity of the dark backing behind text over the camera picture: solid when the user has asked
    /// for less transparency or more contrast.
    private func backing(_ opacity: Double) -> Double {
        reduceTransparency || contrast == .increased ? 1 : opacity
    }

    /// False while a press would do nothing: the model is still loading, or never will.
    private var ready: Bool {
        switch model.phase {
        case .loading, .failed: false
        default: true
        }
    }

    /// True while the button shows its resting title and the line saying how to use it.
    private var describes: Bool {
        model.phase == .idle || model.phase == .speaking
    }

    private var statusText: String {
        switch model.phase {
        case .loading: "loading model"
        case .idle: "ready"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .failed(let message): "error: \(message)"
        }
    }

    private var buttonTitle: String {
        switch model.phase {
        case .loading: "Loading…"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .failed: "Model failed to load"
        case .idle, .speaking: "Describe"
        }
    }

    private var buttonHint: String {
        switch model.phase {
        case .loading, .failed: ""
        case .listening: "Stops listening and answers."
        case .idle, .thinking, .speaking:
            "Describes what is ahead. To ask a question, double-tap and hold while you speak, or use Magic Tap."
        }
    }

    private var buttonIcon: String {
        switch model.phase {
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .loading: "hourglass"
        case .failed: "exclamationmark.triangle"
        case .idle, .speaking: "mic.fill"
        }
    }

    /// Fills dark enough for the white text on them to pass 4.5:1, which the system blue, red and
    /// orange do not.
    private var buttonColor: Color {
        switch model.phase {
        case .listening: Color(red: 0.78, green: 0.12, blue: 0.12)
        case .thinking: Color(red: 0.66, green: 0.33, blue: 0)
        case .loading, .failed: Color(white: 0.37)
        case .idle, .speaking: Color(red: 0.04, green: 0.38, blue: 0.82)
        }
    }
}
