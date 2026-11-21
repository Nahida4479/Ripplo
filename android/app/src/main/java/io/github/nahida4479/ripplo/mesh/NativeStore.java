package io.github.nahida4479.ripplo.mesh;

import android.content.Context;
import android.database.Cursor;
import android.util.Base64;
import android.database.DatabaseUtils;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

public final class NativeStore extends SQLiteOpenHelper {
    private static final int CHUNK = 262144;
    private static final String COLS = "key, length(value), substr(value, 1, " + CHUNK + "), idx";

    public interface RowSink {
        void row(String store, String key, String idx, byte[] value) throws Exception;
    }

    public static final class Row {
        public final String key;
        public final String value;

        Row(String key, String value) {
            this.key = key;
            this.value = value;
        }
    }

    public NativeStore(Context ctx, String name) {
        super(ctx.getApplicationContext(), name, null, 1);
        setWriteAheadLoggingEnabled(true);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE rows (store TEXT NOT NULL, key TEXT NOT NULL, idx TEXT, value BLOB NOT NULL, PRIMARY KEY (store, key))");
        db.execSQL("CREATE INDEX rows_idx ON rows (store, idx)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
    }

    private static final String INSERT = "INSERT OR REPLACE INTO rows (store, key, idx, value) VALUES (?, ?, ?, ?)";

    public void put(String store, String key, String idx, byte[] value) {
        getWritableDatabase().execSQL(INSERT, new Object[]{store, key, idx, value});
    }

    public int putMany(List<String[]> rows) {
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            for (String[] r : rows) db.execSQL(INSERT, new Object[]{r[0], r[1], r[2], Base64.decode(r[3], Base64.NO_WRAP)});
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
        }
        return rows.size();
    }

    public void del(String store, String key) {
        getWritableDatabase().execSQL("DELETE FROM rows WHERE store = ? AND key = ?", new Object[]{store, key});
    }

    private byte[] value(SQLiteDatabase db, String store, String key, Cursor c) {
        long len = c.getLong(1);
        byte[] first = c.getBlob(2);
        if (len <= CHUNK) return first == null ? new byte[0] : first;
        ByteArrayOutputStream out = new ByteArrayOutputStream((int) Math.min(len, Integer.MAX_VALUE - 8));
        out.write(first, 0, first.length);
        long off = first.length;
        while (off < len) {
            try (Cursor p = db.rawQuery("SELECT substr(value, ?, ?) FROM rows WHERE store = ? AND key = ?",
                    new String[]{Long.toString(off + 1), Integer.toString(CHUNK), store, key})) {
                if (!p.moveToFirst()) throw new IllegalStateException("storage");
                byte[] b = p.getBlob(0);
                out.write(b, 0, b.length);
                off += b.length;
            }
        }
        return out.toByteArray();
    }

    private static String text(byte[] b) {
        return Base64.encodeToString(b, Base64.NO_WRAP);
    }

    public String get(String store, String key) {
        SQLiteDatabase db = getReadableDatabase();
        try (Cursor c = db.rawQuery("SELECT " + COLS + " FROM rows WHERE store = ? AND key = ?", new String[]{store, key})) {
            return c.moveToFirst() ? text(value(db, store, key, c)) : null;
        }
    }

    public List<String> keys(String store, String prefix) {
        List<String> out = new ArrayList<>();
        SQLiteDatabase db = getReadableDatabase();
        String sql = "SELECT key FROM rows WHERE store = ?";
        String[] args = {store};
        if (prefix != null && !prefix.isEmpty()) {
            sql += " AND key >= ? AND key < ?";
            args = new String[]{store, prefix + "/", prefix + "0"};
        }
        try (Cursor c = db.rawQuery(sql + " ORDER BY key", args)) {
            while (c.moveToNext()) out.add(c.getString(0));
        }
        return out;
    }

    public List<Row> all(String store) {
        return query("store = ?", new String[]{store}, store);
    }

    public List<Row> byIdx(String store, String idx) {
        return query("store = ? AND idx = ?", new String[]{store, idx}, store);
    }

    private List<Row> query(String where, String[] args, String store) {
        List<Row> out = new ArrayList<>();
        SQLiteDatabase db = getReadableDatabase();
        try (Cursor c = db.rawQuery("SELECT " + COLS + " FROM rows WHERE " + where + " ORDER BY key", args)) {
            while (c.moveToNext()) out.add(new Row(c.getString(0), text(value(db, store, c.getString(0), c))));
        }
        return out;
    }

    public long count() {
        return DatabaseUtils.queryNumEntries(getReadableDatabase(), "rows");
    }

    public void forEachRow(RowSink sink) throws Exception {
        SQLiteDatabase db = getReadableDatabase();
        try (Cursor c = db.rawQuery("SELECT " + COLS + ", store FROM rows ORDER BY store, key", null)) {
            while (c.moveToNext()) {
                String store = c.getString(4);
                String key = c.getString(0);
                sink.row(store, key, c.isNull(3) ? null : c.getString(3), value(db, store, key, c));
            }
        }
    }

    public void replaceAllFrom(NativeStore src) throws Exception {
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            db.execSQL("DELETE FROM rows");
            src.forEachRow((s, k, i, v) -> db.execSQL(INSERT, new Object[]{s, k, i, v}));
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
        }
    }
}
