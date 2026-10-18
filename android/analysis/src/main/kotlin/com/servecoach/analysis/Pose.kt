package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Body joints used by the serve analysis. Left/right are the *player's* left and right. */
enum class Joint {
    NOSE,
    LEFT_SHOULDER, RIGHT_SHOULDER,
    LEFT_ELBOW, RIGHT_ELBOW,
    LEFT_WRIST, RIGHT_WRIST,
    LEFT_HIP, RIGHT_HIP,
    LEFT_KNEE, RIGHT_KNEE,
    LEFT_ANKLE, RIGHT_ANKLE,
}

/** A 2D point in image pixel space, y growing downward. */
data class Point(val x: Double, val y: Double, val confidence: Double = 1.0)

data class Pose(val joints: Map<Joint, Point>) {
    /** The joint if it was detected confidently, otherwise null. */
    operator fun get(joint: Joint): Point? = joints[joint]?.takeIf { it.confidence >= MIN_CONFIDENCE }

    /**
     * Shoulder-midpoint to hip-midpoint length, used to normalise distances so results
     * don't depend on how far the player stands from the camera.
     */
    val torsoLength: Double?
        get() {
            val ls = this[Joint.LEFT_SHOULDER] ?: return null
            val rs = this[Joint.RIGHT_SHOULDER] ?: return null
            val lh = this[Joint.LEFT_HIP] ?: return null
            val rh = this[Joint.RIGHT_HIP] ?: return null
            return max(Geometry.distance(Geometry.midpoint(ls, rs), Geometry.midpoint(lh, rh)), 1e-6)
        }

    internal fun sides(hand: Handedness) = Side(this, left = hand == Handedness.LEFT) to Side(this, left = hand == Handedness.RIGHT)

    companion object {
        /** Joints below this confidence are treated as not visible. */
        const val MIN_CONFIDENCE = 0.3
    }
}

enum class Handedness { RIGHT, LEFT }

/** The joints of one side of the body. */
internal class Side(pose: Pose, left: Boolean) {
    val shoulder = pose[if (left) Joint.LEFT_SHOULDER else Joint.RIGHT_SHOULDER]
    val elbow = pose[if (left) Joint.LEFT_ELBOW else Joint.RIGHT_ELBOW]
    val wrist = pose[if (left) Joint.LEFT_WRIST else Joint.RIGHT_WRIST]
    val hip = pose[if (left) Joint.LEFT_HIP else Joint.RIGHT_HIP]
    val knee = pose[if (left) Joint.LEFT_KNEE else Joint.RIGHT_KNEE]
    val ankle = pose[if (left) Joint.LEFT_ANKLE else Joint.RIGHT_ANKLE]
}

object Geometry {
    /** Angle ABC in degrees (the angle at vertex [b]). */
    fun angle(a: Point, b: Point, c: Point): Double {
        val v1x = a.x - b.x
        val v1y = a.y - b.y
        val v2x = c.x - b.x
        val v2y = c.y - b.y
        val mag = hypot(v1x, v1y) * hypot(v2x, v2y)
        if (mag == 0.0) return 0.0
        val cos = min(1.0, max(-1.0, (v1x * v2x + v1y * v2y) / mag))
        return Math.toDegrees(acos(cos))
    }

    fun distance(a: Point, b: Point) = hypot(a.x - b.x, a.y - b.y)

    fun midpoint(a: Point, b: Point) = Point((a.x + b.x) / 2, (a.y + b.y) / 2, min(a.confidence, b.confidence))

    /** How far the segment from [bottom] to [top] leans away from vertical, in degrees. */
    fun leanFromVertical(bottom: Point, top: Point) = abs(Math.toDegrees(atan2(top.x - bottom.x, bottom.y - top.y)))
}
