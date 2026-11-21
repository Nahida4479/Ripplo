package io.github.nahida4479.ripplo.mesh;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;

public class InstallReceiver extends BroadcastReceiver {
    @Override
    @SuppressWarnings("deprecation")
    public void onReceive(Context ctx, Intent intent) {
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class)
                    : (Intent) intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try {
                    ctx.startActivity(confirm);
                    return;
                } catch (RuntimeException e) {
                    UpdatedReceiver.disarm(ctx);
                    RipploMeshPlugin.installResult(false, -1, "cannot open installer");
                    return;
                }
            }
            return;
        }
        if (status != PackageInstaller.STATUS_SUCCESS) UpdatedReceiver.disarm(ctx);
        RipploMeshPlugin.installResult(status == PackageInstaller.STATUS_SUCCESS, status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
    }
}
