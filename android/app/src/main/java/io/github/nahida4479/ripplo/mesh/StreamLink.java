package io.github.nahida4479.ripplo.mesh;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

final class StreamLink extends Link {
    private final InputStream in;
    private final OutputStream out;
    private final Closeable closeable;
    int chunk;

    StreamLink(MeshEngine engine, String medium, boolean outbound, InputStream in, OutputStream out, Closeable closeable) {
        super(engine, medium, outbound);
        this.in = in;
        this.out = out;
        this.closeable = closeable;
    }

    @Override
    void writeFrame(byte[] frame) throws IOException {
        if (chunk <= 0) out.write(frame);
        else for (int o = 0; o < frame.length; o += chunk) out.write(frame, o, Math.min(chunk, frame.length - o));
        out.flush();
    }

    @Override
    void closeImpl() {
        try { closeable.close(); } catch (IOException ignored) { }
    }

    void open() {
        if (!engine.addLink(this)) return;
        Thread t = new Thread(() -> {
            byte[] buf = new byte[8192];
            try {
                int n;
                while ((n = in.read(buf)) > 0) onBytes(buf, 0, n);
            } catch (Exception ignored) {
            }
            close();
        }, "ripplo-link-r");
        t.setDaemon(true);
        t.start();
    }
}
