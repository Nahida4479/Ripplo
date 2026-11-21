import { openDB, deleteDB } from 'idb'
import { utf8, unutf8 } from '../lib/bytes.js'

const STORES = ['kv', 'contacts', 'chats', 'chunks', 'blobs']

export async function openDb(name, vault) {
  const idb = await openDB(name, 1, {
    upgrade(d) {
      for (const s of STORES) d.createObjectStore(s)
      d.createObjectStore('messages', { keyPath: 'id' }).createIndex('chatId', 'chatId')
    },
  })
  const aad = (store, key) => utf8(`${store}/${key}`)
  const putBin = async (store, key, bytes) => { await idb.put(store, await vault.seal(bytes, aad(store, key)), key) }
  const getBin = async (store, key) => {
    const v = await idb.get(store, key)
    return v && vault.open(v, aad(store, key))
  }
  const msgOut = async (m) => ({ id: m.id, chatId: m.chatId, ts: m.ts, d: await vault.seal(utf8(JSON.stringify(m)), aad('messages', m.id)) })
  const msgIn = async (r) => JSON.parse(unutf8(await vault.open(r.d, aad('messages', r.id))))

  return {
    putBin,
    getBin,
    put: (store, key, obj) => putBin(store, key, utf8(JSON.stringify(obj))),
    async get(store, key) {
      const b = await getBin(store, key)
      return b ? JSON.parse(unutf8(b)) : undefined
    },
    del: (store, key) => idb.delete(store, key),
    has: async (store, key) => (await idb.getKey(store, key)) !== undefined,
    hasMsg: async (id) => (await idb.getKey('messages', id)) !== undefined,
    async all(store) {
      const keys = await idb.getAllKeys(store)
      return Promise.all(keys.map(async (k) => [k, JSON.parse(unutf8(await getBin(store, k)))]))
    },
    keysByPrefix: (store, prefix) => idb.getAllKeys(store, IDBKeyRange.bound(`${prefix}/`, `${prefix}/￿`)),
    async putMsg(m) { await idb.put('messages', await msgOut(m)) },
    async msgs(chatId) {
      const rows = await idb.getAllFromIndex('messages', 'chatId', chatId)
      return (await Promise.all(rows.map(msgIn))).sort((a, b) => a.ts - b.ts)
    },
    delMsg: (id) => idb.delete('messages', id),
    close: () => idb.close(),
  }
}

export const destroyDb = (name) => deleteDB(name)
