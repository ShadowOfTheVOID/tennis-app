import Foundation

/// The strokes the app can coach. Mirrors `StrokeType` in the Android `analysis` module.
public enum StrokeType: String, CaseIterable, Codable, Sendable {
    case serve, forehand, backhand, volley, overhead

    public var title: String {
        switch self {
        case .serve: "Serve"
        case .forehand: "Forehand"
        case .backhand: "Backhand"
        case .volley: "Volley"
        case .overhead: "Overhead"
        }
    }

    /// The key moments analysed, in order.
    public var phases: [Phase] {
        switch self {
        case .serve: [.trophy, .contact]
        case .overhead: [.preparation, .contact]
        case .forehand, .backhand, .volley: [.preparation, .contact, .finish]
        }
    }
}

public struct KeyFrame: Sendable {
    public let phase: Phase
    public let frame: Frame

    public init(phase: Phase, frame: Frame) {
        self.phase = phase
        self.frame = frame
    }
}

/// One analysed stroke: its key moments and the checks at each.
public struct StrokeResult: Sendable {
    public let type: StrokeType
    /// Time of contact (or of the key moment closest to it), in seconds.
    public let time: Double
    public let keyFrames: [KeyFrame]
    public let evaluations: [Evaluation]
    /// Backhand hit with both hands.
    public var twoHanded = false
    /// Whether a split step was seen before the stroke (match analysis only).
    public var splitStep: Bool?
    /// Peak hitting-hand speed around contact, in metres per second (an estimate of power).
    public var swingSpeed: Double?
    /// +1 when the swing moves right in the image, -1 when it moves left. Used to line up ghost poses.
    public var direction: Double = 1

    /// Serve rhythm: seconds from the trophy position to contact.
    public var tempo: Double? {
        guard type == .serve, let trophy = frame(for: .trophy), let contact = frame(for: .contact) else { return nil }
        return contact.time - trophy.time
    }

    public init(type: StrokeType, time: Double, keyFrames: [KeyFrame], evaluations: [Evaluation], twoHanded: Bool = false) {
        self.type = type
        self.time = time
        self.keyFrames = keyFrames
        self.evaluations = evaluations
        self.twoHanded = twoHanded
    }

    public var title: String { twoHanded && type == .backhand ? "Two-handed backhand" : type.title }

    public func frame(for phase: Phase) -> Frame? { keyFrames.first { $0.phase == phase }?.frame }

    public func evaluation(for phase: Phase) -> Evaluation? { evaluations.first { $0.phase == phase } }

    /// Average of the key moments' scores that could be measured.
    public var score: Int? {
        let scores = evaluations.compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    public var checks: [Check] { evaluations.flatMap(\.checks) }

    /// The most useful single thing to work on: the first failing check, then the first warning.
    public var topTip: Check? {
        checks.first { $0.status == .bad } ?? checks.first { $0.status == .warn }
    }
}

extension ServeResult {
    /// The serve as a general stroke, for code that handles every stroke the same way.
    public var stroke: StrokeResult {
        var keyFrames: [KeyFrame] = []
        if let trophyFrame { keyFrames.append(KeyFrame(phase: .trophy, frame: trophyFrame)) }
        if let contactFrame { keyFrames.append(KeyFrame(phase: .contact, frame: contactFrame)) }
        var result = StrokeResult(
            type: .serve,
            time: contactFrame?.time ?? trophyFrame?.time ?? 0,
            keyFrames: keyFrames,
            evaluations: [trophy, contact].compactMap { $0 }
        )
        result.swingSpeed = swingSpeed
        result.direction = direction
        return result
    }
}

/// A fast swing of the hitting arm: almost always a stroke, with contact near the peak speed.
public struct SwingEvent: Sendable, Equatable {
    public let index: Int
    public let time: Double
    /// Peak hitting-wrist speed, in torso lengths per second.
    public let speed: Double
}

/// Finds and grades strokes from a sequence of poses. Mirrors `StrokeAnalyzer` on Android;
/// keep thresholds and tips in sync. Assumes the camera films the player side-on.
public enum StrokeAnalyzer {
    /// Wrist speed (torso lengths per second) that counts as a swing. Walking and bouncing the ball stay well below it.
    public static let minSwingSpeed = 4.0

