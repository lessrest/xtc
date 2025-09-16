import { WASI } from "./wasi.ts"
import wasmUrl from "../zig-out/web-dist/xtc.wasm"

const ctx = self as DedicatedWorkerGlobalScope

const WASM_MEMORY_INITIAL_PAGES = 260
const WASM_MEMORY_MAX_PAGES = 260 * 32

type ThreadWorkerMessage =
  | { type: "thread-exit"; tid: number }
  | { type: "stdout"; tid: number; buffer: ArrayBuffer }
  | { type: "stderr"; tid: number; buffer: ArrayBuffer }
  | { type: "thread-error"; tid: number; message: string }

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
  | { type: "stderr"; buffer: ArrayBuffer }
  | { type: "session-started"; demoName: string }
  | { type: "session-stopped"; demoName: string }
  | { type: "session-error"; demoName: string; message: string }
  | { type: "error"; message: string }

interface WASIInstance {
  wasi: WASI
  instance: WebAssembly.Instance
}

interface ThreadManagerCallbacks {
  onStdout(bytes: Uint8Array): void
  onStderr(bytes: Uint8Array): void
}

class ThreadManager {
  private workers = new Map<number, Worker>()
  private nextThreadId = 1
  private memory: WebAssembly.Memory | null = null

  constructor(
    private readonly module: WebAssembly.Module,
    private readonly callbacks: ThreadManagerCallbacks
  ) {}

  setMemory(memory: WebAssembly.Memory): void {
    if (!(memory.buffer instanceof SharedArrayBuffer)) {
      console.warn("WASM memory is not shared; threads are unavailable")
      this.memory = null
      return
    }

    this.memory = memory
  }

  spawnThread(argPtr: number): number {
    if (!this.memory) {
      console.warn("Cannot spawn thread without shared memory")
      return -1
    }

    try {
      const tid = this.nextThreadId++
      const worker = new Worker(
        new URL(process.env.THREAD_WORKER!, import.meta.url),
        { type: "module" }
      )

      worker.addEventListener("message", (event) => {
        this.handleThreadMessage(
          tid,
          event as MessageEvent<ThreadWorkerMessage>
        )
      })

      worker.addEventListener("error", (event) => {
        console.error(
          `Thread worker ${tid} error:`,
          event.error ?? event.message
        )
      })

      worker.postMessage({
        type: "start-thread",
        tid,
        argPtr,
        module: this.module,
        memory: this.memory
      })

      this.workers.set(tid, worker)
      return tid
    } catch (error) {
      console.error("Failed to spawn WASM thread", error)
      return -1
    }
  }

  dispose(): void {
    for (const worker of this.workers.values()) {
      worker.terminate()
    }
    this.workers.clear()
    this.memory = null
    this.nextThreadId = 1
  }

  private handleThreadMessage(
    tid: number,
    event: MessageEvent<ThreadWorkerMessage>
  ): void {
    const message = event.data

    switch (message.type) {
      case "stdout": {
        const bytes = new Uint8Array(message.buffer)
        this.callbacks.onStdout(bytes)
        break
      }
      case "stderr": {
        const bytes = new Uint8Array(message.buffer)
        this.callbacks.onStderr(bytes)
        break
      }
      case "thread-exit": {
        const worker = this.workers.get(tid)
        if (worker) {
          worker.terminate()
        }
        this.workers.delete(tid)
        break
      }
      case "thread-error": {
        console.error(
          `Thread ${message.tid} reported error: ${message.message}`
        )
        const worker = this.workers.get(message.tid)
        if (worker) {
          worker.terminate()
          this.workers.delete(message.tid)
        }
        break
      }
    }
  }
}

class XTCWorkerRuntime {
  private wasiInstance: WASIInstance | null = null
  private decoder = new TextDecoder()
  private encoder = new TextEncoder()
  private wasmBytes: ArrayBuffer | null = null
  private wasmModule: WebAssembly.Module | null = null
  private sharedMemory: WebAssembly.Memory | null = null
  private threadManager: ThreadManager | null = null
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

    await this.ensureWasmArtifacts()
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
    if (this.threadManager) {
      this.threadManager.dispose()
      this.threadManager = null
    }
    if (wasLive && this.currentDemo) {
      this.emit({ type: "session-stopped", demoName: this.currentDemo })
    }
  }

  private async ensureWasmArtifacts(): Promise<void> {
    if (!this.wasmBytes) {
      const response = await fetch(wasmUrl)
      this.wasmBytes = await response.arrayBuffer()
    }

    if (!this.wasmModule && this.wasmBytes) {
      this.wasmModule = await WebAssembly.compile(this.wasmBytes)
    }
  }

  private async initWASI(): Promise<void> {
    await this.ensureWasmArtifacts()

    if (!this.wasmModule) {
      throw new Error("WASM module not ready")
    }

    if (this.threadManager) {
      this.threadManager.dispose()
    }

    const threadManager = new ThreadManager(this.wasmModule, {
      onStdout: (bytes: Uint8Array) => this.forwardStdout(bytes),
      onStderr: (bytes: Uint8Array) => this.forwardStderr(bytes)
    })
    this.threadManager = threadManager

    const wasi = new WASI({
      stdout: (bytes: Uint8Array) => this.forwardStdout(bytes),
      stderr: (bytes: Uint8Array) => this.forwardStderr(bytes),
      threadSpawn: (argPtr: number) => threadManager.spawnThread(argPtr)
    })

    this.sharedMemory = new WebAssembly.Memory({
      initial: WASM_MEMORY_INITIAL_PAGES,
      maximum: WASM_MEMORY_MAX_PAGES,
      shared: true
    })

    const wasiImports = wasi.getImports() as Record<string, any>
    const envImports: Record<string, unknown> = {
      ...(wasiImports.env ?? {}),
      memory: this.sharedMemory,
      js_performance_now: () => performance.now()
    }

    const imports = {
      ...wasiImports,
      env: envImports
    } as WebAssembly.Imports

    const instance = await WebAssembly.instantiate(this.wasmModule, imports)

    wasi.setMemory(this.sharedMemory)
    threadManager.setMemory(this.sharedMemory)

    this.wasiInstance = { wasi, instance }
  }

  private forwardStdout(bytes: Uint8Array): void {
    const copy = bytes.slice()
    this.emit({ type: "stdout", buffer: copy.buffer }, [copy.buffer])
  }

  private forwardStderr(bytes: Uint8Array): void {
    const copy = bytes.slice()
    this.emit({ type: "stderr", buffer: copy.buffer }, [copy.buffer])
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

    const memory = new Uint8Array(this.getMemory().buffer)
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

  private getMemory(): WebAssembly.Memory {
    if (this.sharedMemory) {
      return this.sharedMemory
    }

    if (this.wasiInstance) {
      const exportedMemory = (
        this.wasiInstance.instance.exports as Record<string, unknown>
      ).memory
      if (exportedMemory instanceof WebAssembly.Memory) {
        return exportedMemory
      }
    }

    throw new Error("WASM memory not available")
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
