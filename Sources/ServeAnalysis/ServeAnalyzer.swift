import Foundation

public enum Phase: String, Sendable {
    case ready, trophy, contact
}

public enum Status: String, Sendable {
    case good, warn, bad, unknown

    var points: Double? {
        switch self {
        case .good: 1
        case .warn: 0.5
        case .bad: 0
        case .unknown: nil
        }
    }
}

public struct Check: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let status: Status
    /// Measured value, formatted for display (e.g. "95°").
    public let value: String
    public let tip: String
}

public struct Evaluation: Sendable {
    public let phase: Phase
    public let checks: [Check]

    /// 0–100 over the checks that could be measured, or nil if none could.
    public var score: Int? {
        let pts = checks.compactMap(\.status.points)
        guard !pts.isEmpty else { return nil }
        return Int((pts.reduce(0, +) / Double(pts.count) * 100).rounded())
    }
}

public struct Frame: Sendable {
    public let time: Double
    public let pose: Pose

    public init(time: Double, pose: Pose) {
        self.time = time
        self.pose = pose
    }
}

public enum ServeAnalyzer {
    // MARK: Phase detection

    /// Classify which part of the serve a single pose looks like.
    public static func phase(of pose: Pose, hand: Handedness) -> Phase {
        let (hit, toss) = pose.sides(for: hand)
        guard let nose = pose[.nose], let t = pose.torsoLength,
              let sh = hit.shoulder, let el = hit.elbow, let wr = hit.wrist else { return .ready }
        if nose.y - wr.y > 0.4 * t, Geometry.angle(sh, el, wr) > 145 { return .contact }
        if let tw = toss.wrist, tw.y < nose.y { return .trophy }
        return .ready
    }

    public static func evaluate(_ pose: Pose, hand: Handedness) -> Evaluation? {
        switch phase(of: pose, hand: hand) {
        case .trophy: trophy(pose, hand: hand)
        case .contact: contact(pose, hand: hand)
        case .ready: nil
        }
    }

    // MARK: Trophy position

    public static func trophy(_ pose: Pose, hand: Handedness) -> Evaluation {
        let (hit, toss) = pose.sides(for: hand)
        let t = pose.torsoLength
        var checks: [Check] = []

        if let s = toss.shoulder, let e = toss.elbow, let w = toss.wrist {
            let a = Geometry.angle(s, e, w)
            let status = band(a, good: 155...180, warn: 135...180)
            checks.append(Check(id: "toss-arm-straight", label: "Tossing arm straight", status: status, value: deg(a),
                                tip: status == .good ? "Nice, long tossing arm."
                                    : "Keep the tossing arm straight and lift from the shoulder — don't flick from the elbow."))
        } else { checks.append(unknown("toss-arm-straight", "Tossing arm straight")) }

        if let w = toss.wrist, let nose = pose[.nose], let t {
            let h = (nose.y - w.y) / t
            let status: Status = h >= 0.6 ? .good : h >= 0.2 ? .warn : .bad
            checks.append(Check(id: "toss-arm-high", label: "Tossing arm reaching up", status: status, value: torso(h),
                                tip: status == .good ? "Tossing hand is reaching high."
                                    : "Release higher — finish the toss with your hand pointing up at the ball."))
        } else { checks.append(unknown("toss-arm-high", "Tossing arm reaching up")) }

        if let s = hit.shoulder, let e = hit.elbow, let w = hit.wrist {
            let a = Geometry.angle(s, e, w)
            let status = band(a, good: 70...115, warn: 55...135)
            let tip = status == .good ? "Good 'L' shape in the hitting arm."
                : a > 115 ? "Bend the hitting elbow more — make an 'L' with the racket up behind you."
                : "Hitting elbow is too closed — open it toward a 90° 'L'."
            checks.append(Check(id: "hit-elbow-bend", label: "Hitting elbow ~90°", status: status, value: deg(a), tip: tip))
        } else { checks.append(unknown("hit-elbow-bend", "Hitting elbow ~90°")) }

        if let s = hit.shoulder, let e = hit.elbow, let t {
            let drop = (e.y - s.y) / t
            let status: Status = drop <= 0.1 ? .good : drop <= 0.3 ? .warn : .bad
            checks.append(Check(id: "hit-elbow-height", label: "Hitting elbow at shoulder height", status: status,
                                value: drop <= 0 ? "above" : "\(torso(drop)) below",
                                tip: status == .good ? "Elbow is up where it should be."
                                    : "Raise the hitting elbow to about shoulder height — a low elbow costs power and strains the shoulder."))
        } else { checks.append(unknown("hit-elbow-height", "Hitting elbow at shoulder height")) }

        if let hs = hit.shoulder, let ts = toss.shoulder, let t {
            let tilt = (hs.y - ts.y) / t
            let status: Status = tilt >= 0.12 ? .good : tilt >= 0.04 ? .warn : .bad
            checks.append(Check(id: "shoulder-tilt", label: "Shoulders tilted toward the toss", status: status, value: torso(tilt),
                                tip: status == .good ? "Great shoulder-over-shoulder tilt."
                                    : "Let the tossing shoulder rise above the hitting shoulder — tilt like a seesaw."))
        } else { checks.append(unknown("shoulder-tilt", "Shoulders tilted toward the toss")) }

        if let k = kneeAngle(pose) {
            let status = band(k, good: 110...155, warn: 95...168)
            let tip = status == .good ? "Legs are loaded and ready to drive."
                : k > 155 ? "Bend your knees more to load up — the serve starts from the legs."
                : "That's a very deep bend — you may lose balance. Aim for a moderate squat."
            checks.append(Check(id: "knee-bend", label: "Knees loaded", status: status, value: deg(k), tip: tip))
        } else { checks.append(unknown("knee-bend", "Knees loaded")) }

        return Evaluation(phase: .trophy, checks: checks)
    }

