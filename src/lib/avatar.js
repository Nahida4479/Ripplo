import { b64, unb64 } from './bytes.js'

export const MAX_AVATAR = 16 * 1024
const SIZE = 160

export function isAvatar(s) {
  if (typeof s !== 'string' || !s || s.length > Math.ceil(MAX_AVATAR * 4 / 3) + 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return false
  try {
    const b = unb64(s)
    return b.length <= MAX_AVATAR && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff
  } catch {
    return false
  }
}

export async function makeAvatar(file) {
  const bmp = await createImageBitmap(file)
  const side = Math.min(bmp.width, bmp.height)
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = SIZE
  canvas.getContext('2d').drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, SIZE, SIZE)
  bmp.close()
  for (let q = 0.85; q > 0.2; q -= 0.15) {
    const blob = await new Promise((r) => canvas.toBlob(r, 'image/jpeg', q))
    const s = b64(new Uint8Array(await blob.arrayBuffer()))
    if (isAvatar(s)) return s
  }
  throw new Error('avatar too large')
}
