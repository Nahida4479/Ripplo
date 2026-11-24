package io.github.nahida4479.ripplo.mesh

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

internal class StreamLink(
    engine: MeshEngine,
    medium: String,
    outbound: Boolean,
    private val input: InputStream,
    private val output: OutputStream,
    private val closeable: Closeable,
) : Link(engine, medium, outbound) {
    var chunk = 0

    override fun writeFrame(frame: ByteArray) {
        if (chunk <= 0) {
            output.write(frame)
        } else {
            for (o in 0 until frame.size step chunk) output.write(frame, o, minOf(chunk, frame.size - o))
        }
        output.flush()
    }

    override fun closeImpl() {
        try {
            closeable.close()
        } catch (ignored: IOException) {
        }
    }

    fun open() {
        if (!engine.addLink(this)) return
        val t = Thread({
            val buf = ByteArray(8192)
            try {
                var n = input.read(buf)
                while (n > 0) {
                    onBytes(buf, 0, n)
                    n = input.read(buf)
                }
            } catch (ignored: Exception) {
            }
            close()
        }, "ripplo-link-r")
        t.isDaemon = true
        t.start()
    }
}
