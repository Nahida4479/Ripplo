package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import androidx.core.content.ContextCompat;

abstract class Transport {
    final Context ctx;
    final MeshEngine engine;
    volatile boolean running;

    Transport(Context ctx, MeshEngine engine) {
        this.ctx = ctx;
        this.engine = engine;
    }

    abstract String name();

    abstract void startImpl() throws Exception;

    abstract void stopImpl();

    void tickImpl() { }

    final synchronized void start() {
        if (running) return;
        try {
            startImpl();
            running = true;
        } catch (Throwable t) {
            try { stopImpl(); } catch (Throwable ignored) { }
        }
    }

    final synchronized void stop() {
        running = false;
        try { stopImpl(); } catch (Throwable ignored) { }
    }

    final synchronized void tick() {
        if (!running) start();
        else try { tickImpl(); } catch (Throwable ignored) { }
    }

    final boolean has(String perm) {
        return ContextCompat.checkSelfPermission(ctx, perm) == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }
}