    // MARK: Finding strokes

    /// Every swing in `frames`, in time order.
    public static func swings(in frames: [Frame], hand: Handedness) -> [SwingEvent] {
        guard frames.count >= 3 else { return [] }
        let speed = handSpeeds(frames, hand: hand)
        // Peaks: fast enough, and the fastest within 0.6 s either side (ties go to the earlier frame).
        let candidates = speed.indices.filter { i in
            guard speed[i] >= minSwingSpeed else { return false }
            var j = i - 1
            while j >= 0, frames[i].time - frames[j].time <= 0.6 {
                if speed[j] >= speed[i] { return false }
                j -= 1
            }
            j = i + 1
            while j < frames.count, frames[j].time - frames[i].time <= 0.6 {
                if speed[j] > speed[i] { return false }
                j += 1
            }
            return true
        }
        var kept: [SwingEvent] = []
        for i in candidates.sorted(by: { speed[$0] > speed[$1] }) where !kept.contains(where: { abs($0.time - frames[i].time) < 0.9 }) {
            kept.append(SwingEvent(index: i, time: frames[i].time, speed: speed[i]))
        }
        return kept.sorted { $0.time < $1.time }
    }

    /// Hitting-hand speed at each frame, in torso lengths per second, measured relative to the hips
    /// so running across the court isn't mistaken for a swing. Zero where it can't be measured.
    static func handSpeeds(_ frames: [Frame], hand: Handedness) -> [Double] {
        var speed = [Double](repeating: 0, count: frames.count)
        guard frames.count >= 2, let scale = medianTorso(frames) else { return speed }
        let relative = frames.map { f -> Point? in
            guard let w = hitWrist(f, hand), let hip = hipMid(f.pose) else { return nil }
            return Point(x: w.x - hip.x, y: w.y - hip.y)
        }
        for i in 1..<frames.count {
            guard let a = relative[i - 1], let b = relative[i] else { continue }
            let dt = frames[i].time - frames[i - 1].time
            guard dt > 0, dt < 0.5 else { continue }
            let step = Geometry.distance(a, b)
            // A one-frame jump that comes straight back is a tracking glitch, not a swing.
            if i + 1 < frames.count, let c = relative[i + 1], step > 0, Geometry.distance(a, c) < 0.5 * step { continue }
            speed[i] = step / scale / dt
        }
        return speed
    }

    /// Peak hitting-hand speed within a quarter second of `time`, in metres per second.
    /// An estimate: it assumes an average 0.5 m shoulder-to-hip length. The racket head moves faster.
    public static func handSpeed(_ frames: [Frame], near time: Double, hand: Handedness) -> Double? {
        let speeds = handSpeeds(frames, hand: hand)
        let peak = frames.indices.filter { abs(frames[$0].time - time) <= 0.25 }.map { speeds[$0] }.max() ?? 0
        return peak > 0 ? peak * MatchAnalyzer.torsoMeters : nil
    }

