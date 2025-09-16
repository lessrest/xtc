import { WASI } from "./wasi.ts"
import wasmUrl from "../zig-out/web-dist/xtc.wasm"

const ctx = self as DedicatedWorkerGlobalScope

type InitMessage = { type: "init"; cols: number; rows: number }
type SwitchDemoMessage = {
  type: "switchDemo"
  demoName: string
  script: string
  cols: number
  rows: number
}
type KeypressMessage = { type: "keypress"; keyCode: number }
type ResizeMessage = { type: "resize"; cols: number; rows: number }
type StopMessage = { type: "stop" }

type WorkerMessage =
  | InitMessage
  | SwitchDemoMessage
  | KeypressMessage
  | ResizeMessage
  | StopMessage

type WorkerResponse =
  | { type: "ready" }
  | { type: "stdout"; buffer: ArrayBuffer }
  | { type: "stderr"; text: string }
  | { type: "session-started"; demoName: string }
  | { type: "session-stopped"; demoName: string }
  | { type: "session-error"; demoName: string; message: string }
  | { type: "error"; message: string }

interface WASIInstance {
  wasi: WASI
  instance: WebAssembly.Instance
}

class XTCWorkerRuntime {
  private wasiInstance: WASIInstance | null = null
  private decoder = new TextDecoder()
  private encoder = new TextEncoder()
  private wasmBytes: ArrayBuffer | null = null
  private terminalCols = 80
  private terminalRows = 30
  private isLiveSession = false
  private animationFrameId: number | null = null
  private currentDemo = ""

  handleMessage = async (event: MessageEvent<WorkerMessage>): Promise<void> => {
    const message = event.data

    try {
      switch (message.type) {
        case "init":
          await this.handleInit(message)
          break
        case "switchDemo":
          await this.handleSwitchDemo(message)
          break
        case "keypress":
          this.handleKeypress(message.keyCode)
          break
        case "resize":
          this.handleResize(message.cols, message.rows)
          break
        case "stop":
          this.handleStop()
          break
      }
    } catch (error) {
      this.emit({
        type: "error",
        message: error instanceof Error ? error.message : String(error)
      })
    }
  }

  private emit(message: WorkerResponse, transfer: Transferable[] = []): void {
    ctx.postMessage(message, transfer)
  }

  private async handleInit(message: InitMessage): Promise<void> {
    this.terminalCols = message.cols
    this.terminalRows = message.rows

    await this.ensureWasmBytes()
    await this.initWASI()

    this.emit({ type: "ready" })
  }

  private async handleSwitchDemo(message: SwitchDemoMessage): Promise<void> {
    this.stopLiveSession()

    this.terminalCols = message.cols
    this.terminalRows = message.rows
    this.currentDemo = message.demoName

    await this.initWASI()

    const result = this.initLiveSession(message.script, message.demoName)
    if (result === 0) {
      this.emit({ type: "session-started", demoName: message.demoName })
    } else {
      this.emit({
        type: "session-error",
        demoName: message.demoName,
        message: `init failed: ${result}`
      })
    }
  }

  private handleKeypress(keyCode: number): void {
    if (!this.isLiveSession || !this.wasiInstance) return

    const keypress = (this.wasiInstance.instance.exports as any).xtc_keypress
    if (typeof keypress === "function") {
      keypress(keyCode)
    }
  }

  private handleResize(cols: number, rows: number): void {
    this.terminalCols = cols
    this.terminalRows = rows

    if (!this.isLiveSession || !this.wasiInstance) return

    const resize = (this.wasiInstance.instance.exports as any).xtc_resize
    if (typeof resize === "function") {
      resize(cols, rows)
    }
  }

  private handleStop(): void {
    const wasLive = this.isLiveSession
    this.stopLiveSession()
    if (wasLive && this.currentDemo) {
      this.emit({ type: "session-stopped", demoName: this.currentDemo })
    }
  }

  private async ensureWasmBytes(): Promise<void> {
    if (this.wasmBytes) return

    const response = await fetch(wasmUrl)
    this.wasmBytes = await response.arrayBuffer()
  }

