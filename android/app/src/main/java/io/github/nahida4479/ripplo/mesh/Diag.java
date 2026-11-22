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

    interface StageSink {
        void onStage(String medium, String node, String stage, String detail);
    }

    static volatile StageSink sink;

    /** Connection step for the developer card: stage is attempt, connecting, connected, linked, rejected, failed, timeout or closed. */
    static void stage(String medium, String node, String stage, String detail) {
        String n = node == null || node.isEmpty() ? "-" : node.substring(0, Math.min(8, node.length()));
        String d = detail == null ? "" : detail;
        add(medium + " " + n + " " + stage + (d.isEmpty() ? "" : " " + d));
        android.util.Log.i("ripplo", medium + " " + n + " " + stage + " " + d);
        StageSink s = sink;
        if (s != null) s.onStage(medium, n, stage, d);
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
