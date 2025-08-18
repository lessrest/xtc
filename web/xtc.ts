import { Terminal } from "@xterm/xterm"
import { WebglAddon } from "@xterm/addon-webgl"
import { WASI } from "./wasi.ts"
import wasmUrl from "../zig-out/web-dist/xtc.wasm"

import wavesScript from "../demos/waves.wren" with { type: "text" }
import matrixScript from "../demos/matrix.wren" with { type: "text" }

class XTCModule {
  private wasiInstance: any = null
  private terminal: Terminal | null = null
  private decoder = new TextDecoder()
  private encoder = new TextEncoder()
  // Fixed terminal dimensions
  private readonly TERMINAL_COLS = 80
  private readonly TERMINAL_ROWS = 40
  // Live session state
  private isLiveSession = false
  private animationFrameId: number | null = null

  async init(): Promise<boolean> {
    try {
      // Initialize xterm.js with fixed size
      this.terminal = new Terminal({
        fontFamily: "monaspace neon",
        fontSize: 18,
        cols: this.TERMINAL_COLS,
        rows: this.TERMINAL_ROWS,
        scrollback: 1000
      })

      this.terminal.open(document.getElementById("terminal")!)

      try {
        const webglAddon = new WebglAddon()
        this.terminal.loadAddon(webglAddon)
        console.log("WebGL renderer enabled for xterm.js")
      } catch (error) {
        console.warn(
          "WebGL renderer not available, falling back to canvas:",
          error
        )
      }

      const wasmResponse = await fetch(wasmUrl)
      const wasmBytes = await wasmResponse.arrayBuffer()

      // Create WASI instance with stdout callback to terminal
      const wasi = new WASI({
        stdout: (bytes: Uint8Array) => {
          if (this.terminal) {
            this.terminal.write(new TextDecoder().decode(bytes))
          }
        },
        stderr: (bytes: Uint8Array) => {
          // Send stderr to console, not terminal
          const text = new TextDecoder().decode(bytes)
          console.error("WASM stderr:", text)
        }
      })

      // Add JS imports for WASM including performance.now()
      const wasiImports = wasi.getImports()
      const jsImports = {
        env: {
          js_performance_now: () => performance.now()
        }
      }

      const wasmModule = await WebAssembly.instantiate(wasmBytes, {
        ...wasiImports,
        ...jsImports
      })

      // Set memory for WASI
      wasi.setMemory(wasmModule.instance.exports.memory)
      this.wasiInstance = { wasi, instance: wasmModule.instance }

      return true
    } catch (error) {
      console.error("Failed to load WASI module:", error)
      return false
    }
  }

  // Helper function to allocate string in WASM memory
  private allocateString(str: string): { ptr: number; length: number } {
    const bytes = this.encoder.encode(str + "\0") // null-terminated
    const ptr = (this.wasiInstance.instance.exports as any).wasm_alloc(
      bytes.length
    )
    if (!ptr) {
      throw new Error("Failed to allocate memory in WASM")
    }
    const memory = new Uint8Array(
      (this.wasiInstance.instance.exports.memory as WebAssembly.Memory).buffer
    )
    memory.set(bytes, ptr)
    return { ptr, length: bytes.length }
  }

  // Helper function to read string from WASM memory
  private readString(ptr: number, length: number): string {
    const memory = new Uint8Array(
      (this.wasiInstance.instance.exports.memory as WebAssembly.Memory).buffer
    )
    const bytes = memory.slice(ptr, ptr + length)
    // Remove null terminator if present
    const nullIndex = bytes.indexOf(0)
    const actualBytes = nullIndex >= 0 ? bytes.slice(0, nullIndex) : bytes
    return this.decoder.decode(actualBytes)
  }

  // Free WASM memory
  private freeMemory(ptr: number, length: number): void {
    ;(this.wasiInstance.instance.exports as any).wasm_free(ptr, length)
  }

  // Initialize a live session with XML
  initLiveSession(xmlString: string): boolean {
    try {
      this.terminal!.clear()

      if (!this.wasiInstance) {
        this.terminal!.writeln("WASI not available - cannot start live session")
        return false
      }

      // Call the live session init function
      if (this.wasiInstance.instance.exports.xtc_init_session) {
        // Allocate memory for XML string
        const xmlBytes = new TextEncoder().encode(xmlString)
        const xmlPtr = this.wasiInstance.instance.exports.wasm_alloc(
          xmlBytes.length
        )

        if (xmlPtr) {
          // Copy XML to WASM memory
          const memory = new Uint8Array(
            this.wasiInstance.instance.exports.memory.buffer
          )
          memory.set(xmlBytes, xmlPtr)

          // Call init function with terminal dimensions
          const result = this.wasiInstance.instance.exports.xtc_init_session(
            xmlPtr,
            xmlBytes.length,
            this.TERMINAL_COLS,
            this.TERMINAL_ROWS
          )

          // Free memory
          if (this.wasiInstance.instance.exports.wasm_free) {
            this.wasiInstance.instance.exports.wasm_free(
              xmlPtr,
              xmlBytes.length
            )
          }

          if (result === 0) {
            this.isLiveSession = true
            this.startAnimationLoop()
            this.setupKeyboardInput()
            return true
          } else {
            this.terminal!.writeln("Failed to initialize live session")
            return false
          }
        } else {
          this.terminal!.writeln("Failed to allocate memory for XML")
          return false
        }
      } else {
        this.terminal!.writeln("xtc_init_session function not found")
        return false
      }
    } catch (error) {
      console.error("Live session init error:", error)
      this.terminal!.writeln(`\r\nError: ${(error as Error).message}`)
      return false
    }
  }