  private async initWASI(): Promise<void> {
    if (!this.wasmBytes) {
      throw new Error("WASM bytes not loaded")
    }

    const wasi = new WASI({
      stdout: (bytes: Uint8Array) => this.forwardStdout(bytes),
      stderr: (bytes: Uint8Array) => this.forwardStderr(bytes)
    })

    const wasiImports = wasi.getImports()
    const jsImports = {
      env: {
        js_performance_now: () => performance.now()
      }
    }

    const { instance } = await WebAssembly.instantiate(this.wasmBytes, {
      ...wasiImports,
      ...jsImports
    })

    wasi.setMemory(instance.exports.memory as WebAssembly.Memory)

    this.wasiInstance = { wasi, instance }
  }

  private forwardStdout(bytes: Uint8Array): void {
    const copy = bytes.slice()
    this.emit({ type: "stdout", buffer: copy.buffer }, [copy.buffer])
  }

  private forwardStderr(bytes: Uint8Array): void {
    const text = this.decoder.decode(bytes)
    this.emit({ type: "stderr", text })
  }

  private initLiveSession(script: string, moduleName: string): number {
    if (!this.wasiInstance) {
      this.emit({
        type: "session-error",
        demoName: moduleName,
        message: "WASI not available"
      })
      return -1
    }

    const exports = this.wasiInstance.instance.exports as Record<string, any>

    if (typeof exports.xtc_init_session !== "function") {
      this.emit({
        type: "session-error",
        demoName: moduleName,
        message: "xtc_init_session function not found"
      })
      return -1
    }

    const scriptAlloc = this.allocateString(script)
    const moduleAlloc = this.allocateString(moduleName)

    try {
      const result = exports.xtc_init_session(
        scriptAlloc.ptr,
        scriptAlloc.length,
        moduleAlloc.ptr,
        moduleAlloc.length,
        this.terminalCols,
        this.terminalRows
      )

      if (result === 0) {
        this.isLiveSession = true
        this.startAnimationLoop()
      }

      return result
    } finally {
      this.freeMemory(scriptAlloc.ptr, scriptAlloc.length)
      this.freeMemory(moduleAlloc.ptr, moduleAlloc.length)
    }
  }

  private allocateString(str: string): { ptr: number; length: number } {
    if (!this.wasiInstance) {
      throw new Error("WASI instance not initialized")
    }

    const bytes = this.encoder.encode(str)
    const alloc = (this.wasiInstance.instance.exports as any).wasm_alloc
    if (typeof alloc !== "function") {
      throw new Error("wasm_alloc function not found")
    }

    const ptr = alloc(bytes.length)
    if (!ptr) {
      throw new Error("Failed to allocate memory in WASM")
    }

    const memory = new Uint8Array(
      (this.wasiInstance.instance.exports.memory as WebAssembly.Memory).buffer
    )
    memory.set(bytes, ptr)
    return { ptr, length: bytes.length }
  }

  private freeMemory(ptr: number, length: number): void {
    if (!this.wasiInstance) return

    const freeFn = (this.wasiInstance.instance.exports as any).wasm_free
    if (typeof freeFn === "function") {
      freeFn(ptr, length)
    }
  }

  private startAnimationLoop(): void {
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId)
    }

    const animate = () => {
      if (!this.isLiveSession || !this.wasiInstance) {
        return
      }

      const exports = this.wasiInstance.instance.exports as Record<string, any>
      if (typeof exports.xtc_process_frame === "function") {
        const needsRender = exports.xtc_process_frame()

        if (
          needsRender === 1 &&
          typeof exports.xtc_render_frame === "function"
        ) {
          exports.xtc_render_frame()
        } else if (needsRender === -1) {
          this.stopLiveSession()
          if (this.currentDemo) {
            this.emit({
              type: "session-error",
              demoName: this.currentDemo,
              message: "Frame processing error"
            })
          }
          return
        }
      }

      this.animationFrameId = requestAnimationFrame(animate)
    }

    this.animationFrameId = requestAnimationFrame(animate)
  }

  private stopLiveSession(): void {
    this.isLiveSession = false

    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId)
      this.animationFrameId = null
    }

    // if (this.wasiInstance) {
    //   const cleanup = (this.wasiInstance.instance.exports as any).xtc_cleanup
    //   if (typeof cleanup === "function") {
    //     cleanup()
    //   }
    // }
  }
}

const runtime = new XTCWorkerRuntime()
ctx.addEventListener("message", (event) => {
  void runtime.handleMessage(event as MessageEvent<WorkerMessage>)
})
