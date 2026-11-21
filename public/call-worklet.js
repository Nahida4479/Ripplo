class Capture extends AudioWorkletProcessor {
  constructor(options) {
    super()
    this.size = options.processorOptions.frame
    this.buf = new Float32Array(this.size)
    this.at = 0
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0]
    if (ch) {
      for (let i = 0; i < ch.length; i++) {
        this.buf[this.at++] = ch[i]
        if (this.at === this.size) {
          this.port.postMessage(this.buf.slice())
          this.at = 0
        }
      }
    }
    return true
  }
}

registerProcessor('ripplo-capture', Capture)
