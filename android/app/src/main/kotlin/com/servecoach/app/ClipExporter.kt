package com.servecoach.app

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.core.content.FileProvider
import com.servecoach.analysis.Joint
import com.servecoach.analysis.ShareClip
import java.io.File
import kotlin.math.min

/** Renders a stroke's replay into a shareable MP4 with the skeleton and scores drawn on. */
object ClipExporter {
    private const val WIDTH = 720
    private const val HEIGHT = 960
    private const val TIMEOUT_US = 10_000L

    /** Encode the clip into the app's cache. Slow (a few seconds): call off the main thread. */
    fun export(context: Context, stroke: ReviewedStroke): File {
        val source = stroke.replay.ifEmpty {
            stroke.result.keyFrames.mapNotNull { key ->
                stroke.images[key.phase]?.let { ReplayFrame(key.frame.time, it, stroke.samples[key.phase]) }
            }
        }
        require(source.isNotEmpty()) { "Nothing to export" }
        val dir = File(context.cacheDir, "clips").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // keep only the latest clip
        val file = File(dir, "${stroke.result.type.key}-${System.currentTimeMillis()}.mp4")

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, 4_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, ShareClip.FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val canvasBitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(WIDTH * HEIGHT)
        var track = -1
        val info = MediaCodec.BufferInfo()

        fun drain(endOfStream: Boolean) {
            while (true) {
                val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer.addTrack(codec.outputFormat); muxer.start() }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && track >= 0) muxer.writeSampleData(track, buffer, info)
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val order = ShareClip.frames(source.map { it.time })
            val canvas = Canvas(canvasBitmap)
            order.forEachIndexed { n, i ->
                draw(canvas, stroke, source[i])
                canvasBitmap.getPixels(pixels, 0, WIDTH, 0, 0, WIDTH, HEIGHT)
                var input: Int
                do { input = codec.dequeueInputBuffer(TIMEOUT_US); if (input < 0) drain(false) } while (input < 0)
                writeYuv(codec.getInputImage(input)!!, pixels)
                codec.queueInputBuffer(input, 0, WIDTH * HEIGHT * 3 / 2, n * 1_000_000L / ShareClip.FPS, 0)
                drain(false)
            }
            var input: Int
            do { input = codec.dequeueInputBuffer(TIMEOUT_US); if (input < 0) drain(false) } while (input < 0)
            codec.queueInputBuffer(input, 0, 0, order.size * 1_000_000L / ShareClip.FPS, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drain(true)
        } finally {
            runCatching { codec.stop() }
            codec.release()
            runCatching { if (track >= 0) muxer.stop() }
            muxer.release()
            canvasBitmap.recycle()
        }
        return file
    }

    /** Open the share sheet for an exported clip. */
    fun share(context: Context, file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.clips", file)
        val send = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, "Share clip").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textSize = 40f; isFakeBoldText = true }
    private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textSize = 28f }
    private val band = Paint().apply { color = android.graphics.Color.argb(150, 0, 0, 0) }
    private val bone = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.GREEN; strokeWidth = 6f; strokeCap = Paint.Cap.ROUND
    }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE }

    private fun draw(canvas: Canvas, stroke: ReviewedStroke, frame: ReplayFrame) {
        canvas.drawColor(android.graphics.Color.BLACK)
        // Fit the frame into the 3:4 canvas.
        val image = frame.image
        val scale = min(WIDTH.toFloat() / image.width, HEIGHT.toFloat() / image.height)
        val dx = (WIDTH - image.width * scale) / 2
        val dy = (HEIGHT - image.height * scale) / 2
        canvas.drawBitmap(image, null, RectF(dx, dy, dx + image.width * scale, dy + image.height * scale), null)

        frame.sample?.let { s ->
            // The pose is in the coordinates of the image it was detected on, which may differ in size.
            val sx = image.width * scale / s.imageWidth
            val sy = image.height * scale / s.imageHeight
            fun at(j: Joint) = s.pose[j]?.let { (it.x * sx + dx).toFloat() to (it.y * sy + dy).toFloat() }
            for ((a, b) in BONES) {
                val pa = at(a) ?: continue
                val pb = at(b) ?: continue
                canvas.drawLine(pa.first, pa.second, pb.first, pb.second, bone)
            }
            for (j in Joint.entries) at(j)?.let { canvas.drawCircle(it.first, it.second, 7f, dot) }
        }

        val result = stroke.result
        canvas.drawRect(0f, 0f, WIDTH.toFloat(), 130f, band)
        canvas.drawText(ShareClip.title(result), 28f, 58f, text)
        ShareClip.caption(result, frame.time)?.let { canvas.drawText(it, 28f, 108f, small) }
        canvas.drawRect(0f, HEIGHT - 110f, WIDTH.toFloat(), HEIGHT.toFloat(), band)
        canvas.drawText(ellipsize(ShareClip.footer(result), small, WIDTH - 56f), 28f, HEIGHT - 62f, small)
        canvas.drawText("Serve Coach · ¼ speed", 28f, HEIGHT - 24f, small.apply { alpha = 170 })
        small.alpha = 255
    }

    private fun ellipsize(s: String, paint: Paint, width: Float): String {
        if (paint.measureText(s) <= width) return s
        var end = s.length
        while (end > 0 && paint.measureText(s.substring(0, end) + "…") > width) end--
        return s.substring(0, end) + "…"
    }

    /** ARGB pixels to the encoder's YUV 4:2:0 image, whatever its plane layout. */
    private fun writeYuv(image: android.media.Image, argb: IntArray) {
        val (yPlane, uPlane, vPlane) = image.planes
        val yBuf = yPlane.buffer
        val row = ByteArray(WIDTH)
        for (y in 0 until HEIGHT) {
            for (x in 0 until WIDTH) {
                val c = argb[y * WIDTH + x]
                val r = c shr 16 and 0xFF; val g = c shr 8 and 0xFF; val b = c and 0xFF
                row[x] = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte()
            }
            if (yPlane.pixelStride == 1) { yBuf.position(y * yPlane.rowStride); yBuf.put(row) }
            else for (x in 0 until WIDTH) yBuf.put(y * yPlane.rowStride + x * yPlane.pixelStride, row[x])
        }
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        for (y in 0 until HEIGHT / 2) {
            for (x in 0 until WIDTH / 2) {
                val c = argb[(y * 2) * WIDTH + x * 2]
                val r = c shr 16 and 0xFF; val g = c shr 8 and 0xFF; val b = c and 0xFF
                val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                uBuf.put(y * uPlane.rowStride + x * uPlane.pixelStride, u.toByte())
                vBuf.put(y * vPlane.rowStride + x * vPlane.pixelStride, v.toByte())
            }
        }
    }
}
