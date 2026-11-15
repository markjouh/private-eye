import AudioToolbox
import AVFoundation
import SwiftUI

/// Limits how often the detector runs: often enough for smooth boxes, and rarely while the language
/// model is working so the two do not fight over the GPU and thermal budget.
final class DetectionPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var last = Date.distantPast

    var modelBusy: Bool {
        get { lock.lock(); defer { lock.unlock() }; return busy }
        set { lock.lock(); busy = newValue; lock.unlock() }
    }

    /// True when enough time has passed since the last detection (and records this one).
    func shouldDetect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // About 10 boxes a second normally, 4 when the phone is hot, 2 while the model is answering.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let interval = busy ? 0.5 : (hot ? 0.25 : 0.1)
        guard Date().timeIntervalSince(last) >= interval else { return false }
        last = Date()
        return true
    }
}

/// The most recent analysed frame with its detections, shared between the camera queue (which writes
/// it) and memory features (which read it while learning or looking for something).
final class LatestSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Snapshot?

    var value: Snapshot? {
        get { lock.lock(); defer { lock.unlock() }; return snapshot }
        set { lock.lock(); snapshot = newValue; lock.unlock() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading, idle, listening, thinking, speaking
        case failed(String)
    }

    @Published var phase: Phase = .loading {
        // The Taptic Engine is loud enough for the microphone to record.
        didSet { proximity.isPaused = phase == .listening }
    }
    @Published var detections: [Detection] = []
    /// Shaded segmentation masks of the drawn detections, one small image covering the frame.
    @Published var maskImage: CGImage?
    @Published var frameSize = CGSize(width: 3, height: 4)
    @Published var question = ""
    @Published var answer = ""
    @Published var detectorMs = 0.0
    @Published var llmInfo = ""
    @Published var cameraReady = false
    /// LiDAR distance to whatever is at the middle of the view, in meters.
    @Published var centerDistance: Float?
    /// Faces in view, named where they match someone the user introduced.
    @Published var faces: [RecognizedFace] = []
    /// The user's own things currently in view.
    @Published var belongingsInView: [FoundBelonging] = []

    /// One question and its spoken reply, for the memories screen.
    struct Exchange: Identifiable {
        let id = UUID()
        let date = Date()
        let question: String
        let answer: String
    }
    @Published var history: [Exchange] = []
    @Published var showingMemory = false
    /// True while the introduction covers the screen. It is shown at every launch, because the app is
    /// being presented; `-onboarding NO` and `-ask` launches skip it. Nothing is listened to, said or
    /// answered until it is over, but the model loads behind it.
    @Published private(set) var onboarding = AppModel.launchesWithOnboarding
    private static var launchesWithOnboarding: Bool {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "ask") != nil { return false }
        return defaults.object(forKey: "onboarding") == nil || defaults.bool(forKey: "onboarding")
    }
    @Published var memoryPeople: [Person] = []
    @Published var memoryBelongings: [Belonging] = []

    let camera = CameraController()
    private let vlm = VLMService()
    private let recognizer = SpeechRecognizer()
    private let speaker = Speaker()
    private var detector: ObjectDetector?
    private let pacer = DetectionPacer()
    private let proximity = ProximityHaptics()
    private var memory: MemoryEngine?
    private var latestDepth: DepthMap?
    /// The camera frame the language model is given this turn: the sharpest from the moment the press
    /// began, or a clearly sharper one that came while the button was held.
    private var turnFrame: CVPixelBuffer?
    private var turnFrameSharpness: Float = 0
    /// The newest frame when the press began, which is what the model used to be given. Kept for the
    /// debug capture, to compare against.
    private var turnFrameAtPress: CVPixelBuffer?
    private let latestSnapshot = LatestSnapshot()
    /// The analysed frame from the moment the current press began.
    private var turnSnapshot: Snapshot?
    /// The frame the text recogniser read its reply from, when it answered this turn.
    private var turnFrameRead: CVPixelBuffer?

    /// Everything the detector currently reports, including boxes too weak to draw.
    private var allDetections: [Detection] = []
    /// What the detector saw when the current turn's frame was captured.
    private var turnDetections: [Detection] = []
    private var turnCenterDistance: Float?
    private var depthInfo = "no depth"
    private var turn = 0
    private var pressStarted = Date.distantPast
    // What the debug capture saves about the current turn.
    private var turnTrigger = "press"
    private var turnPressSeconds = 0.0
    private var turnRoute = ""
    private var turnBelongings: [FoundBelonging] = []
    private var turnNotes: [String] = []
    private var turnAudio: URL?
    private var turnReleased = Date.distantPast
    private var spokeFirstWords = false
    /// A press shorter than this is a tap (quick description) rather than a spoken question.
    private static let tapDuration = 0.35
    private static let quickQuestion = "What is in front of me?"
    private var ingestTask: Task<Void, Error>?
    /// A frame replaces the one the model has when it is this many times as sharp. Frames of a view
    /// held still differ by a few percent (three of two bottles by a sink scored 234, 237 and 246);
    /// the smeared frame of the same view, from the start of a press, scored 36.
    private static let clearlySharper: Float = 1.5
    /// At most this many replacements in a turn, so that a phone that never settles cannot keep the
    /// model reading frames until the question is over.
    private static let sharperFramesPerTurn = 2
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DebugCapture.shared.start()
        UIApplication.shared.isIdleTimerDisabled = true
        Speaker.configureAudioSession()

        do {
            detector = try ObjectDetector()
        } catch {
            log("detector failed to load: \(error)")
        }
        let detector = detector
        let pacer = pacer
        let proximity = proximity
        // Off until it has been tuned on real walks; "haptics on" turns it on.
        proximity.isEnabled = false
        let memory = MemoryEngine(store: .onDevice())
        self.memory = memory
        let latestSnapshot = latestSnapshot
        // Runs on the camera's video queue.
        camera.onFrame = { @Sendable [weak self] buffer, depth in
            // Obstacle warnings run on every frame, independent of how often the detector does.
            proximity.update(depth)
            guard pacer.shouldDetect() else { return }
            var found = detector?.detect(in: buffer) ?? []
            var center: Float?
            var depthInfo = "no depth"
            if let depth {
                for i in found.indices { found[i].distance = depth.distance(in: found[i].box) }
                center = depth.distance(in: Surroundings.centerRegion)
                depthInfo = "depth \(depth.width)x\(depth.height)"
            }
            let ms = detector?.lastInferenceMs ?? 0
            let mask = detector?.lastMask
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let shown = found.filter { $0.confidence >= ObjectDetector.displayConfidence }
            let snapshot = Snapshot(frame: buffer, detections: found, depth: depth)
            latestSnapshot.value = snapshot
            // Recognition waits while the language model works; they share the same hardware.
            if !pacer.modelBusy {
                memory.watch(frame: buffer, depth: depth, detections: found) { faces in
                    DispatchQueue.main.async { self?.noticed(faces: faces) }
                }
                memory.noticeBelongings(in: snapshot) { found in
                    DispatchQueue.main.async { self?.noticed(belongings: found) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.allDetections = found
                self.latestDepth = depth
                self.centerDistance = center
                self.depthInfo = depthInfo
                self.detections = shown
                self.maskImage = mask
                self.detectorMs = ms
                if self.frameSize != size { self.frameSize = size }
                if !self.cameraReady { self.cameraReady = true }
            }
        }
        camera.onConfigured = { summary in print("[eyes] \(summary)") }
        camera.start()

        recognizer.onPartial = { [weak self] text in
            guard let self, text != self.question else { return }
            self.question = text
            self.turnNotes.append(String(format: "%.2fs heard so far: %@", Date().timeIntervalSince(self.pressStarted), text))
        }
        speaker.onFinished = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
        }

        Task {
            if await SpeechRecognizer.requestPermissions() {
                do { try recognizer.prepare() } catch { log("microphone not started: \(error)") }
            }
            do {
                let begin = Date()
                try await vlm.load()
                log(String(format: "LFM3-VL loaded in %.1f s", Date().timeIntervalSince(begin)))
                phase = .idle
                // Someone who cannot see the button change needs to hear that the app is ready;
                // VoiceOver users get this from the status announcement instead.
                if !onboarding, !UIAccessibility.isVoiceOverRunning { speaker.say("Ready.") }
                listenForIntents()
                await runLaunchQuestionIfAny()
            } catch {
                phase = .failed("\(error)")
                log("model load failed: \(error)")
            }
        }
    }

    /// Ends the introduction and, if the model has loaded meanwhile, says so.
    func finishOnboarding() {
        guard onboarding else { return }
        onboarding = false
        VoiceSettings.shared.stopSample()
        if phase == .idle, !UIAccessibility.isVoiceOverRunning { speaker.say("Ready.") }
    }

    // MARK: Push to talk

    func pressDown() {
        guard !onboarding, phase != .loading, phase != .listening else { return }
        if case .failed = phase { return }
        pressStarted = Date()
        beginTurn()
        turnTrigger = "press"
        turnAudio = DebugCapture.shared.newRecordingURL()
        do {
            try recognizer.start(recordingTo: turnAudio)
        } catch {
            // Still a valid press: without the microphone it becomes a quick description.
            log("could not start listening: \(error)")
        }
        phase = .listening
    }

    func pressUp() {
        guard phase == .listening else { return }
        phase = .thinking
        let turn = turn
        turnReleased = Date()
        turnPressSeconds = min(turnReleased.timeIntervalSince(pressStarted), 600)
        let tapped = turnPressSeconds < Self.tapDuration
        log(String(format: "press released after %.2f s (%@); model's frame %.0f, frames now %@", turnPressSeconds, tapped ? "tap" : "hold",
                   turnFrameSharpness, camera.recentSharpness))
        Task {
            var heard = ""
            if tapped {
                recognizer.cancel()
            } else {
                heard = await recognizer.finish()
                guard turn == self.turn else { return }
                log(String(format: "transcript settled %.0f ms after release%@", Date().timeIntervalSince(turnReleased) * 1000,
                           recognizer.keptListening ? " (kept listening: still speaking at release)" : ""))
            }
            // A tap, or a hold with nothing intelligible, gets a quick description of the view.
            await respond(to: heard.isEmpty ? Self.quickQuestion : heard, dictated: !heard.isEmpty, turn: turn)
        }
    }

    /// A tap-equivalent trigger for callers with no press and release, such as the Action button.
    func describeNow() {
        guard phase != .listening, phase != .loading else { return }
        Task {
            // Coming back from the background, the newest frame is from before the app was hidden;
            // wait for the camera to deliver a current one rather than describe an old scene.
            let asked = Date()
            for _ in 0..<40 where (camera.latestFrameDate ?? .distantPast) < asked {
                try? await Task.sleep(for: .milliseconds(50))
            }
            pressDown()
            turnTrigger = "intent"
            pressUp()
        }
    }

    /// Acts on requests from the Action button, Shortcuts and Siri (see EyesIntents.swift). Called once
    /// the model has loaded; a request made before that is waiting in the stream.
    private func listenForIntents() {
        Task {
            for await request in IntentTrigger.requests {
                // The Action button on a cold launch should get its answer, not an introduction.
                finishOnboarding()
                switch request {
                case .describe:
                    describeNow()
                case .toggleListening:
                    if phase == .listening {
                        pressUp()
                    } else {
                        // There is no finger on a button to confirm it started, so play the system's
                        // "begin recording" tone.
                        AudioServicesPlaySystemSound(1113)
                        pressDown()
                        // A toggle has no release to time; make sure it is not mistaken for a tap.
                        pressStarted = .distantPast
                    }
                }
            }
        }
    }

    /// Snapshots the camera and starts feeding the frame to the model, so it is (usually) already
    /// processed by the time the question has been spoken.
    private func beginTurn() {
        turn += 1
        speaker.stop()
        vlm.cancel()
        question = ""
        answer = ""
        llmInfo = ""
        pacer.modelBusy = true
        turnDetections = allDetections
        turnCenterDistance = centerDistance
        turnSnapshot = latestSnapshot.value
        turnFrameRead = nil
        turnRoute = ""
        turnBelongings = []
        turnNotes = []
        turnPressSeconds = 0
        turnAudio = nil
        spokeFirstWords = false
        // The newest frame is often smeared: the phone is still coming to rest as the button goes
        // down. Of 245 press frames saved from the phone about 15 were, and the model's answers about
        // them were wrong ("Blurry photo.", the wrong one of two bottles). So the model gets the
        // sharpest of the last few frames, and a sharper one still if it comes while the button is held.
        let newest = camera.latestFrame
        let sharpest = camera.sharpestRecentFrame()
        turnFrameAtPress = DebugCapture.shared.isEnabled ? newest : nil
        show(sharpest)
        if let sharpest {
            log(String(format: "frame: sharpness %.0f, %.0f ms old%@, of %@%@", sharpest.sharpness,
                       Date().timeIntervalSince(sharpest.date) * 1000, sharpest.buffer === newest ? "" : " (not the newest)",
                       camera.recentSharpness, camera.droppedFrames > 0 ? "; camera out of buffers \(camera.droppedFrames) times" : ""))
        }
        watchForSharperFrame(turn: turn)
    }

    /// Gives the language model `frame` to look at for this turn, in place of any it had.
    private func show(_ frame: ScoredFrame?) {
        turnFrame = frame?.buffer
        turnFrameSharpness = frame?.sharpness ?? 0
        let vlm = vlm
        let image = frame.flatMap { camera.cgImage(of: $0.buffer) }
        ingestTask = Task {
            guard let image else { throw LLMError("no camera frame yet") }
            try await vlm.ingest(image)
        }
    }

    /// While the button is held the phone steadies, or the thing asked about is brought into view. A
    /// frame clearly sharper than the one the model has replaces it. Reading a frame takes the model
    /// two thirds of a second, which is usually over before the question is.
    private func watchForSharperFrame(turn: Int) {
        Task {
            var replaced = 0
            while replaced < Self.sharperFramesPerTurn {
                try? await Task.sleep(for: .milliseconds(100))
                guard turn == self.turn, phase == .listening else { return }
                guard let frame = camera.sharpestRecentFrame(), frame.sharpness > Self.clearlySharper * turnFrameSharpness else { continue }
                log(String(format: "sharper frame: %.0f, was %.0f", frame.sharpness, turnFrameSharpness))
                replaced += 1
                show(frame)
            }
        }
    }

    /// `dictated` is false for a tap, which asks the standing question without anyone having said it.
    private func respond(to heard: String, dictated: Bool, turn: Int) async {
        defer { if turn == self.turn { pacer.modelBusy = false } }
        question = heard
        log("Q: \(heard)")
        if let reply = await memoryReply(to: heard) {
            guard turn == self.turn else { return }
            say(reply, source: "memory")
            return
        }
        if Surroundings.isSafetyQuestion(heard) {
            // Go/no-go traffic questions are answered from the detector and LiDAR, never by the model.
            say(Surroundings.safetyReply(for: allDetections), source: "detector")
            return
        }
        // "Read this" and "what is the number?": exact text comes from the text recogniser, which
        // gets digits and fine print right where the model does not. It reads what the camera sees
        // now, as the question ends and the thing is being held up; at the start of the press it is
        // often still blurred or half out of view (two of seven questions on the phone failed that
        // way). That earlier frame is the second try. With nothing found, the model has a go.
        if let request = TextReader.request(in: heard) {
            for frame in [camera.latestFrame, turnFrame].compactMap({ $0 }) {
                let text = await Self.readText(in: frame, request)
                guard turn == self.turn else { return }
                if let text {
                    turnFrameRead = frame
                    say(text, source: "text")
                    return
                }
            }
        }
        // "What is this?" while pointing at one of their things: say so rather than describe it.
        if Commands.asksWhatThisIs(heard) {
            let mine = await ownThings(in: turnSnapshot)
            guard turn == self.turn else { return }
            turnBelongings = mine
            if let reply = MemoryReplies.thisIs(mine) {
                say(reply, source: "memory")
                return
            }
        }
        if heard == Self.quickQuestion || SceneDescription.isOverviewQuestion(heard) {
            // Only a tap leaves it open what is being asked about. Someone who says "what do you
            // see?" or "describe the room" has asked about the scene, and gets the scene.
            await describeSurroundings(turn: turn, mayBeOneThing: !dictated)
        } else {
            await answerWithModel(heard, turn: turn)
        }
    }

    /// What a tap asks for, and a spoken "what's in front of me?". On a tap (`mayBeOneThing`), one
    /// thing held up to the camera is named and its label read, and which case it is, is the model's
    /// call. Anything else is described as a scene, after what only the app can know: who is there,
    /// and which things in view are the user's own.
    private func describeSurroundings(turn: Int, mayBeOneThing: Bool) async {
        // Who is in the frame this turn is about, looked up now, on that frame, rather than taken
        // from the last background pass, which may be a moment stale.
        if let memory, !memory.store.people.isEmpty, let shot = turnSnapshot,
           shot.detections.contains(where: { $0.label == "person" || $0.label == "face" }) {
            let present = await memory.whoIsHere(frame: shot.frame, depth: shot.depth)
            if turn == self.turn { noticed(faces: present) }
        }
        guard turn == self.turn else { return }
        // Names are said at once: the model takes most of a second, and a tap should not be met with
        // silence. The exception is something held up to the lens, which is probably what the tap is
        // about; then the names wait for the model's answer, and go unsaid if it is a close-up.
        var said = ""
        let names = SceneDescription.names(detections: turnDetections, faces: faces)
        if !names.isEmpty, !mayBeOneThing || (turnCenterDistance ?? .infinity) > Self.heldUpWithin {
            said = names
            log(String(format: "names, at once: %@ (%.0f ms after release)", names, Date().timeIntervalSince(turnReleased) * 1000))
            speaker.begin()
            answer = names + " "
            phase = .speaking
            speaker.feed(names + " ")
        }
        // With a name said, the tap is taken to be about the scene, and the model is not asked:
        // pointed straight at someone, it called them "one object" and went on to describe "Person."
        let askModel = mayBeOneThing && said.isEmpty
        async let closeUp = askModel ? isCloseUp() : false
        let mine = await ownThings(in: turnSnapshot)
        let single = await closeUp
        guard turn == self.turn else { return }
        turnBelongings = mine
        if single, let reply = MemoryReplies.thisIs(mine) {
            // A close-up of one of the user's own things: its name is the answer.
            say(reply, source: "memory")
        } else if single {
            // The scene, and whoever and whatever else is in it, is not what is being asked about.
            // (Prefacing this with one of the user's own things seen near the middle was tried: it
            // said "Your water bottle. Sleep mask." with the bottle on the desk behind the mask.)
            turnRoute = "object"
            await answerWithModel(AnswerStyle.objectQuestion, turn: turn)
        } else {
            turnRoute = "description"
            let others = SceneDescription.others(detections: turnDetections, faces: faces, belongings: mine)
            let lead = said.isEmpty ? [names, others].filter { !$0.isEmpty }.joined(separator: " ") : others
            // People the app has announced are left out of the model's description.
            let peopleSaid = !SceneDescription.known(detections: turnDetections, faces: faces).isEmpty
            await answerWithModel(Self.quickQuestion, as: peopleSaid ? .describeThings : nil, said: said, after: lead, turn: turn)
        }
    }

    /// With the middle of the view nearer than this (meters, by LiDAR), something is taken to be held
    /// up to the lens. Of 78 taps saved from the phone, the 27 close-ups of something in the hand or
    /// on the desk all measured 0.44 or less, and all but one scene with a recognised person more.
    private static let heldUpWithin: Float = 0.45

    /// The model's answer to "is this a close-up of one object?" about this turn's frame. A failure
    /// counts as no: the description that follows will report it.
    private func isCloseUp() async -> Bool {
        guard (try? await ingestTask?.value) != nil, let (single, timing) = try? await vlm.isCloseUp() else { return false }
        log(String(format: "close-up of one thing: %@ (%@; done %.0f ms after release)", single ? "yes" : "no", timing,
                   Date().timeIntervalSince(turnReleased) * 1000))
        return single
    }

    /// Asks the language model and speaks its reply as it is generated. The model gets the frame and
    /// the question, nothing else. `lead` is something the app already knows, spoken first; `said`
    /// is what has already been spoken this turn, ahead of that.
    private func answerWithModel(_ heard: String, as kind: AnswerStyle.Kind? = nil, said: String = "", after lead: String = "", turn: Int) async {
        let thermal = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
        log("\(depthInfo); thermal \(thermal)\(ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power mode" : "")")
        // Everything spoken before the model's own words.
        let preface = [said, lead].filter { !$0.isEmpty }.joined(separator: " ")
        do {
            if said.isEmpty { speaker.begin() }
            if !lead.isEmpty {
                log(String(format: "known without the model: %@ (%.0f ms after release)", lead, Date().timeIntervalSince(turnReleased) * 1000))
                answer = preface + " "
                phase = .speaking
                speaker.feed(lead + " ")
            }
            try await ingestTask?.value
            guard turn == self.turn else { return }
            // Generated text crosses from the model queue to the main actor through a stream so the
            // pieces stay in order and are all delivered before the reply is closed.
            let (pieces, feed) = AsyncStream<String>.makeStream()
            let pump = Task { @MainActor in
                for await text in pieces where turn == self.turn {
                    if !self.spokeFirstWords {
                        self.spokeFirstWords = true
                        self.log(String(format: "first words %.0f ms after release", Date().timeIntervalSince(self.turnReleased) * 1000))
                    }
                    self.answer += text
                    self.phase = .speaking
                    self.speaker.feed(text)
                }
            }
            var reply: String
            let stats: LLMStats
            do {
                (reply, stats) = try await vlm.answer(heard, as: kind) { feed.yield($0) }
            } catch {
                feed.finish()
                throw error
            }
            feed.finish()
            await pump.value
            guard turn == self.turn else { return }
            llmInfo = String(format: "image %d tok %.0f ms · first token %.0f ms · %.0f tok/s",
                             stats.imageTokens, stats.imageMs, stats.ttftMs, stats.tokensPerSecond)
            log("A: \(reply)\n   \(llmInfo)")
            if !preface.isEmpty { reply = "\(preface) \(reply)" }
            answer = reply
            record(reply)
            phase = .speaking
            speaker.end()
        } catch {
            guard turn == self.turn else { return }
            log("turn failed: \(error)")
            turnRoute = "error"
            let reply = preface.isEmpty ? "Something went wrong." : preface
            answer = reply
            record(reply)
            phase = .speaking
            // Whatever was already said stands; only a turn with nothing said reports the failure aloud.
            if preface.isEmpty { speaker.say(reply) } else { speaker.end() }
        }
    }

    /// The text in a frame as it should be read aloud, or nil when none was found.
    nonisolated private static func readText(in frame: CVPixelBuffer, _ request: TextReader.Request) async -> String? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: TextReader.spoken(TextReader.lines(in: frame), request))
            }
        }
    }

    /// Speaks a reply that was built by code rather than generated by the language model.
    private func say(_ reply: String, source: String) {
        vlm.cancel()
        answer = reply
        llmInfo = "answered from \(source)"
        log("A (\(source)): \(reply)")
        turnRoute = source
        record(reply)
        phase = .speaking
        speaker.say(reply)
    }

    // MARK: Memory

    /// Carries out memory commands ("This is Sarah", "Who is this?", "Forget Tom") and answers questions
    /// about where known people are. Returns nil when `heard` is an ordinary question.
    private func memoryReply(to heard: String) async -> String? {
        guard let memory else { return nil }
        let store = memory.store
        let command = Commands.parse(heard)
        if let command { log("command: \(command)") }
        switch command {
        case .rememberPerson(let name):
            releaseModel()
            let latest = latestSnapshot
            let outcome = await memory.remember(person: name, first: turnSnapshot) { latest.value }
            return MemoryReplies.remembered(person: name, outcome)
        case .rememberBelonging(let name):
            releaseModel()
            let latest = latestSnapshot
            let outcome = await memory.remember(belonging: name, first: turnSnapshot) { latest.value }
            return MemoryReplies.remembered(belonging: name, outcome)
        case .findBelonging(let name):
            // "Where is my …" about something never taught is an ordinary question for the model.
            guard let belonging = store.belonging(named: name) else { return nil }
            releaseModel()
            let found = await memory.find(belonging, in: [latestSnapshot.value, turnSnapshot].compactMap { $0 })
            // Read it again: a sighting recorded a moment ago belongs in the answer.
            return MemoryReplies.whereIs(store.belonging(named: name) ?? belonging, found: found)
        case .whoIsThis:
            faces = await facesInView()
            return MemoryReplies.who(faces)
        case .forget(let name):
            return MemoryReplies.forgot(name, removed: store.forget(name))
        case .forgetEverything:
            store.forgetEverything()
            faces = []
            return "Memory cleared."
        case .listMemory:
            return MemoryReplies.list(people: store.people.map(\.name), belongings: store.belongings.map(\.name))
        case .obstacleWarnings(let on):
            proximity.isEnabled = on
            return on ? "Obstacle warnings on." : "Obstacle warnings off."
        case .whoseIsThis:
            releaseModel()
            var found = await ownThings(in: latestSnapshot.value)
            if found.isEmpty { found = await ownThings(in: turnSnapshot) }
            return MemoryReplies.whose(found)
        case .showMemory:
            refreshMemory()
            showingMemory = true
            return "Memories."
        case .cancelled:
            return "Okay, nothing changed."
        case .tellTime:
            return Date().formatted(date: .omitted, time: .shortened) + "."
        case .tellDate:
            return Date().formatted(.dateTime.weekday(.wide).month(.wide).day()) + "."
        case .howFar:
            return Surroundings.howFar(turnCenterDistance)
        case nil:
            guard let name = Commands.personAsked(in: heard, among: store.people.map(\.name)) else { return nil }
            faces = await facesInView()
            return MemoryReplies.whereIs(name, among: faces)
        }
    }

    /// The user's belongings recognised in a frame (nothing to do, and no delay, when they have none).
    private func ownThings(in snapshot: Snapshot?) async -> [FoundBelonging] {
        guard let memory, let snapshot, !memory.store.belongings.isEmpty else { return [] }
        return await memory.belongings(in: snapshot)
    }

    /// Publishes who is in view, logging only when the set of people changes.
    private func noticed(faces now: [RecognizedFace]) {
        func summary(_ list: [RecognizedFace]) -> [String] { list.map { ($0.name ?? "unknown") + ($0.tentative ? "?" : "") }.sorted() }
        if summary(now) != summary(faces) {
            let detail = now.map { String(format: "%@ %.2f", $0.name ?? "unknown", $0.score ?? 0) }.joined(separator: ", ")
            print("[eyes] faces in view: \(detail.isEmpty ? "none" : detail)")
        }
        faces = now
    }

    private func noticed(belongings now: [FoundBelonging]) {
        func summary(_ list: [FoundBelonging]) -> [String] { list.map { $0.name + ($0.tentative ? "?" : "") }.sorted() }
        if summary(now) != summary(belongingsInView) {
            let detail = now.map { String(format: "%@ %.2f", $0.name, $0.score) }.joined(separator: ", ")
            print("[eyes] own things in view: \(detail.isEmpty ? "none" : detail)")
        }
        belongingsInView = now
    }

    // MARK: Memories screen

    func refreshMemory() {
        memoryPeople = memory?.store.people ?? []
        memoryBelongings = memory?.store.belongings ?? []
    }

    func forget(_ name: String) {
        _ = memory?.store.forget(name)
        refreshMemory()
    }

    func forgetEverything() {
        memory?.store.forgetEverything()
        faces = []
        belongingsInView = []
        refreshMemory()
    }

    private func record(_ answer: String) {
        guard !question.isEmpty, !answer.isEmpty else { return }
        history.insert(Exchange(question: question, answer: answer), at: 0)
        if history.count > 30 { history.removeLast() }
        saveForDebugging(reply: answer)
    }

    /// Hands the finished turn to the debug capture: the frame it was about and everything measured.
    private func saveForDebugging(reply: String) {
        guard DebugCapture.shared.isEnabled else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let record = TurnRecord(
            id: stamp.string(from: Date()), date: Date(), trigger: turnTrigger, pressSeconds: turnPressSeconds,
            heard: question, route: turnRoute.isEmpty ? "model" : turnRoute, reply: reply,
            model: llmInfo, thermal: ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)],
            centerDistance: turnCenterDistance,
            detections: turnDetections.map { .init($0.label, $0.box, confidence: $0.confidence, distance: $0.distance) },
            faces: faces.map { face in
                .init(face.name ?? "unknown", face.box, confidence: face.score, distance: face.distance, note: face.tentative ? "tentative" : nil)
            },
            belongings: turnBelongings.map { .init($0.name, $0.box, confidence: $0.score, distance: $0.distance, note: $0.tentative ? "tentative" : nil) },
            knownPeople: memory?.store.people.map(\.name) ?? [], knownThings: memory?.store.belongings.map(\.name) ?? [],
            notes: turnNotes)
        // The frame the answer came from: the one the text recogniser read, the one the model was
        // given, or for a reply built from memory or the detector, the one their outlines are on.
        let analysed = ["memory", "detector"].contains(record.route) ? turnSnapshot?.frame : nil
        let frame = turnFrameRead ?? analysed ?? turnFrame ?? turnSnapshot?.frame
        // And the newest frame at the press, when the model was given another.
        let atPress = frame === turnFrame && turnFrameAtPress !== frame ? turnFrameAtPress : nil
        DebugCapture.shared.save(record, frame: frame, atPress: atPress, depth: turnSnapshot?.depth, audio: turnAudio)
        turnFrameAtPress = nil
        turnAudio = nil
    }

    /// Memory commands do not need the language model: stop it reading the frame, and let the detector
    /// return to full speed so the frames memory looks at are current.
    private func releaseModel() {
        vlm.cancel()
        pacer.modelBusy = false
    }

    /// Recognises the people in view right now, falling back to the frame from when the press began
    /// (the user may have lowered the phone while speaking).
    private func facesInView() async -> [RecognizedFace] {
        guard let memory else { return [] }
        if let frame = camera.latestFrame {
            let now = await memory.whoIsHere(frame: frame, depth: latestDepth)
            if !now.isEmpty { return now }
        }
        if let frame = turnFrame { return await memory.whoIsHere(frame: frame, depth: nil) }
        return []
    }

    // MARK: Debugging

    /// `-ask "question"` on the command line runs one turn without speech input once a frame is available.
    private func runLaunchQuestionIfAny() async {
        guard let text = UserDefaults.standard.string(forKey: "ask"), !text.isEmpty else { return }
        for _ in 0..<50 where camera.latestFrame == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        pressStarted = Date()
        turnReleased = Date()
        beginTurn()
        turnTrigger = "launch"
        phase = .thinking
        await respond(to: text, dictated: false, turn: turn)
    }

    private func log(_ message: String) {
        print("[eyes] \(message)")
        turnNotes.append(String(format: "%.2fs %@", Date().timeIntervalSince(pressStarted), message))
    }
}