    /// Which stroke a swing was, judged from body position alone (no ball or racket tracking).
    public static func classify(_ frames: [Frame], _ event: SwingEvent, hand: Handedness) -> (type: StrokeType, twoHanded: Bool) {
        let t = event.time
        let scale = medianTorso(frames) ?? 1
        let around = frames.filter { abs($0.time - t) <= 0.3 }
        let highest = around.compactMap { f -> Double? in
            guard let w = hitWrist(f, hand), let nose = f.pose[.nose] else { return nil }
            return (nose.y - w.y) / scale
        }.max() ?? -.infinity

        if highest >= 0.3 {
            // Above the head: a serve starts from standing still with a toss; an overhead doesn't.
            let before = frames.filter { $0.time >= t - 2.0 && $0.time <= t - 0.6 }
            let moved = pathLength(before.compactMap { hipMid($0.pose) }) / scale
            let tossed = frames.contains { f in
                guard f.time >= t - 1.5, f.time < t - 0.1, let w = tossWrist(f, hand), let nose = f.pose[.nose] else { return false }
                return w.y < nose.y
            }
            return (moved <= 0.6 && tossed ? .serve : .overhead, false)
        }

        let contact = frames[event.index]
        let twoHanded: Bool = {
            guard let a = contact.pose[.leftWrist], let b = contact.pose[.rightWrist] else { return false }
            return Geometry.distance(a, b) / scale <= 0.45
        }()
        let d = swingDirection(frames, event, hand)
        let prep = preparationFrame(frames, event, hand, d)
        let backswing = prep.flatMap { backswingDistance($0.pose, hand, d) } ?? 0
        let travel = pathLength(frames.filter { $0.time >= t - 0.6 && $0.time <= t + 0.4 }.compactMap { hitWrist($0, hand) }) / scale
        if travel < 2.2, backswing < 0.6 { return (.volley, false) }

        // Forehand: the hitting shoulder starts behind (turned away from the net). Backhand: it starts in front.
        if let p = prep?.pose, let hs = p[hitShoulder(hand)], let ns = p[tossShoulder(hand)],
           abs((hs.x - ns.x) / scale) >= 0.15 {
            let forehand = (hs.x - ns.x) * d < 0
            return (forehand ? .forehand : .backhand, !forehand && twoHanded)
        }
        // Shoulders edge-on: fall back to which side of the body the hitting hand met the ball.
        if let hs = contact.pose[hitShoulder(hand)], let ns = contact.pose[tossShoulder(hand)], let w = hitWrist(contact, hand) {
            let mid = Geometry.midpoint(hs, ns)
            let forehand = (w.x - mid.x) * (hs.x - ns.x) >= 0
            return (forehand ? .forehand : .backhand, !forehand && twoHanded)
        }
        return (.forehand, false)
    }

    /// Analyse the swing at `event` as `type` (or as whatever it looks like when `type` is nil).
    public static func analyze(_ frames: [Frame], event: SwingEvent, type: StrokeType? = nil, hand: Handedness) -> StrokeResult {
        let classified = classify(frames, event, hand: hand)
        let kind = type ?? classified.type
        let t = event.time
        if kind == .serve {
            let window = frames.filter { $0.time >= t - 2.5 && $0.time <= t + 0.3 }
            return ServeAnalyzer.analyze(window, hand: hand).stroke
        }

        let d = swingDirection(frames, event, hand)
        let contact = frames[event.index]
        var keyFrames: [KeyFrame] = []
        var evaluations: [Evaluation] = []

        switch kind {
        case .overhead:
            let prep = frames.filter { $0.time >= t - 1.5 && $0.time <= t - 0.1 }
                .max { height(tossWrist($0, hand), $0) < height(tossWrist($1, hand), $1) }
            if let prep {
                keyFrames.append(KeyFrame(phase: .preparation, frame: prep))
                evaluations.append(overheadPreparation(prep.pose, hand: hand))
            }
            keyFrames.append(KeyFrame(phase: .contact, frame: contact))
            evaluations.append(overheadContact(contact.pose, hand: hand))

        default:
            let prep = preparationFrame(frames, event, hand, d)
            let finish = finishFrame(frames, event, hand, volley: kind == .volley)
            let scale = medianTorso(frames) ?? 1
            if let prep {
                keyFrames.append(KeyFrame(phase: .preparation, frame: prep))
                evaluations.append(preparation(kind, prep.pose, hand: hand, direction: d))
            }
            keyFrames.append(KeyFrame(phase: .contact, frame: contact))
            evaluations.append(groundContact(kind, contact.pose, hand: hand, direction: d, twoHanded: classified.twoHanded))
            if let finish {
                let from = kind == .volley ? contact.time : (prep?.time ?? t - 0.6)
                let path = frames.filter { $0.time >= from && $0.time <= finish.time }.compactMap { hitWrist($0, hand) }
                evaluations.append(self.finish(kind, finish.pose, hand: hand, swingPath: pathLength(path) / scale))
                keyFrames.append(KeyFrame(phase: .finish, frame: finish))
            }
        }
        var result = StrokeResult(type: kind, time: t, keyFrames: keyFrames, evaluations: evaluations,
                                  twoHanded: kind == .backhand && classified.twoHanded)
        result.swingSpeed = handSpeed(frames, near: t, hand: hand)
        result.direction = d
        return result
    }

