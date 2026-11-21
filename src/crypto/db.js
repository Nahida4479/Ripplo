import { openDB, deleteDB } from 'idb'
import { utf8, unutf8 } from '../lib/bytes.js'

const STORES = ['kv', 'contacts', 'chats', 'chunks', 'blobs']
const BATCH_ROWS = 200
const BATCH_BYTES = 4 * 1024 * 1024

const idbRaw = (idb) => {
  const msg = (s) => s === 'messages'
  const get = async (s, k) => {
    const v = await idb.get(s, k)
    return msg(s) ? v?.d : v
  }
  return {
    put: (s, k, v, idx) => (msg(s) ? idb.put(s, { id: k, chatId: idx, d: v }) : idb.put(s, v, k)),
    get,
    del: (s, k) => idb.delete(s, k),
    has: async (s, k) => (await idb.getKey(s, k)) !== undefined,
    keys: (s, prefix) => idb.getAllKeys(s, prefix ? IDBKeyRange.bound(`${prefix}/`, `${prefix}/￿`) : undefined),
    async all(s) {
      const keys = await idb.getAllKeys(s)
      return Promise.all(keys.map(async (k) => [k, await get(s, k)]))
    },
    async byIdx(chatId) {
      return (await idb.getAllFromIndex('messages', 'chatId', chatId)).map((r) => [r.id, r.d])
    },
    close: () => idb.close(),
  }
}

const nativeRaw = (mesh) => ({
  put: (store, key, value, idx) => mesh.dbPut({ store, key, idx, value }),
  get: (store, key) => mesh.dbGet({ store, key }),
  del: (store, key) => mesh.dbDel({ store, key }),
  has: async (store, key) => (await mesh.dbGet({ store, key })) != null,
  keys: (store, prefix) => mesh.dbKeys({ store, prefix }),
  all: async (store) => (await mesh.dbAll({ store })).map((r) => [r.key, r.value]),
  byIdx: async (idx) => (await mesh.dbByIdx({ store: 'messages', idx })).map((r) => [r.key, r.value]),
  close: async () => {},
})

export async function migrateToNative(name, mesh) {
  let fresh = false
  const idb = await openDB(name, 1, { upgrade() { fresh = true } })
  if (fresh) {
    idb.close()
    await deleteDB(name)
    return false
  }
  let total = 0
  let rows = []
  let bytes = 0
  const flush = async () => {
    if (!rows.length) return
    await mesh.dbPutMany({ rows })
    total += rows.length
    rows = []
    bytes = 0
  }
  const push = async (row) => {
    rows.push(row)
    bytes += row.value.length
    if (rows.length >= BATCH_ROWS || bytes >= BATCH_BYTES) await flush()
  }
  try {
    for (const store of [...STORES, 'messages']) {
      for (const key of await idb.getAllKeys(store)) {
        const v = await idb.get(store, key)
        await push(store === 'messages' ? { store, key, idx: v.chatId, value: v.d } : { store, key, value: v })
      }
    }
    await flush()
    if ((await mesh.dbCount()) < total) throw new Error('migration_count')
  } finally {
    idb.close()
  }
  await deleteDB(name)
  return total > 0
}

export async function openDb(name, vault, mesh) {
  let raw
  if (mesh?.isNative) {
    await migrateToNative(name, mesh)
    raw = nativeRaw(mesh)
  } else {
    raw = idbRaw(await openDB(name, 1, {
      upgrade(d) {
        for (const s of STORES) d.createObjectStore(s)
        d.createObjectStore('messages', { keyPath: 'id' }).createIndex('chatId', 'chatId')
      },
    }))
  }
  const aad = (store, key) => utf8(`${store}/${key}`)
  const putBin = async (store, key, bytes, idx) => { await raw.put(store, key, await vault.seal(bytes, aad(store, key)), idx) }
  const open = (store, key, v) => vault.open(v, aad(store, key))
  const getBin = async (store, key) => {
    const v = await raw.get(store, key)
    return v ? open(store, key, v) : v
  }
  const msgIn = async ([id, v]) => JSON.parse(unutf8(await open('messages', id, v)))

  return {
    putBin,
    getBin,
    put: (store, key, obj) => putBin(store, key, utf8(JSON.stringify(obj))),
    async get(store, key) {
      const b = await getBin(store, key)
      return b ? JSON.parse(unutf8(b)) : undefined
    },
    del: (store, key) => raw.del(store, key),
    has: (store, key) => raw.has(store, key),
    hasMsg: (id) => raw.has('messages', id),
    async all(store) {
      return Promise.all((await raw.all(store)).map(async ([k, v]) => [k, JSON.parse(unutf8(await open(store, k, v)))]))
    },
    keysByPrefix: (store, prefix) => raw.keys(store, prefix),
    putMsg: (m) => putBin('messages', m.id, utf8(JSON.stringify(m)), m.chatId),
    async msgs(chatId) {
      return (await Promise.all((await raw.byIdx(chatId)).map(msgIn))).sort((a, b) => a.ts - b.ts)
    },
    delMsg: (id) => raw.del('messages', id),
    close: () => raw.close(),
  }
}

export const destroyDb = (name) => deleteDB(name)
