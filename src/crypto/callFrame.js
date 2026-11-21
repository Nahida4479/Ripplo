import { concat, u32, readU32 } from '../lib/bytes.js'

const TAG = 1
const MAX_FRAMES = 8
const MAX_OPUS = 1275

export const FRAME_TAG = TAG
export const importCallKey = (raw) => crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt'])

const nonce = (role, seq) => {
  const n = new Uint8Array(12)
  n[0] = role
  n.set(u32(seq), 4)
  return n
}
const aad = (callId, seq) => concat(callId, u32(seq))

export async function sealFrame(key, callId, role, seq, plain) {
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce(role, seq), additionalData: aad(callId, seq) }, key, plain))
  return concat(new Uint8Array([TAG]), callId, u32(seq), ct)
}

export async function openFrame(key, callId, role, packet) {
  if (packet.length < 29 || packet[0] !== TAG) throw new Error('bad_frame')
  for (let i = 0; i < 8; i++) if (packet[1 + i] !== callId[i]) throw new Error('bad_call')
  const seq = readU32(packet, 9)
  const plain = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce(role, seq), additionalData: aad(callId, seq) }, key, packet.subarray(13)))
  return { seq, plain }
}

export function packFrames(frames) {
  if (!frames.length || frames.length > MAX_FRAMES) throw new Error('bad_frames')
  const parts = [new Uint8Array([frames.length])]
  for (const f of frames) {
    if (!f.length || f.length > MAX_OPUS) throw new Error('bad_frames')
    parts.push(new Uint8Array([f.length >> 8, f.length & 255]), f)
  }
  return concat(...parts)
}

export function unpackFrames(b) {
  const n = b[0]
  if (!n || n > MAX_FRAMES) throw new Error('bad_frames')
  const out = []
  let p = 1
  for (let i = 0; i < n; i++) {
    if (p + 2 > b.length) throw new Error('bad_frames')
    const len = (b[p] << 8) | b[p + 1]
    p += 2
    if (!len || len > MAX_OPUS || p + len > b.length) throw new Error('bad_frames')
    out.push(b.subarray(p, p + len))
    p += len
  }
  if (p !== b.length) throw new Error('bad_frames')
  return out
}

export function createReplay(size = 64) {
  let max = -1
  const seen = new Set()
  return {
    accept(seq) {
      if (seq + size <= max || seen.has(seq)) return false
      seen.add(seq)
      if (seq > max) {
        max = seq
        for (const s of seen) if (s + size <= max) seen.delete(s)
      }
      return true
    },
  }
}
