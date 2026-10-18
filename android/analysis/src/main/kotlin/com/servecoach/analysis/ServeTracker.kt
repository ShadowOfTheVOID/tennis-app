package com.servecoach.analysis

/** The analysed key moments of one serve. */
data class ServeResult(
    val trophyFrame: Frame?,
    val contactFrame: Frame?,
    val trophy: Evaluation?,
    val contact: Evaluation?,
    /** Peak hitting-hand speed around contact, in metres per second (an estimate). */
    val swingSpeed: Double? = null,
    /** +1 when the server faces right in the image, -1 when facing left. */
    val direction: Double = 1.0,
) {
    /** Average of the trophy and contact scores that could be measured. */
    val score: Int?
        get() {
            val scores = listOfNotNull(trophy?.score, contact?.score)
            return if (scores.isEmpty()) null else scores.sum() / scores.size
        }

    val checks: List<Check> get() = (trophy?.checks ?: emptyList()) + (contact?.checks ?: emptyList())

    /** The most useful single thing to work on: the first failing check, then the first warning. */
    val topTip: Check? get() = checks.firstOrNull { it.status == Status.BAD } ?: checks.firstOrNull { it.status == Status.WARN }
}

/**
 * Watches a live stream of poses and reports a [ServeResult] each time a serve finishes,
 * i.e. when the player leaves the contact position.
 */
class ServeTracker(val hand: Handedness, val window: Double = 3.0) {
    private val buffer = ArrayDeque<Frame>()
    private var inContact = false

    fun add(frame: Frame): ServeResult? {
        buffer.addLast(frame)
        while (buffer.first().time < frame.time - window) buffer.removeFirst()

        if (ServeAnalyzer.phase(frame.pose, hand) == Phase.CONTACT) {
            inContact = true
            return null
        }
        if (!inContact) return null
        inContact = false
        val result = ServeAnalyzer.analyze(buffer.toList(), hand)
        buffer.clear()
        return result
    }
}
