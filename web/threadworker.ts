import { WASI } from "./wasi.ts"

const ctx = self as DedicatedWorkerGlobalScope

type StartThreadMessage = {
  type: "start-thread"
  tid: number
  argPtr: number
  module?: WebAssembly.Module
  wasmBytes?: ArrayBuffer
  memory: WebAssembly.Memory
}

type IncomingMessage = StartThreadMessage

type OutgoingMessage =
  | { type: "stdout"; tid: number; buffer: ArrayBuffer }
  | { type: "stderr"; tid: number; buffer: ArrayBuffer }
  | { type: "thread-exit"; tid: number }
  | { type: "thread-error"; tid: number; message: string }

ctx.addEventListener("message", (event: MessageEvent<IncomingMessage>) => {
  const message = event.data

  switch (message.type) {
    case "start-thread":
      void startThread(message)
      break
  }
})

async function startThread(message: StartThreadMessage): Promise<void> {
  if (!(message.memory.buffer instanceof SharedArrayBuffer)) {
    ctx.postMessage({
      type: "thread-error",
      tid: message.tid,
      message: "Shared memory required for thread execution"
    })
    return
  }

  try {
    const module =
      message.module ??
      (message.wasmBytes ? await WebAssembly.compile(message.wasmBytes) : null)

    if (!module) {
      throw new Error("No WebAssembly module provided for thread")
    }

    const wasi = new WASI({
      stdout: (bytes: Uint8Array) => forwardStdout(message.tid, bytes),
      stderr: (bytes: Uint8Array) => forwardStderr(message.tid, bytes),
      threadSpawn: (_argPtr: number) => {
        console.warn("Nested WASI threads are not yet supported in the worker")
        return -1
      }
    })

    const wasiImports = wasi.getImports() as Record<string, any>
    const envImports: Record<string, unknown> = {
      ...(wasiImports.env ?? {}),
      memory: message.memory,
      js_performance_now: () => performance.now()
    }

    const imports = {
      ...wasiImports,
      env: envImports
    } as WebAssembly.Imports

    const instance = await WebAssembly.instantiate(module, imports)

    wasi.setMemory(message.memory)

    const startFn = (instance.exports as Record<string, unknown>).wasi_thread_start
    if (typeof startFn !== "function") {
      throw new Error("wasi_thread_start export not found")
    }

    startFn(message.tid, message.argPtr)

    ctx.postMessage({ type: "thread-exit", tid: message.tid })
  } catch (error) {
    const messageText =
      error instanceof Error ? error.message : `Unknown error: ${String(error)}`
    ctx.postMessage({
      type: "thread-error",
      tid: message.tid,
      message: messageText
    })
  } finally {
    ctx.close()
  }
}

function forwardStdout(tid: number, bytes: Uint8Array): void {
  const copy = bytes.slice()
  ctx.postMessage({ type: "stdout", tid, buffer: copy.buffer }, [copy.buffer])
}

function forwardStderr(tid: number, bytes: Uint8Array): void {
  const copy = bytes.slice()
  ctx.postMessage({ type: "stderr", tid, buffer: copy.buffer }, [copy.buffer])
}
