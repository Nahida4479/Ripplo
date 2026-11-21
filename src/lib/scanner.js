import jsQR from 'jsqr'

const MAX_SIDE = 1280
const GAP = 60
const OPTIONS = { formats: ['QRCode'], tryHarder: true, tryRotate: true, tryInvert: true, maxNumberOfSymbols: 1 }

let loading = null
function loadReader() {
  loading ??= (async () => {
    const [{ readBarcodes, setZXingModuleOverrides }, { default: wasm }] = await Promise.all([
      import('zxing-wasm/reader'),
      import('zxing-wasm/reader/zxing_reader.wasm?url'),
    ])
    setZXingModuleOverrides({ locateFile: (path, prefix) => (path.endsWith('.wasm') ? wasm : prefix + path) })
    return readBarcodes
  })().catch(() => null)
  return loading
}

export async function startScanner(video, canvas, onCode) {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
  })
  const track = stream.getVideoTracks()[0]
  track?.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(() => {})
  video.srcObject = stream
  await video.play().catch(() => {})
  let native = null
  if ('BarcodeDetector' in window) {
    try { native = new window.BarcodeDetector({ formats: ['qr_code'] }) } catch { native = null }
  }
  let reader = null
  loadReader().then((r) => { reader = r })
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  let stopped = false
  let timer

  async function scan() {
    if (stopped) return
    try {
      if (video.readyState >= 2 && video.videoWidth) {
        let text = null
        if (native) {
          try { text = (await native.detect(video))[0]?.rawValue || null } catch { native = null }
        }
        if (!text) {
          const k = Math.min(1, MAX_SIDE / Math.max(video.videoWidth, video.videoHeight))
          canvas.width = Math.round(video.videoWidth * k)
          canvas.height = Math.round(video.videoHeight * k)
          ctx.drawImage(video, 0, 0, canvas.width, canvas.height)
          const img = ctx.getImageData(0, 0, canvas.width, canvas.height)
          if (reader) text = (await reader(img, OPTIONS))[0]?.text || null
          else text = jsQR(img.data, img.width, img.height, { inversionAttempts: 'attemptBoth' })?.data || null
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
