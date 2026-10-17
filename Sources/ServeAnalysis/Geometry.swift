import Foundation

public enum Geometry {
    /// Angle ABC in degrees (the angle at vertex `b`).
    public static func angle(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let v1 = (x: a.x - b.x, y: a.y - b.y)
        let v2 = (x: c.x - b.x, y: c.y - b.y)
        let mag = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
        guard mag > 0 else { return 0 }
        let cos = min(1, max(-1, (v1.x * v2.x + v1.y * v2.y) / mag))
        return acos(cos) * 180 / .pi
    }

    public static func distance(_ a: Point, _ b: Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    public static func midpoint(_ a: Point, _ b: Point) -> Point {
        Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, confidence: min(a.confidence, b.confidence))
    }

    /// How far the segment from `bottom` to `top` leans away from vertical, in degrees.
    public static func leanFromVertical(bottom: Point, top: Point) -> Double {
        abs(atan2(top.x - bottom.x, bottom.y - top.y) * 180 / .pi)
    }
}