    /// Analyse the fastest swing in a short clip of one stroke. Nil if no swing was found.
    public static func analyzeClip(_ frames: [Frame], type: StrokeType? = nil, hand: Handedness) -> StrokeResult? {
        if type == .serve {
            let serve = ServeAnalyzer.analyze(frames, hand: hand)
            return serve.contactFrame == nil && serve.trophyFrame == nil ? nil : serve.stroke
        }
        guard let event = swings(in: frames, hand: hand).max(by: { $0.speed < $1.speed }) else { return nil }
        return analyze(frames, event: event, type: type, hand: hand)
    }

    // MARK: Ready position

    /// The athletic stance between shots: knees bent, feet wide, racket up in front.
    public static func readyPosition(_ pose: Pose) -> Evaluation {
        var checks: [Check] = []
        let t = pose.torsoLength
        if let k = ServeAnalyzer.kneeAngle(pose) {
            let status = ServeAnalyzer.band(k, good: 120...165, warn: 105...172)
            checks.append(Check(id: "ready-knees", label: "Knees bent", status: status, value: ServeAnalyzer.deg(k),
                                tip: status == .good ? "Nice athletic stance." : k > 165
                                    ? "Bend your knees a little more so you can push off in any direction."
                                    : "That's very low — a moderate knee bend lets you move faster."))
        } else { checks.append(ServeAnalyzer.unknown("ready-knees", "Knees bent")) }

        if let w = stanceWidth(pose) {
            let status: Status = w >= 0.9 ? .good : w >= 0.6 ? .warn : .bad
            checks.append(Check(id: "ready-stance", label: "Feet wider than shoulders", status: status, value: ServeAnalyzer.torso(w),
                                tip: status == .good ? "Good wide base." : "Widen your stance — feet a bit more than shoulder-width apart."))
        } else { checks.append(ServeAnalyzer.unknown("ready-stance", "Feet wider than shoulders")) }

        if let hip = hipMid(pose), let t, let lw = pose[.leftWrist], let rw = pose[.rightWrist] {
            let up = [lw, rw].filter { (hip.y - $0.y) / t >= 0.1 }.count
            let status: Status = up == 2 ? .good : up == 1 ? .warn : .bad
            checks.append(Check(id: "ready-hands", label: "Racket up in front", status: status, value: "\(up) of 2 hands up",
                                tip: status == .good ? "Racket ready in front of you." : "Hold the racket up in front of you with both hands, above your waist."))
        } else { checks.append(ServeAnalyzer.unknown("ready-hands", "Racket up in front")) }
        return Evaluation(phase: .ready, checks: checks)
    }

    // MARK: Groundstrokes and volleys

