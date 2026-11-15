import Foundation

/// How hot the phone is, as far as the video features care.
enum Heat {
    case normal
    /// Thermal state "serious": keep working, at a slower pace.
    case hot
    /// Thermal state "critical": stop asking the model anything unasked.
    case tooHot

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .critical: self = .tooHot
        case .serious: self = .hot
        default: self = .normal
        }
    }
}

/// The decisions of a search judged by the language model, with no camera or model in it so that
/// it can be replayed on a clip: when the model is asked whether the thing is in view, and when
/// its answers add up to telling the user.
///
/// A wrong "found" is worse than a late one, so one yes is not enough: the model must be sure
/// (`bar`), and sure again about a later frame.
///
/// There are two ways of pacing it. `Policy.searching` is what the app uses: the user is sweeping
/// the phone about for half a minute, so every look is at something new and the model is asked
/// again as soon as it has answered. `Policy.calibrated` is the patient kind the app began with,
/// which asks only when the view has changed and slows down on a run of noes; it is kept for
/// replaying a long, still watch.
struct WatchMonitor {
    struct Policy {
        /// How different the view must be from the frame last asked about (`SceneSignature.change`)
        /// before asking again. Measured on clips made from the phone's frames: a hand holding
        /// still moves the score by 0.3 to 0.4, at most 0.66 in two minutes; someone appearing in
        /// an eighth of the view moves it by 1.3.
        var changeNeeded: Float = 0.8
        /// Seconds from one check to the next while the view keeps changing; this caps how much of
        /// the time the model is working.
        var gap: TimeInterval = 1.5
        var hotGap: TimeInterval = 4
        /// A view that keeps changing without the answer ever nearing yes (walking with the phone,
        /// a busy room) is looked at less often: after every `patience` such checks in a row the
        /// gap doubles, up to four times its length. A spell of `quiet` seconds without a check
        /// ends it, so the first looks at something new are always prompt.
        var patience = 3
        var quiet: TimeInterval = 10
        /// False while searching: a run of noes is what a search looks like until it ends, and
        /// no reason to look less often.
        var slowsDown = true
        /// A yes is checked again on a frame taken at least this much later.
        var confirmAfter: TimeInterval = 0.5
        /// How sure the model must be (`LLMEngine.yesProbability`) for an answer to count as yes.
        /// This is a property of the model, not of the app: see `calibrated(forModel:)`.
        var bar: Float = 0.9
        /// Yeses in a row that make an alert.
        var yesNeeded = 2
        /// An answer this sure makes an alert on its own, with no second look. nil: never.
        /// Only a search uses it (`searching(forModel:)`), where the thing may be in view for
        /// a second as the phone sweeps past.
        var sure: Float?
        /// An answer between `maybe` and `bar` is neither: the model is asked again about a
        /// later frame, changed view or not, up to `retries` times. Without this a thing that had
        /// happened, in a view that then stayed still, would never be looked at again.
        var maybe: Float = 0.5
        var retries = 3

        /// The policy with the bar that suits the model file loaded (`LLMEngine.modelFile`).
        ///
        /// How confident a model sounds when it is right differs from one set of weights to the
        /// next, so the bar is measured per model: `eyes-cli check` on 1,045 checks of frames from
        /// the phone (412 where the condition does not hold, 198 where it does).
        ///
        ///     model                  bar    passes wrongly   fails wrongly
        ///     LFM3-VL-2B-QAD-Q4_0    0.9    9 (2.2%)         4 (2.0%)
        ///     eyes-ft-v1-Q4_K_M      0.6    11 (2.7%)        13 (6.6%)
        ///
        /// The fine-tuned model is the more cautious: held to 0.9 it passes 5 wrongly and fails 76
        /// of the 198 it should pass, which would leave most alerts late or never given. A model
        /// not in this table gets a bar between the two until it has been measured.
        ///
        /// A second measurement, with an answer key made by eye rather than from the detector
        /// (263 frames from the phone, each marked for a person, a chair, a laptop, a bottle and
        /// a can; 611 cases plainly absent, 388 plainly there, the partly visible left out):
        ///
        ///     model                  bar    passes wrongly   fails wrongly
        ///     LFM3-VL-2B-QAD-Q4_0    0.9    16 (2.6%)        11 (2.8%)
        ///     eyes-ft-v2-Q4_K_M      0.7    3 (0.5%)         15 (3.9%)
        ///     (the object detector, at 0.5: 21 (3.4%) and 121 (31.2%), 67 of the 69 cans among them)
        static func calibrated(forModel file: String) -> Policy {
            var policy = Policy()
            if file.hasPrefix("LFM3-VL-2B") {
                policy.bar = 0.9
            } else if file.hasPrefix("eyes-ft-v1") {
                policy.bar = 0.6
            } else {
                // Measured for eyes-ft-v2; a guess for anything else.
                policy.bar = 0.7
            }
            // An answer a little short of the bar is worth asking about again.
            policy.maybe = min(0.5, policy.bar - 0.2)
            return policy
        }

