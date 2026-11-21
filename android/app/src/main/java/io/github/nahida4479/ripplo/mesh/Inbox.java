package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

final class Inbox {
    static final int MAX = 2000;

    static final class Item {
        final byte[] packet;
        final String from;
        Item(byte[] packet, String from) { this.packet = packet; this.from = from; }
    }

    private final File file;
    private int count = -1;

    Inbox(Context ctx) {
        file = new File(ctx.getFilesDir(), "mesh_inbox.bin");
    }

    private void load() {
        if (count >= 0) return;
        count = readAll().size();
    }

    private List<Item> readAll() {
        List<Item> out = new ArrayList<>();
        if (!file.exists()) return out;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(file)))) {
            while (true) {
                String from = in.readUTF();
                int n = in.readInt();
                if (n < Packet.HEADER || n > Packet.MAX_PACKET) break;
                byte[] b = new byte[n];
                in.readFully(b);
                out.add(new Item(b, from));
            }
        } catch (IOException ignored) {
        }
        return out;
    }

    synchronized boolean add(byte[] packet, String from) {
        load();
        if (count >= MAX) return false;
        try (DataOutputStream out = new DataOutputStream(new FileOutputStream(file, true))) {
            out.writeUTF(from);
            out.writeInt(packet.length);
            out.write(packet);
            out.flush();
            count++;
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    synchronized List<Item> drain() {
        List<Item> items = readAll();
        file.delete();
        count = 0;
        return items;
    }
}
