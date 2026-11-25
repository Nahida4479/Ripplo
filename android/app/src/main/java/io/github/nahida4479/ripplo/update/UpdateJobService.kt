package io.github.nahida4479.ripplo.update

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build

class UpdateJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        val t = Thread({
            try {
                UpdateEngine.background(applicationContext)
            } finally {
                jobFinished(params, false)
            }
        }, "ripplo-update-job")
        t.isDaemon = true
        t.start()
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean = false

    companion object {
        private const val ID = 4201
        private const val PERIOD = 6 * 3600 * 1000L

        fun schedule(ctx: Context) {
            val js = ctx.getSystemService(JobScheduler::class.java) ?: return
            val b = JobInfo.Builder(ID, ComponentName(ctx, UpdateJobService::class.java))
                .setPeriodic(PERIOD)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPersisted(true)
            if (Build.VERSION.SDK_INT >= 26) b.setRequiresBatteryNotLow(true)
            js.schedule(b.build())
        }

        fun cancel(ctx: Context) {
            ctx.getSystemService(JobScheduler::class.java)?.cancel(ID)
        }
    }
}
