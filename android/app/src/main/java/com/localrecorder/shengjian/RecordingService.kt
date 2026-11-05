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

/** Keeps the process in the foreground (microphone type) while a session is active. */
class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            (application as ShengjianApp).controller.stop()
            if (!running) stopSelf(startId)
            return START_NOT_STICKY
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(CHANNEL, "实时翻译", NotificationManager.IMPORTANCE_LOW).apply {
                description = "实时翻译进行中时显示"
            }
        )
        val notification = notification(this, DEFAULT_TITLE, DEFAULT_TEXT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val DEFAULT_TITLE = "声笺正在实时翻译"
        const val DEFAULT_TEXT = "麦克风音频正发送到 LiveTranslate 云端服务"
        private const val CHANNEL = "live_session"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.localrecorder.shengjian.STOP"

        // Main thread only.
        private var running = false

        fun start(context: Context) {
            context.startForegroundService(Intent(context, RecordingService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingService::class.java))
        }

        /** Replaces the ongoing notification's content; false while the service is not in the foreground. */
        fun update(context: Context, title: String, text: String): Boolean {
            if (!running) return false
            context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(context, title, text))
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
                .addAction(Notification.Action.Builder(null, "停止", stop).build())
                .build()
        }
    }
}
