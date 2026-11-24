package io.github.nahida4479.ripplo.mesh

import java.security.MessageDigest

internal object Ids {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val CONTROL = Regex("[\\p{Cntrl}\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]")

    fun ripploId(tag: ByteArray): String {
        val out = StringBuilder()
        var bits = 0
        var acc = 0
        for (i in 0 until minOf(10, tag.size)) {
            acc = (acc shl 8) or (tag[i].toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                out.append(ALPHABET[(acc ushr (bits - 5)) and 31])
                bits -= 5
            }
            acc = acc and ((1 shl bits) - 1)
        }
        return out.toString()
    }

    fun clean(s: String?): String = s?.replace(CONTROL, "")?.trim { it <= ' ' } ?: ""

    fun cardName(card: ByteArray?, tag: ByteArray?): String? {
        if (card == null || card.size < 3 || card[0].toInt() != 2) return null
        val len = card[1].toInt() and 0xFF
        val off = 2 + len
        if (len < 1 || off + 38 > card.size || card[off].toInt() != 2 || card[off + 5].toInt() != 5) return null
        try {
            val hash = MessageDigest.getInstance("SHA-256").digest(card.copyOfRange(off + 5, off + 38))
            if (!hash.copyOf(16).contentEquals(tag)) return null
        } catch (e: Exception) {
            return null
        }
        val name = clean(String(card, 2, len, Charsets.UTF_8)).take(40)
        return if (name.isEmpty()) null else name
    }
}
