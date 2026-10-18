package com.servecoach.app

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.servecoach.analysis.PracticePlan
import java.io.File
import java.util.Calendar

/** Daily practice reminders that say which day of the plan it is. */
object Reminders {
    private const val CHANNEL = "practice"
    internal const val ACTION = "com.servecoach.app.PRACTICE_REMINDER"
    private const val DAY_MS = 24L * 3600 * 1000

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun isOn(context: Context) = prefs(context).getBoolean("reminderOn", false)
    fun hour(context: Context) = prefs(context).getInt("reminderHour", 18)

    /** Turn on a daily reminder at [hour]:00, and start the plan's week today. */
    fun enable(context: Context, hour: Int) {
        val edit = prefs(context).edit().putBoolean("reminderOn", true).putInt("reminderHour", hour)
        // Changing the time keeps the current week; only switching reminders on starts a new one.
        if (!isOn(context)) edit.putLong("planStart", System.currentTimeMillis())
        edit.apply()
        schedule(context)
    }

    fun disable(context: Context) {
        prefs(context).edit().putBoolean("reminderOn", false).apply()
        alarms(context).cancel(intent(context))
    }

    /** Day of the plan (1–7) for [now], counting from when reminders were turned on. */
    fun planDay(context: Context, now: Long = System.currentTimeMillis()): Int {
        val start = prefs(context).getLong("planStart", now)
        return (((now - start) / DAY_MS) % 7).toInt() + 1
    }

    internal fun schedule(context: Context) {
        if (!isOn(context)) return
        val next = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour(context))
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
        }
        // Inexact is fine for a practice nudge and needs no special alarm permission.
        alarms(context).setInexactRepeating(AlarmManager.RTC_WAKEUP, next.timeInMillis, AlarmManager.INTERVAL_DAY, intent(context))
    }

    internal fun notify(context: Context) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Practice reminders", NotificationManager.IMPORTANCE_DEFAULT))
        val plan = PracticePlan.make(SharedHistory.store(context).records)
        val day = plan.days.firstOrNull { it.day == planDay(context) } ?: plan.days.first()
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("Today: ${day.title}")
            .setContentText(day.items.firstOrNull() ?: "Time to practise.")
            .setStyle(NotificationCompat.BigTextStyle().bigText(day.items.joinToString("\n")))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(1, notification)
    }

    private fun alarms(context: Context) = context.getSystemService(AlarmManager::class.java)

    private fun intent(context: Context) = PendingIntent.getBroadcast(
        context, 0, Intent(context, ReminderReceiver::class.java).setAction(ACTION), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

/** Shows the reminder, and re-arms it after a reboot (alarms don't survive one). */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> Reminders.schedule(context)
            Reminders.ACTION -> Reminders.notify(context)
        }
    }
}
