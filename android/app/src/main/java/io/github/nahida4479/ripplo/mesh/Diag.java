package io.github.nahida4479.ripplo.mesh;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.Date;
import java.util.Locale;

final class Diag {
    private static final int MAX = 600;
    private static final ArrayDeque<String> lines = new ArrayDeque<>();

    private Diag() { }

    static void i(String m) {
        add(m);
        android.util.Log.i("ripplo", m);
    }

    static void w(String m) {
        add("! " + m);
        android.util.Log.w("ripplo", m);
    }

    private static synchronized void add(String m) {
        if (lines.size() >= MAX) lines.removeFirst();
        lines.addLast(new SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(new Date()) + " " + m);
    }

    static synchronized String dump() {
        StringBuilder b = new StringBuilder();
        for (String l : lines) b.append(l).append('\n');
        return b.toString();
    }

    static synchronized void clear() {
        lines.clear();
    }
}
