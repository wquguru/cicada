package com.wquguru.cicada

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import cicada.Log
import cicada.Strings.L
import cicada.Strings.LF
import cicada.UpdateChecker

class AppUpdates(private val app: CicadaApp) {
    val checker = UpdateChecker(app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: "0", app.settings.updateLastChecked)
    @Volatile var enabled = !BuildConfig.DEBUG; private set
    @Volatile var manual: String? = null; private set
    private val clearManual = Runnable { manual = null; app.changed() }

    val available get() = if (enabled) checker.available else null

    fun start() {
        checker.onChange {
            app.main.post {
                app.settings.updateLastChecked = checker.lastChecked
                app.settings.save()
                if (checker.available == null) cancelNotification()
                app.changed()
            }
        }
        app.settings.updateNotified?.let { if (!UpdateChecker.isNewer(it, checker.current)) cancelNotification() }
        if (!enabled) return
        schedule()
        checkIfDue(UpdateChecker.STALE)
    }

    fun checkIfDue(age: Long) { if (enabled) app.background.execute { checker.checkIfDue(age) } }

    fun setFeed(feed: String) {
        checker.feed = feed.ifEmpty { UpdateChecker.FEED }
        enabled = true
        schedule()
        Log.d("update: feed set")
    }

    fun checkNow() {
        if (manual == L("正在检查…")) return
        enabled = true
        app.main.removeCallbacks(clearManual)
        manual = L("正在检查…"); app.changed()
        app.background.execute {
            val reached = checker.check()
            app.main.post {
                manual = if (checker.available != null) null else if (reached) L("已是最新版本") else L("连不上 GitHub，请稍后再试")
                app.changed()
                app.main.postDelayed(clearManual, 4000)
            }
        }
    }

    fun download() { available?.let { open(it.apk ?: it.page); Log.d("update: download ${it.version}") } }

    fun openNotes() { available?.let { open(it.page) } }

    private fun open(url: String) {
        try { app.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        catch (e: Exception) { Log.d("update: open failed ${e.javaClass.simpleName}") }
    }

    // MARK: In the background

    private fun schedule() {
        try {
            val js = app.getSystemService(JobScheduler::class.java)
            if (js.getPendingJob(JOB) != null) return
            val r = js.schedule(JobInfo.Builder(JOB, ComponentName(app, UpdateJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(24 * 3600_000L, 6 * 3600_000L)
                .setPersisted(true)
                .build())
            Log.d("update: job scheduled ${r == JobScheduler.RESULT_SUCCESS}")
        } catch (e: Exception) { Log.d("update: job not scheduled ${e.javaClass.simpleName}") }
    }

    fun checkInBackground() {
        if (!enabled) return
        checker.check()
        val u = checker.available ?: return
        app.main.post {
            if (app.settings.updateNotified == u.version) return@post
            if (app.foreground || app.listen.listening) { Log.d("update: ${u.version} not notified now"); return@post }
            notifyAbout(u)
        }
    }

    fun notifyAbout(u: UpdateChecker.Update) {
        val nm = app.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, L("检查更新"), NotificationManager.IMPORTANCE_DEFAULT))
        fun view(code: Int, url: String) = PendingIntent.getActivity(app, code, Intent(Intent.ACTION_VIEW, Uri.parse(url)), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(LF("有新版本 %@", u.version))
            .setContentText(L("点按更新"))
            .setContentIntent(view(10, u.apk ?: u.page))
            .addAction(Notification.Action.Builder(null, L("更新说明"), view(11, u.page)).build())
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFICATION, n)
        app.settings.updateNotified = u.version
        app.settings.save()
        Log.d("update: notified ${u.version}")
    }

    private fun cancelNotification() = app.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)

    companion object {
        const val JOB = 7
        const val NOTIFICATION = 2
        private const val CHANNEL = "updates"
    }
}

class UpdateJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val app = cicada
        app.background.execute {
            app.updates.checkInBackground()
            jobFinished(params, false)
        }
        return true
    }

    override fun onStopJob(params: JobParameters) = true
}
