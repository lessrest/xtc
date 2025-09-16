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
  private wasmBytes: ArrayBuffer | null = null
  // Dynamic terminal dimensions
  private terminalCols = 80
  private terminalRows = 30
  // Live session state
  private isLiveSession = false
  private animationFrameId: number | null = null
  private currentDemo = "waves"
  private keyboardHandlerRegistered = false

  // Initialize or reinitialize WASI instance
  private async initWASI(): Promise<void> {
    if (!this.wasmBytes) {
      throw new Error("WASM bytes not loaded")
    }

    // Create fresh WASI instance
    const wasi = new WASI({
      stdout: (bytes: Uint8Array) => {
        if (this.terminal) {
          this.terminal.write(new TextDecoder().decode(bytes))
        }
      },
      stderr: (bytes: Uint8Array) => {
        const text = new TextDecoder().decode(bytes)
        console.error("WASM stderr:", text)
      }
    })

    // Add JS imports for WASM
    const wasiImports = wasi.getImports()
    const jsImports = {
      env: {
        js_performance_now: () => performance.now()
      }
    }

    // Create fresh WASM instance
    const wasmModule = await WebAssembly.instantiate(this.wasmBytes, {
      ...wasiImports,
      ...jsImports
    })

    // Set memory for WASI
    wasi.setMemory(wasmModule.instance.exports.memory)
    this.wasiInstance = { wasi, instance: wasmModule.instance }

    console.log("WASI reinitialized successfully")
  }

  // Calculate responsive terminal dimensions
  private calculateTerminalSize(): { cols: number; rows: number } {
    const containerElement = document.querySelector('.terminal-wrapper') as HTMLElement
    if (!containerElement) {
      return { cols: 80, rows: 30 }
    }

    const containerWidth = containerElement.clientWidth - 16 // padding
    const containerHeight = containerElement.clientHeight - 16 // padding

    // Base font size calculation for responsive design
    const baseSize = Math.max(10, Math.min(16, containerWidth / 50))
    
    // Character dimensions (approximate for monospace fonts)
    const charWidth = baseSize * 0.6
    const charHeight = baseSize * 1.2

    const cols = Math.max(40, Math.floor(containerWidth / charWidth))
    const rows = Math.max(20, Math.floor(containerHeight / charHeight))

    return { 
      cols: Math.min(cols, 120), 
      rows: Math.min(rows, 50) 
    }
  }

  async init(): Promise<boolean> {
    try {
      // Calculate responsive terminal size
      const { cols, rows } = this.calculateTerminalSize()
      this.terminalCols = cols
      this.terminalRows = rows

      // Calculate responsive font size
      const containerElement = document.querySelector('.terminal-wrapper') as HTMLElement
      const fontSize = containerElement ? Math.max(10, Math.min(16, containerElement.clientWidth / 50)) : 14

      // Initialize xterm.js with responsive size
      this.terminal = new Terminal({
        fontFamily: "'Monaco', 'Menlo', 'Ubuntu Mono', monospace",
        fontSize: fontSize,
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
        console.warn(
          "WebGL renderer not available, falling back to canvas:",
          error
        )
      }

      const wasmResponse = await fetch(wasmUrl)
      this.wasmBytes = await wasmResponse.arrayBuffer()

      // Initialize first WASI instance
      await this.initWASI()

      return true
    } catch (error) {
      console.error("Failed to load WASI module:", error)
      return false
    }
  }

  // Helper function to allocate string in WASM memory
  private allocateString(str: string): { ptr: number; length: number } {
    const bytes = this.encoder.encode(str)
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
  // Free WASM memory
  private freeMemory(ptr: number, length: number): void {
    ;(this.wasiInstance.instance.exports as any).wasm_free(ptr, length)
  }

  // Initialize a live session with a Wren script
  initLiveSession(script: string, moduleName: string): boolean {
    try {
      this.terminal!.clear()

      if (!this.wasiInstance) {
        this.terminal!.writeln("WASI not available")
        return false
      }

      if (!this.wasiInstance.instance.exports.xtc_init_session) {
        this.terminal!.writeln("xtc_init_session function not found")
        return false
      }

      const scriptAlloc = this.allocateString(script)
      const moduleAlloc = this.allocateString(moduleName)

      try {
        const result = this.wasiInstance.instance.exports.xtc_init_session(
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
          this.setupKeyboardInput()
          return true
        } else {
          this.terminal!.writeln(`Init failed: ${result}`)
          return false
        }
      } finally {
        this.freeMemory(scriptAlloc.ptr, scriptAlloc.length)
        this.freeMemory(moduleAlloc.ptr, moduleAlloc.length)
      }
    } catch (error) {
      console.error("Init error:", error)
      this.terminal!.writeln(`Error: ${error}`)
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
    if (!this.terminal || this.keyboardHandlerRegistered) return
    this.keyboardHandlerRegistered = true

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

    // if (this.wasiInstance?.instance.exports.xtc_cleanup) {
    //   this.wasiInstance.instance.exports.xtc_cleanup()
    // }
  }

  // Switch to a different demo
  async switchDemo(demoName: string): Promise<void> {
    console.log(`Switching to demo: ${demoName}`)
    
    this.currentDemo = demoName
    
    // Stop current session
    this.stopLiveSession()
    
    // Clear terminal
    if (this.terminal) {
      this.terminal.clear()
    }

    // Reinitialize WASI completely
    await this.initWASI()

    // Select script for the demo
    let script: string
    switch (demoName) {
      case "matrix":
        script = matrixScript
        break
      default:
        script = wavesScript
        break
    }

    // Start new session with fresh WASI
    if (!this.initLiveSession(script, demoName)) {
      console.error("Failed to start demo session")
    }
  }

  // Handle window resize
  handleResize(): void {
    if (!this.terminal) return

    const { cols, rows } = this.calculateTerminalSize()
    
    if (cols !== this.terminalCols || rows !== this.terminalRows) {
      this.terminalCols = cols
      this.terminalRows = rows
      
      // Resize the terminal
      this.terminal.resize(cols, rows)

      if (this.isLiveSession && this.wasiInstance?.instance.exports.xtc_resize) {
        this.wasiInstance.instance.exports.xtc_resize(cols, rows)
      }
    }
  }
}

// Initialize everything when the page loads
async function init(): Promise<void> {
  const xtc = new XTCModule()
  const success = await xtc.init()

  if (success) {
    // Set up tab switching
    const tabs = document.querySelectorAll('.tab')
    tabs.forEach(tab => {
      tab.addEventListener('click', async (e) => {
        const target = e.target as HTMLButtonElement
        const demoName = target.dataset.demo

        if (demoName) {
          console.log("Tab clicked:", demoName)
          
          // Disable tabs during switch
          tabs.forEach(t => (t as HTMLButtonElement).disabled = true)
          
          // Update active tab
          tabs.forEach(t => t.classList.remove('active'))
          target.classList.add('active')
          
          try {
            // Switch demo with full WASI reinit
            await xtc.switchDemo(demoName)
          } catch (error) {
            console.error("Failed to switch demo:", error)
          }
          
          // Re-enable tabs
          tabs.forEach(t => (t as HTMLButtonElement).disabled = false)
        }
      })
    })

    // Set up window resize handler
    let resizeTimeout: number
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimeout)
      resizeTimeout = setTimeout(() => {
        xtc.handleResize()
      }, 250)
    })

    // Start with the default demo (waves)
    await xtc.switchDemo('waves')
  } else {
    console.error("Failed to load WASM module")
  }
}

// Start the application
init().catch(console.error)