  // Start the requestAnimationFrame loop
  private startAnimationLoop(): void {
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId)
    }

    const animate = () => {
      if (!this.isLiveSession || !this.wasiInstance) {
        return
      }

      // Process one animation frame
      if (this.wasiInstance.instance.exports.xtc_process_frame) {
        const needsRender =
          this.wasiInstance.instance.exports.xtc_process_frame()

        if (needsRender === 1) {
            this.wasiInstance.instance.exports.xtc_render_frame()
        } else if (needsRender === -1) {
          console.error("Frame processing error")
          this.stopLiveSession()
          return
        }
      }

      // Continue animation loop
      this.animationFrameId = requestAnimationFrame(animate)
    }

    this.animationFrameId = requestAnimationFrame(animate)
  }

  // Setup keyboard input handling
  private setupKeyboardInput(): void {
    if (!this.terminal) return

    // Handle keyboard input from terminal
    this.terminal.onKey(({ key, domEvent }) => {
      if (!this.isLiveSession || !this.wasiInstance) return

      // Convert special keys
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
        return // Skip other special keys
      }

      // Send keypress to WASM
      if (this.wasiInstance.instance.exports.xtc_keypress) {
        this.wasiInstance.instance.exports.xtc_keypress(keyCode)
      }
    })
  }

  // Stop the live session
  stopLiveSession(): void {
    this.isLiveSession = false

    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId)
      this.animationFrameId = null
    }

    if (this.wasiInstance && this.wasiInstance.instance.exports.xtc_cleanup) {
      this.wasiInstance.instance.exports.xtc_cleanup()
    }
  }

  // Legacy one-shot render function
  renderXML(xmlString: string): void {
    try {
      this.terminal!.clear()

      if (!this.wasiInstance) {
        this.terminal!.writeln("WASI not available - cannot render")
        return
      }

      // Call the render function with XML data
      if (this.wasiInstance.instance.exports.xtc_render) {
        // Allocate memory for XML string
        const xmlBytes = new TextEncoder().encode(xmlString)
        const xmlPtr = this.wasiInstance.instance.exports.wasm_alloc(
          xmlBytes.length
        )

        if (xmlPtr) {
          // Copy XML to WASM memory
          const memory = new Uint8Array(
            this.wasiInstance.instance.exports.memory.buffer
          )
          memory.set(xmlBytes, xmlPtr)

          // Call render function with terminal dimensions
          this.wasiInstance.instance.exports.xtc_render(
            xmlPtr,
            xmlBytes.length,
            this.TERMINAL_COLS,
            this.TERMINAL_ROWS
          )

          // Free memory
          if (this.wasiInstance.instance.exports.wasm_free) {
            this.wasiInstance.instance.exports.wasm_free(
              xmlPtr,
              xmlBytes.length
            )
          }
        } else {
          this.terminal!.writeln("Failed to allocate memory for XML")
        }
      } else {
        this.terminal!.writeln("xtc_render function not found")
      }
    } catch (error) {
      console.error("Render error:", error)
      this.terminal!.writeln(`\r\nError: ${(error as Error).message}`)
    }
  }
}

function escapeHtml(unsafe: string): string {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Initialize everything when the page loads
async function init(): Promise<void> {
  const xtc = new XTCModule()
  const success = await xtc.init()

  if (success) {
    console.log(wavesScript)
    // Start with animated wave demo
    const waveDemo = `
            <root class="flex flex-row">
                <script type="text/wren" module="waves" class="flex flex-row grow-1" id="waves">${escapeHtml(
                  location.search.includes("matrix") ? matrixScript : wavesScript
                )}</script>
            </root>
        `

    const liveSuccess = xtc.initLiveSession(waveDemo)
    if (!liveSuccess) {
      console.error("Failed to load live session")
    }
  } else {
    console.error("Failed to load WASM module")
  }
}

// Start the application
init().catch(console.error)
