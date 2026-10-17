import Foundation

/// Body joints used by the serve analysis. Left/right are the *player's* left and right.
public enum Joint: String, CaseIterable, Sendable {
    case nose
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// A 2D point in image pixel space, y growing downward.
public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double = 1) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public struct Pose: Sendable {
    /// Joints below this confidence are treated as not visible.
    public static let minConfidence = 0.3

    public var joints: [Joint: Point]

    public init(joints: [Joint: Point]) {
        self.joints = joints
    }

    /// The joint if it was detected confidently, otherwise nil.
    public subscript(joint: Joint) -> Point? {
        guard let p = joints[joint], p.confidence >= Pose.minConfidence else { return nil }
        return p
    }

    /// Shoulder-midpoint to hip-midpoint length, used to normalise distances so
    /// results don't depend on how far the player stands from the camera.
    public var torsoLength: Double? {
        guard let ls = self[.leftShoulder], let rs = self[.rightShoulder],
              let lh = self[.leftHip], let rh = self[.rightHip] else { return nil }
        return max(Geometry.distance(Geometry.midpoint(ls, rs), Geometry.midpoint(lh, rh)), 1e-6)
    }
}

public enum Handedness: String, CaseIterable, Sendable {
    case right, left
}

/// The joints of one side of the body.
struct Side {
    let shoulder, elbow, wrist, hip, knee, ankle: Point?

    init(_ pose: Pose, left: Bool) {
        shoulder = pose[left ? .leftShoulder : .rightShoulder]
        elbow = pose[left ? .leftElbow : .rightElbow]
        wrist = pose[left ? .leftWrist : .rightWrist]
        hip = pose[left ? .leftHip : .rightHip]
        knee = pose[left ? .leftKnee : .rightKnee]
        ankle = pose[left ? .leftAnkle : .rightAnkle]
    }
}

extension Pose {
    /// The racket arm side and the tossing arm side for a given handedness.
    func sides(for hand: Handedness) -> (hit: Side, toss: Side) {
        (Side(self, left: hand == .left), Side(self, left: hand == .right))
    }
}