    static func preparation(_ type: StrokeType, _ pose: Pose, hand: Handedness, direction d: Double) -> Evaluation {
        var checks: [Check] = []
        let volley = type == .volley
        if let b = backswingDistance(pose, hand, d) {
            if volley {
                let status: Status = b <= 0.4 ? .good : b <= 0.7 ? .warn : .bad
                checks.append(Check(id: "volley-compact", label: "Compact backswing", status: status, value: ServeAnalyzer.torso(b),
                                    tip: status == .good ? "Nice short preparation." : "Keep the backswing short — just turn your shoulders and catch the ball in front."))
            } else {
                let status: Status = b >= 0.5 ? .good : b >= 0.25 ? .warn : .bad
                checks.append(Check(id: "prep-takeback", label: "Racket taken back", status: status, value: ServeAnalyzer.torso(b),
                                    tip: status == .good ? "Good early take-back." : "Turn and take the racket back early, before the ball bounces."))
            }
        } else { checks.append(ServeAnalyzer.unknown(volley ? "volley-compact" : "prep-takeback", volley ? "Compact backswing" : "Racket taken back")) }

        if let k = ServeAnalyzer.kneeAngle(pose) {
            let status = ServeAnalyzer.band(k, good: 110...160, warn: 95...170)
            checks.append(Check(id: "prep-knees", label: "Knees bent", status: status, value: ServeAnalyzer.deg(k),
                                tip: status == .good ? "Loaded and ready to push into the shot." : k > 160
                                    ? "Bend your knees as you turn so you can push up into the shot."
                                    : "That's very low — a moderate bend keeps you balanced."))
        } else { checks.append(ServeAnalyzer.unknown("prep-knees", "Knees bent")) }

        if volley {
            if let w = hitWrist(pose, hand), let hip = hipMid(pose), let t = pose.torsoLength {
                let h = (hip.y - w.y) / t
                let status: Status = h >= 0.3 ? .good : h >= 0 ? .warn : .bad
                checks.append(Check(id: "volley-hands-up", label: "Racket head up", status: status, value: ServeAnalyzer.torso(h),
                                    tip: status == .good ? "Racket up and ready." : "Keep the racket up in front of you, not dropping below your waist."))
            } else { checks.append(ServeAnalyzer.unknown("volley-hands-up", "Racket head up")) }
        } else if let w = stanceWidth(pose) {
            let status: Status = w >= 0.9 ? .good : w >= 0.6 ? .warn : .bad
            checks.append(Check(id: "prep-stance", label: "Wide, stable stance", status: status, value: ServeAnalyzer.torso(w),
                                tip: status == .good ? "Solid base." : "Widen your stance — step out so your feet are wider than your shoulders."))
        } else { checks.append(ServeAnalyzer.unknown("prep-stance", "Wide, stable stance")) }

        if type == .forehand {
            if let w = tossWristIn(pose, hand), let sm = shoulderMid(pose), let t = pose.torsoLength {
                let f = (w.x - sm.x) * d / t
                let status: Status = f >= 0.15 ? .good : f >= -0.1 ? .warn : .bad
                checks.append(Check(id: "prep-off-arm", label: "Non-hitting arm out in front", status: status, value: ServeAnalyzer.torso(f),
                                    tip: status == .good ? "Off-arm helping the turn." : "Point your non-hitting hand toward the ball as you turn — it sets up the shoulder turn."))
            } else { checks.append(ServeAnalyzer.unknown("prep-off-arm", "Non-hitting arm out in front")) }
        }
        return Evaluation(phase: .preparation, checks: checks)
    }

    static func groundContact(_ type: StrokeType, _ pose: Pose, hand: Handedness, direction d: Double, twoHanded: Bool) -> Evaluation {
        var checks: [Check] = []
        let (hit, _) = pose.sides(for: hand)
        let t = pose.torsoLength

        if let w = hit.wrist, let hip = hipMid(pose), let t {
            let f = (w.x - hip.x) * d / t
            let good = type == .volley ? 0.3 : 0.2
            let status: Status = f >= good ? .good : f >= -0.05 ? .warn : .bad
            checks.append(Check(id: "contact-in-front", label: "Contact out in front", status: status, value: ServeAnalyzer.torso(f),
                                tip: status == .good ? "Great — you met the ball in front." : "Meet the ball out in front of your front hip, not beside you."))
        } else { checks.append(ServeAnalyzer.unknown("contact-in-front", "Contact out in front")) }

        if !(type == .backhand && twoHanded) {
            if let s = hit.shoulder, let e = hit.elbow, let w = hit.wrist {
                let a = Geometry.angle(s, e, w)
                let check: Check
                switch type {
                case .volley:
                    let status = ServeAnalyzer.band(a, good: 100...170, warn: 80...180)
                    check = Check(id: "volley-firm", label: "Firm arm at contact", status: status, value: ServeAnalyzer.deg(a),
                                  tip: status == .good ? "Firm, compact contact." : "Keep a firm, slightly bent arm and punch the ball — don't swing at it.")
                case .backhand:
                    let status = ServeAnalyzer.band(a, good: 150...180, warn: 130...180)
                    check = Check(id: "contact-spacing", label: "Arm extended at contact", status: status, value: ServeAnalyzer.deg(a),
                                  tip: status == .good ? "Good extension through the ball." : "On a one-handed backhand, hit with a straight arm — give yourself more room.")
                default:
                    let status = ServeAnalyzer.band(a, good: 110...180, warn: 90...180)
                    check = Check(id: "contact-spacing", label: "Room between you and the ball", status: status, value: ServeAnalyzer.deg(a),
                                  tip: status == .good ? "Good spacing." : "You're jammed — leave about an arm's length between you and the ball.")
                }
                checks.append(check)
            } else {
                checks.append(ServeAnalyzer.unknown(type == .volley ? "volley-firm" : "contact-spacing", "Arm at contact"))
            }
        }

        if type != .volley {
            if let w = hit.wrist, let hip = hipMid(pose), let t {
                let h = (hip.y - w.y) / t
                let status = ServeAnalyzer.band(h, good: -0.3...0.9, warn: -0.6...1.2)
                checks.append(Check(id: "strike-zone", label: "Contact between waist and chest", status: status, value: ServeAnalyzer.torso(h),
                                    tip: status == .good ? "Right in your strike zone." : h > 0.9
                                        ? "Move back so you don't have to hit at shoulder height or above."
                                        : "Bend your knees to get down to low balls instead of reaching with the racket."))
            } else { checks.append(ServeAnalyzer.unknown("strike-zone", "Contact between waist and chest")) }
        }

        checks.append(balance(pose, id: "contact-balance", label: "Balanced at contact",
                              tip: "Stay tall and balanced through contact — let your legs, not your back, lower you."))
        return Evaluation(phase: .contact, checks: checks)
    }

