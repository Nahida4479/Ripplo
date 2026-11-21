package io.github.nahida4479.ripplo.mesh;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

final class Awaiter {
    private CountDownLatch latch = new CountDownLatch(1);
    private volatile boolean ok;

    synchronized void reset() {
        latch = new CountDownLatch(1);
        ok = false;
    }

    void signal(boolean success) {
        ok = success;
        CountDownLatch l;
        synchronized (this) { l = latch; }
        l.countDown();
    }

    boolean await(long ms) {
        CountDownLatch l;
        synchronized (this) { l = latch; }
        try {
            return l.await(ms, TimeUnit.MILLISECONDS) && ok;
        } catch (InterruptedException e) {
            return false;
        }
    }
}
