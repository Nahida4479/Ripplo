import { openDB } from 'idb'
import 'fake-indexeddb/auto'
import { describe, it, expect } from 'vitest'
import { openDb, migrateToNative } from '../src/crypto/db.js'
import { createVault } from '../src/crypto/vault.js'
import { random, hex } from '../src/lib/bytes.js'

function fakeNative() {
  const rows = new Map()
  const k = (s, key) => `${s}\0${key}`
  const m = {
    isNative: true,
    rows,
    batches: [],
    getDbKey: async () => ({ key: KEY, insecure: false }),
    dbCount: async () => rows.size,
    dbPut: async ({ store, key, idx, value }) => { rows.set(k(store, key), { store, key, idx, value }) },
    dbPutMany: async ({ rows: list }) => { m.batches.push(list.length); for (const r of list) rows.set(k(r.store, r.key), r); return { count: list.length } },
    dbGet: async ({ store, key }) => rows.get(k(store, key))?.value ?? null,
    dbDel: async ({ store, key }) => { rows.delete(k(store, key)) },
    dbKeys: async ({ store, prefix }) => [...rows.values()].filter((r) => r.store === store && (!prefix || r.key.startsWith(`${prefix}/`))).map((r) => r.key),
    dbAll: async ({ store }) => [...rows.values()].filter((r) => r.store === store),
    dbByIdx: async ({ store, idx }) => [...rows.values()].filter((r) => r.store === store && r.idx === idx),
  }
  return m
}
const KEY = random(32)
const web = { isNative: false, getDbKey: async () => ({ key: KEY, insecure: false }) }
const exists = async (name) => (await indexedDB.databases()).some((d) => d.name === name)

describe('native store', () => {
  it('migrates sealed IndexedDB records without decrypting, in batches, then deletes the database', async () => {
    const name = `mig-${hex(random(4))}`
    const vault = await createVault(web)
    const old = await openDb(name, vault, web)
    await old.put('kv', 'profile', { name: 'A' })
    await old.putBin('blobs', 'b1', new Uint8Array([1, 2, 3]))
    for (let i = 0; i < 450; i++) await old.putBin('chunks', `x/${i}`, new Uint8Array([i % 256]))
    await old.putMsg({ id: 'm1', chatId: 'c1', ts: 2, text: 'second' })
    await old.putMsg({ id: 'm2', chatId: 'c1', ts: 1, text: 'first' })
    await old.putMsg({ id: 'm3', chatId: 'c2', ts: 1, text: 'other' })
    await old.close()
    const native = fakeNative()
    native.getDbKey = async () => ({ key: KEY, insecure: false })
    expect(await migrateToNative(name, native)).toBe(true)
    expect(native.rows.size).toBe(1 + 1 + 450 + 3)
    expect(Math.max(...native.batches)).toBeLessThanOrEqual(200)
    expect(await exists(name)).toBe(false)
    const db = await openDb(name, vault, native)
    expect(await db.get('kv', 'profile')).toEqual({ name: 'A' })
    expect(await db.getBin('blobs', 'b1')).toEqual(new Uint8Array([1, 2, 3]))
    expect((await db.msgs('c1')).map((m) => m.text)).toEqual(['first', 'second'])
    expect((await db.keysByPrefix('chunks', 'x')).length).toBe(450)
    expect(await db.hasMsg('m3')).toBe(true)
    await db.delMsg('m3')
    expect(await db.hasMsg('m3')).toBe(false)
    expect(await db.has('kv', 'profile')).toBe(true)
    expect((await db.all('kv')).map(([key]) => key)).toEqual(['profile'])
  })

  it('resumes an interrupted migration and is a no-op without IndexedDB', async () => {
    const native = fakeNative()
    const name = `mig-${hex(random(4))}`
    const old = await openDb(name, await createVault(web), web)
    await old.put('kv', 'a', 1)
    await old.put('kv', 'b', 2)
    await old.close()
    const partial = await openDB(name, 1)
    await native.dbPut({ store: 'kv', key: 'a', value: await partial.get('kv', 'a') })
    partial.close()
    expect(await migrateToNative(name, native)).toBe(true)
    expect(native.rows.size).toBe(2)
    expect(await exists(name)).toBe(false)
    const empty = fakeNative()
    expect(await migrateToNative(`none-${hex(random(4))}`, empty)).toBe(false)
    expect(empty.rows.size).toBe(0)
  })
})