    static func finish(_ type: StrokeType, _ pose: Pose, hand: Handedness, swingPath: Double) -> Evaluation {
        var checks: [Check] = []
        if type == .volley {
            let status: Status = swingPath <= 1.2 ? .good : swingPath <= 1.8 ? .warn : .bad
            checks.append(Check(id: "volley-short", label: "Short follow-through", status: status, value: ServeAnalyzer.torso(swingPath),
                                tip: status == .good ? "Punch and stop — nicely done." : "Punch and stop — a volley needs very little follow-through."))
        } else {
            if let w = hitWrist(pose, hand), let sm = shoulderMid(pose), let t = pose.torsoLength {
                let h = (sm.y - w.y) / t
                let status: Status = h >= 0 ? .good : h >= -0.5 ? .warn : .bad
                checks.append(Check(id: "finish-high", label: "High finish", status: status, value: ServeAnalyzer.torso(h),
                                    tip: status == .good ? "Nice high finish." : "Swing up and finish high, over your shoulder."))
            } else { checks.append(ServeAnalyzer.unknown("finish-high", "High finish")) }
            let status: Status = swingPath >= 2.0 ? .good : swingPath >= 1.3 ? .warn : .bad
            checks.append(Check(id: "finish-through", label: "Full swing through the ball", status: status, value: ServeAnalyzer.torso(swingPath),
                                tip: status == .good ? "Full, relaxed swing." : "Swing all the way through the ball instead of stopping at contact."))
        }
        checks.append(balance(pose, id: "finish-balance", label: "Balanced finish",
                              tip: "Hold your finish for a second — if you can't, you were off balance."))
        return Evaluation(phase: .finish, checks: checks)
    }

    // MARK: Overhead