        /// The policy for an active search: the same bar, asked about every view rather than
        /// only a changed one, back to back. A look takes about 0.8 s on the phone, so `gap`
        /// (counted from the start of one look to the start of the next) leaves the detector and
        /// face memory a breath in between; hot, the looks are two seconds apart.
        ///
        /// One very sure answer is enough (`sure`); a merely sure one still needs a second look.
        /// Simulated half-minute searches made from those 263 frames (each view one frame held
        /// for 1 to 2.5 s, a look taking 0.8 s), eyes-ft-v2:
        ///
        ///     rule                       false "found",      found, thing in view for
        ///                                nothing there       1 s     1.5 s    2 s
        ///     one yes at 0.7             6.4% of searches    94%     93%      93%    (1.3 s after it appears)
        ///     two yeses running          4.8%                19%     65%      94%    (2.1 s)
        ///     0.95 once, or two at 0.7   4.9%                80%     89%      94%    (1.4 s)
        ///
        /// Asking twice buys little, because a wrong yes belongs to the scene and the second
        /// look at it says yes again; what it costs is every thing the phone sweeps past in
        /// under two seconds. The stock model gives a false "found" in 21 to 27% of searches
        /// whichever rule is used.
        static func searching(forModel file: String) -> Policy {
            var policy = calibrated(forModel: file)
            policy.changeNeeded = 0
            policy.gap = 1.0
            policy.hotGap = 2.0
            policy.slowsDown = false
            policy.confirmAfter = 0.3
            if file.hasPrefix("LFM3-VL-2B") {
                policy.sure = 0.98
            } else if file.hasPrefix("eyes-ft-v2") {
                policy.sure = 0.95
            }
            return policy
        }
    }

    enum Verdict {
        case nothing
        /// It has happened: tell the user.
        case alert
        /// The model was sure from the first look, before it ever said no. Either the thing was
        /// already so when the user asked, or this is a view the model gets wrong; said as
        /// "already so" rather than announced as news.
        case alreadySo
    }

    let condition: WatchCondition
    var policy = Policy()
    /// True once the user has been told: a watch tells the user once and is over.
    private(set) var fired = false
    private(set) var checks = 0
    private var asking = false
    private var lastAsked: (time: TimeInterval, signature: SceneSignature)?
    private var yeses = 0
    private var maybes = 0
    /// Checks in a row that came back a plain no.
    private var noes = 0
    private var saidNo = false

    init(_ condition: WatchCondition) {
        self.condition = condition
    }

    /// Call with every analysed frame. True when the model should be asked about this one; the
    /// caller then reports back with `began`, and `answered` or `abandoned`.
    func wantsCheck(at time: TimeInterval, signature: SceneSignature, heat: Heat) -> Bool {
        guard !fired, !asking, heat != .tooHot else { return false }
        // The first look is at once: the thing may already be so.
        guard let last = lastAsked else { return true }
        let since = time - last.time
        if yeses > 0 { return since >= policy.confirmAfter }
        let gap = heat == .hot ? policy.hotGap : policy.gap
        if maybes > 0 { return since >= gap }
        let slowed = !policy.slowsDown || since >= policy.quiet ? 1 : Double(1 << min(2, noes / max(policy.patience, 1)))
        guard since >= gap * slowed else { return false }
        return signature.change(from: last.signature) >= policy.changeNeeded
    }

    /// The model is now being asked about the frame with this signature.
    mutating func began(at time: TimeInterval, signature: SceneSignature) {
        if let last = lastAsked, time - last.time >= policy.quiet { noes = 0 }
        asking = true
        checks += 1
        lastAsked = (time, signature)
    }

    /// The model's answer about that frame, and whether the user should now be told.
    mutating func answered(_ probability: Float) -> Verdict {
        asking = false
        guard !fired else { return .nothing }
        if let sure = policy.sure, probability >= sure {
            fired = true
            return saidNo ? .alert : .alreadySo
        }
        if probability >= policy.bar {
            yeses += 1
            maybes = 0
            noes = 0
        } else if probability >= policy.maybe, maybes < policy.retries {
            yeses = 0
            maybes += 1
            noes = 0
        } else {
            // A maybe that never became a yes ends as a no.
            saidNo = saidNo || probability < policy.maybe
            yeses = 0
            maybes = 0
            noes += 1
        }
        guard yeses >= policy.yesNeeded else { return .nothing }
        fired = true
        return saidNo ? .alert : .alreadySo
    }

    /// The check did not finish (the user pressed, the app went away). It counts for nothing, and
    /// the frame it was about is forgotten so that the next one is looked at afresh.
    mutating func abandoned() {
        asking = false
        yeses = 0
        maybes = 0
        lastAsked = nil
    }
}
