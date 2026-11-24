package io.github.nahida4479.ripplo.mesh

import android.content.Context
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

internal class Inbox(ctx: Context) {
    class Item(val packet: ByteArray, val from: String) {
        fun opened(): Boolean = from.startsWith(OPENED)

        fun callId(): String = from.substring(OPENED.length)
    }

    companion object {
        const val MAX = 2000
        private const val RESERVE = 200
        const val OPENED = "~"
        private const val MAX_ITEM = 1 shl 20
    }

    private val file = File(ctx.filesDir, "mesh_inbox.bin")
    private var count = -1

    private fun load() {
        if (count >= 0) return
        count = readAll().size
    }

    private fun readAll(): MutableList<Item> {
        val out = ArrayList<Item>()
        if (!file.exists()) return out
        try {
            DataInputStream(BufferedInputStream(FileInputStream(file))).use { input ->
                while (true) {
                    val from = input.readUTF()
                    val n = input.readInt()
                    if (n < Packet.HEADER || n > MAX_ITEM) break
                    val b = ByteArray(n)
                    input.readFully(b)
                    out.add(Item(b, from))
                }
            }
        } catch (ignored: IOException) {
        }
        return out
    }

    @Synchronized
    fun requeue(item: Item): Boolean = append(item.packet, item.from, MAX)

    @Synchronized
    fun hasRoom(): Boolean {
        load()
        return count < MAX
    }

    @Synchronized
    fun addOpened(sealedPacket: ByteArray, callId: String?): Boolean =
        append(sealedPacket, OPENED + (callId ?: ""), MAX)

    @Synchronized
    fun removeCall(callId: String?) {
        val keep = readAll().filterNot { it.opened() && it.callId() == callId }
        val tmp = File(file.path + ".tmp")
        try {
            DataOutputStream(FileOutputStream(tmp, false)).use { out ->
                for (item in keep) {
                    out.writeUTF(item.from)
                    out.writeInt(item.packet.size)
                    out.write(item.packet)
                }
                out.flush()
            }
        } catch (ignored: IOException) {
            tmp.delete()
            return
        }
        if (tmp.renameTo(file)) count = keep.size else tmp.delete()
    }

    @Synchronized
    fun add(packet: ByteArray, from: String): Boolean = append(packet, from, MAX - RESERVE)

    private fun append(packet: ByteArray, from: String, limit: Int): Boolean {
        load()
        if (count >= limit) return false
        return try {
            DataOutputStream(FileOutputStream(file, true)).use { out ->
                out.writeUTF(from)
                out.writeInt(packet.size)
                out.write(packet)
                out.flush()
                count++
            }
            true
        } catch (ignored: IOException) {
            false
        }
    }

    @Synchronized
    fun drain(): List<Item> {
        val items = readAll()
        file.delete()
        count = 0
        return items
    }
}
