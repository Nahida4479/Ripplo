const lines = []

export function diagLog(m) {
  lines.push(new Date().toISOString().slice(11, 23) + ' ' + m)
  if (lines.length > 400) lines.shift()
  console.info('ripplo ' + m)
}

export const diagText = () => lines.join('\n')
export const diagClear = () => { lines.length = 0 }
