package io.github.nahida4479.ripplo.mesh;

import java.nio.charset.StandardCharsets;

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

    static String cardName(byte[] card) {
        if (card == null || card.length < 3 || card[0] != 2) return null;
        int len = card[1] & 0xFF;
        if (len < 1 || 2 + len > card.length) return null;
        String name = new String(card, 2, len, StandardCharsets.UTF_8).replaceAll("[\\p{Cntrl}\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]", "").trim();
        if (name.length() > 40) name = name.substring(0, 40);
        return name.isEmpty() ? null : name;
    }
}