    // MARK: Contact

    public static func contact(_ pose: Pose, hand: Handedness) -> Evaluation {
        let (hit, toss) = pose.sides(for: hand)
        let t = pose.torsoLength
        var checks: [Check] = []

        if let s = hit.shoulder, let e = hit.elbow, let w = hit.wrist {
            let a = Geometry.angle(s, e, w)
            let status = band(a, good: 160...180, warn: 145...180)
            checks.append(Check(id: "hit-arm-extended", label: "Hitting arm fully extended", status: status, value: deg(a),
                                tip: status == .good ? "Full reach at contact."
                                    : "Reach up and hit at full extension — don't let the ball drop into you."))
        } else { checks.append(unknown("hit-arm-extended", "Hitting arm fully extended")) }

        if let w = hit.wrist, let nose = pose[.nose], let t {
            let h = (nose.y - w.y) / t
            let status: Status = h >= 0.9 ? .good : h >= 0.6 ? .warn : .bad
            checks.append(Check(id: "contact-height", label: "High contact point", status: status, value: torso(h),
                                tip: status == .good ? "Contact point is nice and high."
                                    : "Contact the ball higher — toss a bit higher and drive up through it."))
        } else { checks.append(unknown("contact-height", "High contact point")) }

        if let k = kneeAngle(pose) {
            let status = band(k, good: 160...180, warn: 145...180)
            checks.append(Check(id: "leg-drive", label: "Legs extended (leg drive)", status: status, value: deg(k),
                                tip: status == .good ? "You drove up through your legs."
                                    : "Push up through the ground so your legs are straight by contact."))
        } else { checks.append(unknown("leg-drive", "Legs extended (leg drive)")) }

        if let ls = pose[.leftShoulder], let rs = pose[.rightShoulder], let lh = pose[.leftHip], let rh = pose[.rightHip] {
            let lean = Geometry.leanFromVertical(bottom: Geometry.midpoint(lh, rh), top: Geometry.midpoint(ls, rs))
            let status = band(lean, good: 0...20, warn: 0...32)
            checks.append(Check(id: "torso-upright", label: "Torso tall and balanced", status: status, value: deg(lean),
                                tip: status == .good ? "Tall, balanced posture through contact."
                                    : "You're leaning a lot — keep the toss in front and stay tall instead of bending sideways."))
        } else { checks.append(unknown("torso-upright", "Torso tall and balanced")) }

        if let w = toss.wrist, let s = toss.shoulder, let t {
            let tucked = w.y > s.y - 0.1 * t
            checks.append(Check(id: "toss-arm-tuck", label: "Tossing arm tucked in", status: tucked ? .good : .warn,
                                value: tucked ? "tucked" : "still up",
                                tip: tucked ? "Tossing arm pulled in — that helps you rotate."
                                    : "Pull the tossing arm down into your chest as you swing up to speed up rotation."))
        } else { checks.append(unknown("toss-arm-tuck", "Tossing arm tucked in")) }

        return Evaluation(phase: .contact, checks: checks)
    }

    // MARK: Recorded serves

    /// Find the trophy and contact frames in a recorded serve.
    /// Contact: the hitting wrist at its highest relative to the head.
    /// Trophy: the tossing wrist at its highest before contact.
    public static func keyFrames(in frames: [Frame], hand: Handedness) -> (trophy: Frame?, contact: Frame?) {
        func height(_ f: Frame, _ wrist: Point?) -> Double? {
            guard let wrist, let nose = f.pose[.nose], let t = f.pose.torsoLength else { return nil }
            return (nose.y - wrist.y) / t
        }
        let contact = frames
            .compactMap { f in height(f, f.pose.sides(for: hand).hit.wrist).map { (f, $0) } }
            .max { $0.1 < $1.1 }?.0
        let contactTime = contact?.time ?? .infinity
        let trophy = frames
            .filter { $0.time < contactTime }
            .compactMap { f in height(f, f.pose.sides(for: hand).toss.wrist).map { (f, $0) } }
            .max { $0.1 < $1.1 }?.0
        return (trophy, contact)
    }

    // MARK: Helpers

    static func kneeAngle(_ pose: Pose) -> Double? {
        let angles = [Side(pose, left: true), Side(pose, left: false)].compactMap { s -> Double? in
            guard let h = s.hip, let k = s.knee, let a = s.ankle else { return nil }
            return Geometry.angle(h, k, a)
        }
        guard !angles.isEmpty else { return nil }
        return angles.reduce(0, +) / Double(angles.count)
    }

    private static func band(_ v: Double, good: ClosedRange<Double>, warn: ClosedRange<Double>) -> Status {
        good.contains(v) ? .good : warn.contains(v) ? .warn : .bad
    }

    private static func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    private static func torso(_ v: Double) -> String { String(format: "%.2f× torso", v) }

    private static func unknown(_ id: String, _ label: String) -> Check {
        Check(id: id, label: label, status: .unknown, value: "—",
              tip: "Not enough of your body is visible. Step back so your whole body is in frame.")
    }
}