    static func overheadPreparation(_ pose: Pose, hand: Handedness) -> Evaluation {
        var checks: [Check] = []
        let (hit, toss) = pose.sides(for: hand)
        let t = pose.torsoLength
        if let w = toss.wrist, let nose = pose[.nose], let t {
            let h = (nose.y - w.y) / t
            let status: Status = h >= 0.3 ? .good : h >= 0 ? .warn : .bad
            checks.append(Check(id: "oh-off-arm-up", label: "Non-hitting hand pointing up", status: status, value: ServeAnalyzer.torso(h),
                                tip: status == .good ? "Good — tracking the ball with your hand." : "Point your non-hitting hand up at the ball to line it up."))
        } else { checks.append(ServeAnalyzer.unknown("oh-off-arm-up", "Non-hitting hand pointing up")) }

        if let s = hit.shoulder, let e = hit.elbow, let t {
            let drop = (e.y - s.y) / t
            let status: Status = drop <= 0.1 ? .good : drop <= 0.3 ? .warn : .bad
            checks.append(Check(id: "oh-racket-up", label: "Racket up early", status: status, value: drop <= 0 ? "above" : "\(ServeAnalyzer.torso(drop)) below",
                                tip: status == .good ? "Racket up and ready." : "Get the racket up behind your head early, elbow at shoulder height."))
        } else { checks.append(ServeAnalyzer.unknown("oh-racket-up", "Racket up early")) }

        if let k = ServeAnalyzer.kneeAngle(pose) {
            let status = ServeAnalyzer.band(k, good: 110...165, warn: 95...172)
            checks.append(Check(id: "prep-knees", label: "Knees bent", status: status, value: ServeAnalyzer.deg(k),
                                tip: status == .good ? "Loaded and ready." : "Bend your knees so you can push up to the ball."))
        } else { checks.append(ServeAnalyzer.unknown("prep-knees", "Knees bent")) }
        return Evaluation(phase: .preparation, checks: checks)
    }

    static func overheadContact(_ pose: Pose, hand: Handedness) -> Evaluation {
        var checks: [Check] = []
        let (hit, _) = pose.sides(for: hand)
        if let s = hit.shoulder, let e = hit.elbow, let w = hit.wrist {
            let a = Geometry.angle(s, e, w)
            let status = ServeAnalyzer.band(a, good: 155...180, warn: 140...180)
            checks.append(Check(id: "hit-arm-extended", label: "Hitting arm fully extended", status: status, value: ServeAnalyzer.deg(a),
                                tip: status == .good ? "Full reach at contact." : "Reach up and hit at full extension — move back so the ball doesn't drop on you."))
        } else { checks.append(ServeAnalyzer.unknown("hit-arm-extended", "Hitting arm fully extended")) }

        if let w = hit.wrist, let nose = pose[.nose], let t = pose.torsoLength {
            let h = (nose.y - w.y) / t
            let status: Status = h >= 0.7 ? .good : h >= 0.4 ? .warn : .bad
            checks.append(Check(id: "oh-contact-high", label: "Contact high and in front", status: status, value: ServeAnalyzer.torso(h),
                                tip: status == .good ? "Hit at the top of your reach." : "Take quick steps back so you can hit the ball at the top of your reach."))
        } else { checks.append(ServeAnalyzer.unknown("oh-contact-high", "Contact high and in front")) }

        checks.append(balance(pose, id: "contact-balance", label: "Balanced at contact",
                              tip: "Stay tall — falling backwards usually means you didn't get far enough behind the ball."))
        return Evaluation(phase: .contact, checks: checks)
    }

    // MARK: Helpers

    static func balance(_ pose: Pose, id: String, label: String, tip: String) -> Check {
        guard let ls = pose[.leftShoulder], let rs = pose[.rightShoulder], let lh = pose[.leftHip], let rh = pose[.rightHip] else {
            return ServeAnalyzer.unknown(id, label)
        }
        let lean = Geometry.leanFromVertical(bottom: Geometry.midpoint(lh, rh), top: Geometry.midpoint(ls, rs))
        let status = ServeAnalyzer.band(lean, good: 0...20, warn: 0...30)
        return Check(id: id, label: label, status: status, value: ServeAnalyzer.deg(lean), tip: status == .good ? "Well balanced." : tip)
    }

    static func hitShoulder(_ hand: Handedness) -> Joint { hand == .right ? .rightShoulder : .leftShoulder }
    static func tossShoulder(_ hand: Handedness) -> Joint { hand == .right ? .leftShoulder : .rightShoulder }
    static func hitWrist(_ f: Frame, _ hand: Handedness) -> Point? { f.pose[hand == .right ? .rightWrist : .leftWrist] }
    static func tossWrist(_ f: Frame, _ hand: Handedness) -> Point? { tossWristIn(f.pose, hand) }
    static func tossWristIn(_ p: Pose, _ hand: Handedness) -> Point? { p[hand == .right ? .leftWrist : .rightWrist] }
    static func hitWrist(_ p: Pose, _ hand: Handedness) -> Point? { p[hand == .right ? .rightWrist : .leftWrist] }

