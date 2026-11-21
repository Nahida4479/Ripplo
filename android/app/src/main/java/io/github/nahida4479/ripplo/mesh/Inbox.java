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
    private static final int RESERVE = 200;

    static final String OPENED = "~";
    private static final int MAX_ITEM = 1 << 20;

    static final class Item {
        final byte[] packet;
        final String from;
        Item(byte[] packet, String from) { this.packet = packet; this.from = from; }
        boolean opened() { return from.startsWith(OPENED); }
        String callId() { return from.substring(OPENED.length()); }
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
                if (n < Packet.HEADER || n > MAX_ITEM) break;
                byte[] b = new byte[n];
                in.readFully(b);
                out.add(new Item(b, from));
            }
        } catch (IOException ignored) {
        }
        return out;
    }

    synchronized boolean requeue(Item it) {
        return append(it.packet, it.from, MAX);
    }

    synchronized boolean hasRoom() {
        load();
        return count < MAX;
    }

    synchronized boolean addOpened(byte[] sealed, String callId) {
        return append(sealed, OPENED + (callId == null ? "" : callId), MAX);
    }

    synchronized void removeCall(String callId) {
        List<Item> keep = new ArrayList<>();
        for (Item it : readAll()) if (!(it.opened() && it.callId().equals(callId))) keep.add(it);
        File tmp = new File(file.getPath() + ".tmp");
        try (DataOutputStream out = new DataOutputStream(new FileOutputStream(tmp, false))) {
            for (Item it : keep) {
                out.writeUTF(it.from);
                out.writeInt(it.packet.length);
                out.write(it.packet);
            }
            out.flush();
        } catch (IOException e) {
            tmp.delete();
            return;
        }
        if (tmp.renameTo(file)) count = keep.size();
        else tmp.delete();
    }

    synchronized boolean add(byte[] packet, String from) {
        return append(packet, from, MAX - RESERVE);
    }

    private boolean append(byte[] packet, String from, int limit) {
        load();
        if (count >= limit) return false;
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
