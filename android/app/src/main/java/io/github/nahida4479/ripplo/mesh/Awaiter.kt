package io.github.nahida4479.ripplo.mesh

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal class Awaiter {
    private var latch = CountDownLatch(1)

    @Volatile
    private var ok = false

    @Synchronized
    fun reset() {
        latch = CountDownLatch(1)
        ok = false
    }

    fun signal(success: Boolean) {
        ok = success
        val l = synchronized(this) { latch }
        l.countDown()
    }

    fun await(ms: Long): Boolean {
        val l = synchronized(this) { latch }
        return try {
            l.await(ms, TimeUnit.MILLISECONDS) && ok
        } catch (e: InterruptedException) {
            false
        }
    }
}
