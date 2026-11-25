package io.github.nahida4479.ripplo.data

import android.content.Context
import android.database.Cursor
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Base64
import java.io.ByteArrayOutputStream

class NativeStore(ctx: Context, name: String) : SQLiteOpenHelper(ctx.applicationContext, name, null, 1) {
    companion object {
        private const val CHUNK = 262144
        private const val COLS = "key, length(value), substr(value, 1, $CHUNK), idx"
        private const val INSERT = "INSERT OR REPLACE INTO rows (store, key, idx, value) VALUES (?, ?, ?, ?)"
    }

    fun interface RowSink {
        @Throws(Exception::class)
        fun row(store: String, key: String, idx: String?, value: ByteArray)
    }

    class Row internal constructor(val key: String, val value: String)

    init {
        setWriteAheadLoggingEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE rows (store TEXT NOT NULL, key TEXT NOT NULL, idx TEXT, value BLOB NOT NULL, PRIMARY KEY (store, key))")
        db.execSQL("CREATE INDEX rows_idx ON rows (store, idx)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
    }

    fun put(store: String, key: String, idx: String?, value: ByteArray) {
        writableDatabase.execSQL(INSERT, arrayOf(store, key, idx, value))
    }

    fun putMany(rows: List<Array<String?>>): Int {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (r in rows) db.execSQL(INSERT, arrayOf(r[0], r[1], r[2], Base64.decode(r[3]!!, Base64.NO_WRAP)))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return rows.size
    }

    fun del(store: String, key: String) {
        writableDatabase.execSQL("DELETE FROM rows WHERE store = ? AND key = ?", arrayOf(store, key))
    }

    private fun value(db: SQLiteDatabase, store: String, key: String, c: Cursor): ByteArray {
        val len = c.getLong(1)
        val first = c.getBlob(2)
        if (len <= CHUNK) return first ?: ByteArray(0)
        val out = ByteArrayOutputStream(minOf(len, (Int.MAX_VALUE - 8).toLong()).toInt())
        out.write(first, 0, first.size)
        var off = first.size.toLong()
        while (off < len) {
            db.rawQuery(
                "SELECT substr(value, ?, ?) FROM rows WHERE store = ? AND key = ?",
                arrayOf((off + 1).toString(), CHUNK.toString(), store, key)
            ).use { p ->
                if (!p.moveToFirst()) throw IllegalStateException("storage")
                val b = p.getBlob(0)
                out.write(b, 0, b.size)
                off += b.size
            }
        }
        return out.toByteArray()
    }

    private fun text(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)

    fun get(store: String, key: String): String? {
        val db = readableDatabase
        return db.rawQuery("SELECT $COLS FROM rows WHERE store = ? AND key = ?", arrayOf(store, key)).use { c ->
            if (c.moveToFirst()) text(value(db, store, key, c)) else null
        }
    }

    fun keys(store: String, prefix: String?): List<String> {
        val out = ArrayList<String>()
        val db = readableDatabase
        var sql = "SELECT key FROM rows WHERE store = ?"
        var args = arrayOf(store)
        if (!prefix.isNullOrEmpty()) {
            sql += " AND key >= ? AND key < ?"
            args = arrayOf(store, "$prefix/", "${prefix}0")
        }
        db.rawQuery("$sql ORDER BY key", args).use { c ->
            while (c.moveToNext()) out.add(c.getString(0))
        }
        return out
    }

    fun all(store: String): List<Row> = query("store = ?", arrayOf(store), store)

    fun byIdx(store: String, idx: String): List<Row> = query("store = ? AND idx = ?", arrayOf(store, idx), store)

    private fun query(where: String, args: Array<String>, store: String): List<Row> {
        val out = ArrayList<Row>()
        val db = readableDatabase
        db.rawQuery("SELECT $COLS FROM rows WHERE $where ORDER BY key", args).use { c ->
            while (c.moveToNext()) out.add(Row(c.getString(0), text(value(db, store, c.getString(0), c))))
        }
        return out
    }

    fun count(): Long = DatabaseUtils.queryNumEntries(readableDatabase, "rows")

    @Throws(Exception::class)
    fun forEachRow(sink: RowSink) {
        val db = readableDatabase
        db.rawQuery("SELECT $COLS, store FROM rows ORDER BY store, key", null).use { c ->
            while (c.moveToNext()) {
                val store = c.getString(4)
                val key = c.getString(0)
                sink.row(store, key, if (c.isNull(3)) null else c.getString(3), value(db, store, key, c))
            }
        }
    }

    @Throws(Exception::class)
    fun replaceAllFrom(src: NativeStore) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM rows")
            src.forEachRow { s, k, i, v -> db.execSQL(INSERT, arrayOf(s, k, i, v)) }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }
}
