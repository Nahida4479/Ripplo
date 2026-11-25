package io.github.nahida4479.ripplo.platform

import android.util.Log
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

internal object Diag {
    private const val MAX = 600
    private val lines = ArrayDeque<String>()
    private var added = 0L

    fun i(m: String) {
        add(m)
        Log.i("ripplo", m)
    }

    fun w(m: String) {
        add("! $m")
        Log.w("ripplo", m)
    }

    fun interface StageSink {
        fun onStage(medium: String, node: String, stage: String, detail: String)
    }

    @Volatile
    var sink: StageSink? = null

    fun stage(medium: String, node: String?, stage: String, detail: String?) {
        val n = if (node.isNullOrEmpty()) "-" else node.take(8)
        val d = detail ?: ""
        val suffix = if (d.isEmpty()) "" else " $d"
        add("$medium $n $stage$suffix")
        Log.i("ripplo", "$medium $n $stage $d")
        sink?.onStage(medium, n, stage, d)
    }

    @Synchronized
    private fun add(m: String) {
        if (lines.size >= MAX) lines.removeFirst()
        added++
        lines.addLast(SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date()) + " " + m)
    }

    @Synchronized
    fun mark(): Long = added

    @Synchronized
    fun since(mark: Long): List<String> = lines.toList().takeLast(minOf(added - mark, lines.size.toLong()).toInt())

    @Synchronized
    fun dump(): String = lines.joinToString("") { "$it\n" }

    @Synchronized
    fun clear() {
        lines.clear()
    }
}
