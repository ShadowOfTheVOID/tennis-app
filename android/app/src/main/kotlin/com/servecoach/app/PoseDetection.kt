package com.servecoach.app

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseDetector
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.accurate.AccuratePoseDetectorOptions
import com.servecoach.analysis.Joint
import com.servecoach.analysis.Point
import com.servecoach.analysis.Pose

/** A detected pose together with the size of the (upright) image it was found in. */
data class PoseSample(val pose: Pose, val imageWidth: Int, val imageHeight: Int)

private val LANDMARKS = mapOf(
    Joint.NOSE to PoseLandmark.NOSE,
    Joint.LEFT_SHOULDER to PoseLandmark.LEFT_SHOULDER, Joint.RIGHT_SHOULDER to PoseLandmark.RIGHT_SHOULDER,
    Joint.LEFT_ELBOW to PoseLandmark.LEFT_ELBOW, Joint.RIGHT_ELBOW to PoseLandmark.RIGHT_ELBOW,
    Joint.LEFT_WRIST to PoseLandmark.LEFT_WRIST, Joint.RIGHT_WRIST to PoseLandmark.RIGHT_WRIST,
    Joint.LEFT_HIP to PoseLandmark.LEFT_HIP, Joint.RIGHT_HIP to PoseLandmark.RIGHT_HIP,
    Joint.LEFT_KNEE to PoseLandmark.LEFT_KNEE, Joint.RIGHT_KNEE to PoseLandmark.RIGHT_KNEE,
    Joint.LEFT_ANKLE to PoseLandmark.LEFT_ANKLE, Joint.RIGHT_ANKLE to PoseLandmark.RIGHT_ANKLE,
)

/** Google ML Kit's on-device pose detector, converted to `analysis.Pose` (pixel coordinates, y down). */
class BodyPoseDetector(stream: Boolean) : AutoCloseable {
    private val detector: PoseDetector = PoseDetection.getClient(
        AccuratePoseDetectorOptions.Builder()
            .setDetectorMode(if (stream) AccuratePoseDetectorOptions.STREAM_MODE else AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE)
            .build()
    )

    /** Blocking; call off the main thread. [width]/[height] are of the upright image. */
    fun detect(image: InputImage, width: Int, height: Int): PoseSample? {
        val result = runCatching { Tasks.await(detector.process(image)) }.getOrNull() ?: return null
        if (result.allPoseLandmarks.isEmpty()) return null
        val joints = LANDMARKS.mapNotNull { (joint, type) ->
            result.getPoseLandmark(type)?.let { lm ->
                joint to Point(lm.position.x.toDouble(), lm.position.y.toDouble(), lm.inFrameLikelihood.toDouble())
            }
        }.toMap()
        return PoseSample(Pose(joints), width, height)
    }

    fun detect(bitmap: Bitmap): PoseSample? = detect(InputImage.fromBitmap(bitmap, 0), bitmap.width, bitmap.height)

    override fun close() = detector.close()
}
