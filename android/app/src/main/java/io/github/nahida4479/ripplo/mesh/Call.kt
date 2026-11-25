package io.github.nahida4479.ripplo.mesh

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

internal class Call(private val data: JSONObject, private val result: MethodChannel.Result) {
    private val replied = AtomicBoolean()

    fun getString(name: String): String? = data.opt(name) as? String

    fun getString(name: String, default: String): String = getString(name) ?: default

    fun getBoolean(name: String, default: Boolean): Boolean = data.opt(name) as? Boolean ?: default

    fun getArray(name: String): JSONArray? = data.opt(name) as? JSONArray

    fun getObject(name: String, default: JSONObject): JSONObject = data.opt(name) as? JSONObject ?: default

    fun resolve(o: JSONObject? = null) {
        reply { result.success(o) }
    }

    fun reject(message: String, code: String? = null, details: JSONObject? = null) {
        reply { result.error(code ?: message, message, details) }
    }

    private fun reply(block: () -> Unit) {
        if (!replied.compareAndSet(false, true)) return
        post(block)
    }

    companion object {
        private val MAIN = Handler(Looper.getMainLooper())

        fun post(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) block() else MAIN.post { block() }
        }
    }
}
