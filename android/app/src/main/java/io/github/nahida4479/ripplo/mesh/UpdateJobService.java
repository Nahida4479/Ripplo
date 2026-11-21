package io.github.nahida4479.ripplo.mesh;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.Build;

public class UpdateJobService extends JobService {
    private static final int ID = 4201;
    private static final long PERIOD = 6 * 3600 * 1000L;

    static void schedule(Context ctx) {
        JobScheduler js = ctx.getSystemService(JobScheduler.class);
        if (js == null) return;
        JobInfo.Builder b = new JobInfo.Builder(ID, new ComponentName(ctx, UpdateJobService.class))
                .setPeriodic(PERIOD)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPersisted(true);
        if (Build.VERSION.SDK_INT >= 26) b.setRequiresBatteryNotLow(true);
        js.schedule(b.build());
    }

    static void cancel(Context ctx) {
        JobScheduler js = ctx.getSystemService(JobScheduler.class);
        if (js != null) js.cancel(ID);
    }

    @Override
    public boolean onStartJob(final JobParameters params) {
        Thread t = new Thread(() -> {
            try {
                UpdateEngine.background(getApplicationContext());
            } finally {
                jobFinished(params, false);
            }
        }, "ripplo-update-job");
        t.setDaemon(true);
        t.start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return false;
    }
}
