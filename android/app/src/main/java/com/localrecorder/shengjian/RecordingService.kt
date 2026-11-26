package com.localrecorder.shengjian

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.localrecorder.live.AudioSourceMode

/** Keeps the process in the foreground with the service type matching the active audio capture mode. */
class RecordingService : Service() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLocale.wrapContext(newBase))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            (application as ShengjianApp).controller.stop()
            if (!running) stopSelf(startId)
            return START_NOT_STICKY
        }
        val mode = AudioSourceMode.of(intent?.getStringExtra(EXTRA_AUDIO_MODE))
        val localized = AppLocale.localizedContext(this)
        refreshChannel(localized)
        val notification = notification(
            localized,
            localized.getString(R.string.live_notification_recording),
            localized.getString(notificationTextRes(mode)),
        )
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                    val fgsType = when (mode) {
                        AudioSourceMode.MICROPHONE -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                        AudioSourceMode.SYSTEM_AUDIO -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                        AudioSourceMode.SYSTEM_AND_MIC ->
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    }
                    startForeground(NOTIFICATION_ID, notification, fgsType)
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    if (mode.usesSystemAudio) {
                        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                }
                else -> startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            running = false
            activeMode = null
            (application as ShengjianApp).controller.onForegroundServiceFailed()
            stopSelf(startId)
            return START_NOT_STICKY
        }
        running = true
        activeMode = mode
        (application as ShengjianApp).controller.onForegroundServiceStarted(mode)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        activeMode = null
        (application as ShengjianApp).controller.onRecordingServiceDestroyed()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "live_session"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.localrecorder.shengjian.STOP"
        private const val EXTRA_AUDIO_MODE = "audio_mode"

        // Main thread only.
        private var running = false
        private var activeMode: AudioSourceMode? = null

        fun isRunningFor(mode: AudioSourceMode): Boolean = running && activeMode == mode

        fun start(context: Context, mode: AudioSourceMode = AudioSourceMode.MICROPHONE) {
            val intent = Intent(context, RecordingService::class.java).putExtra(EXTRA_AUDIO_MODE, mode.id)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingService::class.java))
        }

        fun notificationTextRes(mode: AudioSourceMode): Int = when (mode) {
            AudioSourceMode.MICROPHONE -> R.string.live_notification_audio
            AudioSourceMode.SYSTEM_AUDIO -> R.string.live_notification_system_audio
            AudioSourceMode.SYSTEM_AND_MIC -> R.string.live_notification_mixed_audio
        }

        fun refreshChannel(context: Context) {
            val localized = AppLocale.localizedContext(context)
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(CHANNEL, localized.getString(R.string.live_notification_channel), NotificationManager.IMPORTANCE_LOW).apply {
                    description = localized.getString(R.string.live_notification_description)
                }
            )
        }

        /** Replaces the ongoing notification's content; false while the service is not in the foreground. */
        fun update(context: Context, title: String, text: String): Boolean {
            if (!running) return false
            val localized = AppLocale.localizedContext(context)
            context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(localized, title, text))
            return true
        }

        private fun notification(context: Context, title: String, text: String): Notification {
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            val stop = PendingIntent.getService(
                context, 1, Intent(context, RecordingService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(Notification.Action.Builder(null, context.getString(R.string.stop), stop).build())
                .build()
        }
    }
}
