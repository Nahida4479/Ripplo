package io.github.nahida4479.ripplo.transport.ble.l2cap

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.os.Build
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.StreamLink
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.function.Consumer

internal class BleL2cap(
    private val engine: MeshEngine,
    private val isRunning: () -> Boolean,
    private val lock: Any,
    private val addrNode: ConcurrentHashMap<String, String>,
    private val phyNotes: ConcurrentHashMap<String, String>,
    private val inboundSock: ConcurrentHashMap<String, StreamLink>
) {
    private var server: BluetoothServerSocket? = null
    private val activeDials = HashSet<String>()

    @Volatile
    var psmBytes = byteArrayOf(0, 0)
        private set

    fun startServer(adapter: BluetoothAdapter) {
        val ss = adapter.listenUsingInsecureL2capChannel()
        server = ss
        val psm = ss.psm
        psmBytes = byteArrayOf((psm shr 8).toByte(), psm.toByte())
        Thread({
            try {
                while (isRunning() || server === ss) {
                    val s = ss.accept()
                    openSocket(s, false)
                }
            } catch (ignored: IOException) {
            }
        }, "ripplo-l2cap-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        try { server?.close() } catch (ignored: Exception) { }
        server = null
        synchronized(lock) { activeDials.clear() }
        psmBytes = byteArrayOf(0, 0)
    }

    fun connect(dev: BluetoothDevice, psm: Int, note: String?) {
        val addr = dev.address
        synchronized(lock) { if (!activeDials.add(addr)) return }
        Thread({
            try {
                val s = dev.createInsecureL2capChannel(psm)
                s.connect()
                val sl = openSocket(s, true)
                if (!note.isNullOrEmpty()) sl.note = note
            } catch (e: Exception) {
                Diag.i("l2cap connect failed $addr $e")
            }
            synchronized(lock) { activeDials.remove(addr) }
        }, "ripplo-l2cap-connect").apply {
            isDaemon = true
            start()
        }
    }

    private fun openSocket(s: BluetoothSocket, outbound: Boolean): StreamLink {
        val l = StreamLink(engine, "l2cap", outbound, s.inputStream, s.outputStream, s)
        val mtu = if (Build.VERSION.SDK_INT >= 23) s.maxTransmitPacketSize else 0
        l.chunk = if (mtu > 0) mtu else 672
        val raddr = s.remoteDevice.address
        if (outbound) {
            l.helloHook = Consumer<String> { tag -> addrNode[raddr] = tag }
        } else {
            inboundSock[raddr] = l
            val pn = phyNotes[raddr]
            if (pn != null) l.note = pn
        }
        l.open()
        return l
    }
}
