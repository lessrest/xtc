import { Terminal } from "@xterm/xterm"
import { WebglAddon } from "@xterm/addon-webgl"

import wavesScript from "../demos/waves.wren" with { type: "text" }
import matrixScript from "../demos/matrix.wren" with { type: "text" }

type WorkerResponse =
  | { type: "ready" }
  | { type: "stdout"; buffer: ArrayBuffer }
  | { type: "stderr"; buffer: ArrayBuffer }
  | { type: "session-started"; demoName: string }
  | { type: "session-stopped"; demoName: string }
  | { type: "session-error"; demoName: string; message: string }
  | { type: "error"; message: string }

class XTCModule {
  private terminal: Terminal | null = null
  private decoder = new TextDecoder()
  private worker: Worker | null = null
  private readyPromise: Promise<void> | null = null
  private readyResolve: (() => void) | null = null
  private readyReject: ((reason?: unknown) => void) | null = null
  private pendingSession: {
    demoName: string
    resolve: () => void
    reject: (reason?: unknown) => void
  } | null = null
  private terminalCols = 80
  private terminalRows = 30
  private isLiveSession = false
  private currentDemo = "waves"
  private keyboardHandlerRegistered = false

  private calculateTerminalSize(): { cols: number; rows: number } {
    const containerElement = document.querySelector('.terminal-wrapper') as HTMLElement
    if (!containerElement) {
      return { cols: 80, rows: 30 }
    }

    const containerWidth = containerElement.clientWidth - 16
    const containerHeight = containerElement.clientHeight - 16
    const baseSize = Math.max(10, Math.min(16, containerWidth / 50))
    const charWidth = baseSize * 0.6
    const charHeight = baseSize * 1.2

    const cols = Math.max(40, Math.floor(containerWidth / charWidth))
    const rows = Math.max(20, Math.floor(containerHeight / charHeight))

    return {
      cols: Math.min(cols, 120),
      rows: Math.min(rows, 50)
    }
  }

  private handleWorkerMessage = (event: MessageEvent<WorkerResponse>): void => {
    const message = event.data

    switch (message.type) {
      case "ready":
        this.readyResolve?.()
        this.readyResolve = null
        this.readyReject = null
        this.readyPromise = null
        break
      case "stdout": {
        if (!this.terminal) break
        const text = this.decoder.decode(new Uint8Array(message.buffer), { stream: true })
        this.terminal.write(text)
        break
      }
      case "stderr":
        console.error("WASM stderr:", this.decoder.decode(new Uint8Array(message.buffer), { stream: true }))
        break
      case "session-started":
        this.isLiveSession = true
        if (this.pendingSession && this.pendingSession.demoName === message.demoName) {
          this.pendingSession.resolve()
          this.pendingSession = null
        }
        break
      case "session-stopped":
        this.isLiveSession = false
        break
      case "session-error":
        this.isLiveSession = false
        if (this.pendingSession && this.pendingSession.demoName === message.demoName) {
          this.pendingSession.reject(new Error(message.message))
          this.pendingSession = null
        }
        console.error(`Session error for ${message.demoName}:`, message.message)
        break
      case "error":
        console.error("Worker error:", message.message)
        this.readyReject?.(new Error(message.message))
        this.readyResolve = null
        this.readyReject = null
        this.readyPromise = null
        if (this.pendingSession) {
          this.pendingSession.reject(new Error(message.message))
          this.pendingSession = null
        }
        break
    }
  }