    static func hipMid(_ p: Pose) -> Point? {
        guard let l = p[.leftHip], let r = p[.rightHip] else { return nil }
        return Geometry.midpoint(l, r)
    }

    static func shoulderMid(_ p: Pose) -> Point? {
        guard let l = p[.leftShoulder], let r = p[.rightShoulder] else { return nil }
        return Geometry.midpoint(l, r)
    }

    static func stanceWidth(_ p: Pose) -> Double? {
        guard let l = p[.leftAnkle], let r = p[.rightAnkle], let t = p.torsoLength else { return nil }
        return Geometry.distance(l, r) / t
    }

    /// Height of `point` above the nose, in torso lengths (-infinity when unknown).
    static func height(_ point: Point?, _ f: Frame) -> Double {
        guard let point, let nose = f.pose[.nose], let t = f.pose.torsoLength else { return -.infinity }
        return (nose.y - point.y) / t
    }

    /// How far the hitting hand is behind the shoulders, against the swing direction `d` (+1 or -1).
    static func backswingDistance(_ p: Pose, _ hand: Handedness, _ d: Double) -> Double? {
        guard let w = hitWrist(p, hand), let sm = shoulderMid(p), let t = p.torsoLength else { return nil }
        return -(w.x - sm.x) * d / t
    }

    static func medianTorso(_ frames: [Frame]) -> Double? {
        let lengths = frames.compactMap(\.pose.torsoLength).sorted()
        return lengths.isEmpty ? nil : lengths[lengths.count / 2]
    }

    static func pathLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).map { Geometry.distance($0, $1) }.reduce(0, +)
    }

    /// +1 when the hitting hand moves right through contact, -1 when it moves left.
    static func swingDirection(_ frames: [Frame], _ event: SwingEvent, _ hand: Handedness) -> Double {
        let before = frames[max(0, event.index - 1)]
        let after = frames[min(frames.count - 1, event.index + 1)]
        guard let a = hitWrist(before, hand), let b = hitWrist(after, hand) else { return 1 }
        return b.x >= a.x ? 1 : -1
    }

    /// The moment of fullest backswing before contact.
    static func preparationFrame(_ frames: [Frame], _ event: SwingEvent, _ hand: Handedness, _ d: Double) -> Frame? {
        frames.filter { $0.time >= event.time - 1.2 && $0.time <= event.time - 0.08 }
            .compactMap { f in backswingDistance(f.pose, hand, d).map { (f, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The finish: highest hand after a groundstroke, or the end of the punch on a volley.
    static func finishFrame(_ frames: [Frame], _ event: SwingEvent, _ hand: Handedness, volley: Bool) -> Frame? {
        if volley {
            return frames.filter { $0.time >= event.time + 0.1 && $0.time <= event.time + 0.6 && hitWrist($0, hand) != nil }
                .min { abs($0.time - event.time - 0.35) < abs($1.time - event.time - 0.35) }
        }
        return frames.filter { $0.time >= event.time + 0.08 && $0.time <= event.time + 1.0 }
            .compactMap { f in hitWrist(f, hand).map { (f, $0.y) } }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Watches a live stream of poses and reports each groundstroke, volley or overhead about a
/// second after it's hit (once the finish has been seen). Use `ServeTracker` for serves.
public struct StrokeTracker: Sendable {
    public let hand: Handedness
    /// The stroke being practised, or nil to work it out from each swing.
    public let type: StrokeType?
    private var buffer: [Frame] = []
    private var lastReported = -Double.infinity

    public init(hand: Handedness, type: StrokeType?) {
        self.hand = hand
        self.type = type
    }

    public mutating func add(_ frame: Frame) -> StrokeResult? {
        buffer.append(frame)
        buffer.removeAll { $0.time < frame.time - 3.5 }
        let swings = StrokeAnalyzer.swings(in: buffer, hand: hand)
        guard let swing = swings.first(where: { $0.time > lastReported + 0.5 && frame.time - $0.time >= 1.0 }) else { return nil }
        lastReported = swing.time
        return StrokeAnalyzer.analyze(buffer, event: swing, type: type, hand: hand)
    }
}
