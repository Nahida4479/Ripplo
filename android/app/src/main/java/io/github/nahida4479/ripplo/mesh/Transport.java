package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import androidx.core.content.ContextCompat;

abstract class Transport {
    final Context ctx;
    final MeshEngine engine;
    volatile boolean running;
    private volatile boolean unsupported;

    Transport(Context ctx, MeshEngine engine) {
        this.ctx = ctx;
        this.engine = engine;
    }

    abstract String name();

    abstract void startImpl() throws Exception;

    abstract void stopImpl();

    boolean forceConnect(String node, String option) { return false; }

    void tickImpl() { }

    final synchronized void start() {
        if (running) return;
        try {
            startImpl();
            running = true;
            log("started");
        } catch (Throwable t) {
            Diag.w(name() + " start failed: " + t);
            if (t instanceof UnsupportedOperationException) unsupported = true;
            try { stopImpl(); } catch (Throwable ignored) { }
        }
    }

    final synchronized void stop() {
        running = false;
        try { stopImpl(); } catch (Throwable ignored) { }
    }

    final synchronized void tick() {
        if (!running) { if (!unsupported) start(); }
        else try { tickImpl(); } catch (Throwable ignored) { }
    }

    final void log(String m) {
        Diag.i(name() + " " + m);
    }

    final boolean unsupported() {
        return unsupported;
    }

    final boolean has(String perm) {
        return ContextCompat.checkSelfPermission(ctx, perm) == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }
}
