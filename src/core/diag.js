const lines = []

let sink = null
export const setDiagSink = f => { sink = f }

export function diagLog(m) {
  const line = new Date().toISOString().slice(11, 23) + ' ' + m
  lines.push(line)
  if (sink) sink('js ' + line)
  if (lines.length > 400) lines.shift()
  console.info('ripplo ' + m)
}

export const diagText = () => lines.join('\n')
export const diagClear = () => { lines.length = 0 }
