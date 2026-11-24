package io.github.nahida4479.ripplo.mesh

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

internal abstract class Transport(val ctx: Context, val engine: MeshEngine) {
    @Volatile
    var running = false

    @Volatile
    private var isUnsupported = false

    abstract fun name(): String

    @Throws(Exception::class)
    abstract fun startImpl()

    abstract fun stopImpl()

    open fun forceConnect(node: String, option: String): Boolean = false

    open fun tickImpl() {}

    open fun onPeerRequest(kind: Int) {}

    @Synchronized
    fun start() {
        if (running) return
        try {
            startImpl()
            running = true
            log("started")
        } catch (t: Throwable) {
            Diag.w("${name()} start failed: $t")
            if (t is UnsupportedOperationException) isUnsupported = true
            try {
                stopImpl()
            } catch (ignored: Throwable) {
            }
        }
    }

    @Synchronized
    fun stop() {
        running = false
        try {
            stopImpl()
        } catch (ignored: Throwable) {
        }
    }

    @Synchronized
    fun tick() {
        if (!running) {
            if (!isUnsupported) start()
        } else {
            try {
                tickImpl()
            } catch (ignored: Throwable) {
            }
        }
    }

    fun log(m: String) {
        Diag.i("${name()} $m")
    }

    fun unsupported(): Boolean = isUnsupported

    fun has(perm: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED
}
