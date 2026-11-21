import jsQR from 'jsqr'

const MAX_SIDE = 1024
const GAP = 60

export async function startScanner(video, canvas, onCode) {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } }
  })
  const track = stream.getVideoTracks()[0]
  track?.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(() => {})
  video.srcObject = stream
  await video.play().catch(() => {})
  let native = null
  if ('BarcodeDetector' in window) {
    try { native = new window.BarcodeDetector({ formats: ['qr_code'] }) } catch { native = null }
  }
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  let stopped = false
  let timer

  async function scan() {
    if (stopped) return
    try {
      if (video.readyState >= 2 && video.videoWidth) {
        let text = null
        if (native) text = (await native.detect(video))[0]?.rawValue || null
        if (!text) {
          const k = Math.min(1, MAX_SIDE / Math.max(video.videoWidth, video.videoHeight))
          canvas.width = Math.round(video.videoWidth * k)
          canvas.height = Math.round(video.videoHeight * k)
          ctx.drawImage(video, 0, 0, canvas.width, canvas.height)
          const img = ctx.getImageData(0, 0, canvas.width, canvas.height)
          text = jsQR(img.data, img.width, img.height, { inversionAttempts: 'attemptBoth' })?.data || null
        }
        if (text && !stopped) await onCode(text)
      }
    } catch {}
    if (!stopped) timer = setTimeout(scan, GAP)
  }
  scan()

  return () => {
    stopped = true
    clearTimeout(timer)
    stream.getTracks().forEach(x => x.stop())
    video.srcObject = null
  }
}
