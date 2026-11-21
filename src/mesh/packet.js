export const TYPE = { LINK_HELLO: 1, PING: 2, PONG: 3, DATA: 10, ACK: 11, DEAD_END: 12, DISCOVER: 13, REPLY: 14, APP: 20 }
export const TTL_DEFAULT = 8, HEADER = 36, MAX_PACKET = 65536, ZERO16 = new Uint8Array(16)

export function newId() {
  return crypto.getRandomValues(new Uint8Array(16))
}

export function encodePacket({ type, ttl = TTL_DEFAULT, hops = 0, id = newId(), dest = ZERO16, payload = new Uint8Array() }) {
  if (id.length !== 16 || dest.length !== 16) throw new Error('bad id/dest length')
  if (HEADER + payload.length > MAX_PACKET) throw new Error('packet too large')
  const out = new Uint8Array(HEADER + payload.length)
  out[0] = 1
  out[1] = type
  out[2] = ttl
  out[3] = hops
  out.set(id, 4)
  out.set(dest, 20)
  out.set(payload, HEADER)
  return out
}

export function decodePacket(bytes) {
  if (bytes.length < HEADER) throw new Error('short packet')
  if (bytes.length > MAX_PACKET) throw new Error('packet too large')
  if (bytes[0] !== 1) throw new Error('bad version')
  return {
    type: bytes[1], ttl: bytes[2], hops: bytes[3],
    id: bytes.slice(4, 20), dest: bytes.slice(20, 36), payload: bytes.slice(HEADER),
  }
}
