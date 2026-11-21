package io.github.nahida4479.ripplo.mesh;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;

final class Ids {
    private static final String ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    private Ids() { }

    static String ripploId(byte[] tag) {
        StringBuilder out = new StringBuilder();
        int bits = 0;
        int acc = 0;
        for (int i = 0; i < 10 && i < tag.length; i++) {
            acc = (acc << 8) | (tag[i] & 0xFF);
            bits += 8;
            while (bits >= 5) {
                out.append(ALPHABET.charAt((acc >>> (bits - 5)) & 31));
                bits -= 5;
            }
            acc &= (1 << bits) - 1;
        }
        return out.toString();
    }

    static String clean(String s) {
        return s == null ? "" : s.replaceAll("[\\p{Cntrl}\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]", "").trim();
    }

    static String cardName(byte[] card, byte[] tag) {
        if (card == null || card.length < 3 || card[0] != 2) return null;
        int len = card[1] & 0xFF;
        int off = 2 + len;
        if (len < 1 || off + 38 > card.length || card[off] != 2 || card[off + 5] != 5) return null;
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(Arrays.copyOfRange(card, off + 5, off + 38));
            if (!Arrays.equals(Arrays.copyOf(hash, 16), tag)) return null;
        } catch (Exception e) {
            return null;
        }
        String name = clean(new String(card, 2, len, StandardCharsets.UTF_8));
        if (name.length() > 40) name = name.substring(0, 40);
        return name.isEmpty() ? null : name;
    }
}