  async init(): Promise<boolean> {
    try {
      const { cols, rows } = this.calculateTerminalSize()
      this.terminalCols = cols
      this.terminalRows = rows

      const containerElement = document.querySelector('.terminal-wrapper') as HTMLElement
      const fontSize = containerElement ? Math.max(10, Math.min(16, containerElement.clientWidth / 50)) : 14

      this.terminal = new Terminal({
        fontFamily: "'Monaco', 'Menlo', 'Ubuntu Mono', monospace",
        fontSize,
        cols: this.terminalCols,
        rows: this.terminalRows,
        scrollback: 1000,
        theme: {
          background: '#000000',
          foreground: '#00ff00',
          cursor: '#00ff00'
        }
      })

      this.terminal.open(document.getElementById("terminal")!)

      try {
        const webglAddon = new WebglAddon()
        this.terminal.loadAddon(webglAddon)
        console.log("WebGL renderer enabled for xterm.js")
      } catch (error) {
        console.warn("WebGL renderer not available, falling back to canvas:", error)
      }

      this.setupKeyboardInput()

      const workerPath = process.env.XTC_WORKER!

      this.worker = new Worker(new URL(workerPath, import.meta.url), {
        type: "module"
      })
      this.worker.addEventListener("message", this.handleWorkerMessage)
      this.worker.addEventListener("error", (event) => {
        console.error("Worker runtime error:", event.message)
        this.readyReject?.(event.error ?? event.message)
      })

      this.readyPromise = new Promise((resolve, reject) => {
        this.readyResolve = resolve
        this.readyReject = reject
      })

      this.worker.postMessage({
        type: "init",
        cols: this.terminalCols,
        rows: this.terminalRows
      })

      await this.readyPromise

      return true
    } catch (error) {
      console.error("Failed to initialize XTC module:", error)
      return false
    }
  }

  private stopLiveSession(): void {
    this.isLiveSession = false
    if (this.worker) {
      this.worker.postMessage({ type: "stop" })
    }
  }

  async switchDemo(demoName: string): Promise<void> {
    console.log(`Switching to demo: ${demoName}`)

    if (!this.worker) {
      throw new Error("Worker not initialized")
    }

    this.stopLiveSession()

    if (this.terminal) {
      this.terminal.clear()
    }

    this.currentDemo = demoName

    let script: string
    switch (demoName) {
      case "matrix":
        script = matrixScript
        break
      default:
        script = wavesScript
        break
    }

    await new Promise<void>((resolve, reject) => {
      this.pendingSession = { demoName, resolve, reject }
      this.worker!.postMessage({
        type: "switchDemo",
        demoName,
        script,
        cols: this.terminalCols,
        rows: this.terminalRows
      })
    })
  }

  handleResize(): void {
    if (!this.terminal) return

    const { cols, rows } = this.calculateTerminalSize()

    if (cols !== this.terminalCols || rows !== this.terminalRows) {
      this.terminalCols = cols
      this.terminalRows = rows

      this.terminal.resize(cols, rows)

      if (this.worker) {
        this.worker.postMessage({ type: "resize", cols, rows })
      }
    }
  }

  private setupKeyboardInput(): void {
    if (!this.terminal || this.keyboardHandlerRegistered) return
    this.keyboardHandlerRegistered = true

    this.terminal.onKey(({ key, domEvent }) => {
      if (!this.worker || !this.isLiveSession) return

      let keyCode: number
      if (domEvent.key === "Enter") {
        keyCode = 13
      } else if (domEvent.key === "Backspace") {
        keyCode = 127
      } else if (domEvent.key === "Tab") {
        keyCode = 9
      } else if (domEvent.key === "Escape") {
        keyCode = 27
      } else if (key.length === 1) {
        keyCode = key.charCodeAt(0)
      } else {
        return
      }

      this.worker.postMessage({ type: "keypress", keyCode })
    })
  }
}

async function init(): Promise<void> {
  const xtc = new XTCModule()
  const success = await xtc.init()

  if (!success) {
    console.error("Failed to load WASM module")
    return
  }

  const tabs = document.querySelectorAll('.tab')
  tabs.forEach(tab => {
    tab.addEventListener('click', async (e) => {
      const target = e.target as HTMLButtonElement
      const demoName = target.dataset.demo

      if (!demoName) return

      console.log("Tab clicked:", demoName)
      tabs.forEach(t => (t as HTMLButtonElement).disabled = true)
      tabs.forEach(t => t.classList.remove('active'))
      target.classList.add('active')

      try {
        await xtc.switchDemo(demoName)
      } catch (error) {
        console.error("Failed to switch demo:", error)
      }

      tabs.forEach(t => (t as HTMLButtonElement).disabled = false)
    })
  })

  let resizeTimeout: number
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimeout)
    resizeTimeout = window.setTimeout(() => {
      xtc.handleResize()
    }, 250)
  })

  await xtc.switchDemo('waves')
}

init().catch(console.error)
