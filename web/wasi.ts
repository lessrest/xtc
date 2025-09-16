// -*- fill-column: 64; -*-
//
// This file is part of Wisp.
//
// Wisp is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// Wisp is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General
// Public License along with Wisp. If not, see
// <https://www.gnu.org/licenses/>.
//

const WASI_ESUCCESS = 0
const WASI_STDOUT_FILENO = 1
const WASI_STDERR_FILENO = 2

const CLOCK = {
  REALTIME: 0,
  MONOTONIC: 1
} as const

interface WASIOptions {
  stdout?: (data: Uint8Array) => void
  stderr?: (data: Uint8Array) => void
  terminalSize?: { cols: number; rows: number }
  threadSpawn?: (argPtr: number) => number
}

export default class WASI {
  private memory?: WebAssembly.Memory
  private stdout: (data: Uint8Array) => void
  private stderr: (data: Uint8Array) => void
  private terminalSize: { cols: number; rows: number }
  private threadSpawn?: (argPtr: number) => number

  constructor(options: WASIOptions = {}) {
    this.stdout = options.stdout || ((text) => console.log(text))
    this.stderr = options.stderr || ((text) => console.warn(text))
    this.terminalSize = options.terminalSize || { cols: 80, rows: 24 }
    this.threadSpawn = options.threadSpawn
  }

  setMemory(memory: WebAssembly.Memory): void {
    this.memory = memory
  }

  private getDataView(): DataView {
    if (!this.memory) {
      throw new Error("Memory not set")
    }
    return new DataView(this.memory.buffer)
  }

  getImports(): WebAssembly.Imports {
    return {
      wasi_snapshot_preview1: this.exports()
    }
  }

  private exports() {
    return {
      proc_exit(): void {},

      fd_prestat_get(): void {},
      fd_prestat_dir_name(): void {},

      fd_write: (
        fd: number,
        iovs: number,
        iovsLen: number,
        nwritten: number
      ): number => {
        const view = this.getDataView()
        let written = 0

        const buffers = Array.from({ length: iovsLen }, (_, i) => {
          const ptr = iovs + i * 8
          const buf = view.getUint32(ptr, true)
          const bufLen = view.getUint32(ptr + 4, true)

          return new Uint8Array(this.memory!.buffer, buf, bufLen)
        })

        // Forward raw bytes directly to terminal
        for (const iov of buffers) {
          if (fd === WASI_STDOUT_FILENO) this.stdout(iov)
          else if (fd === WASI_STDERR_FILENO) this.stderr(iov)

          written += iov.byteLength
        }

        view.setUint32(nwritten, written, true)

        return WASI_ESUCCESS
      },

      fd_pwrite: (
        fd: number,
        iovs: number,
        iovsLen: number,
        offset: bigint,
        nwritten: number
      ) => {
        if (fd === WASI_STDOUT_FILENO || fd === WASI_STDERR_FILENO) {
          return this.exports().fd_write(fd, iovs, iovsLen, nwritten)
        }

        return 8 // EBADF
      },

      fd_pread: (
        fd: number,
        iovs: number,
        iovsLen: number,
        offset: bigint,
        nread: number
      ): number => {
        // Return EBADF - bad file descriptor
        // This will blow up if anything actually tries to read
        return 8 // EBADF
      },

      fd_close(): void {},
      fd_read(): void {},

      path_open(): void {},
      path_rename(): void {},
      path_create_directory(): void {},
      path_remove_directory(): void {},
      path_unlink_file(): void {},

      fd_filestat_get(): void {},

      random_get: (buf_ptr: number, buf_len: number): number => {
        const buffer = new Uint8Array(this.memory!.buffer, buf_ptr, buf_len)
        crypto.getRandomValues(buffer)

        return 0
      },

      clock_time_get: (
        clock_id: number,
        _precision: bigint,
        timestamp_out: number
      ): number => {
        const view = this.getDataView()

        switch (clock_id) {
          case CLOCK.REALTIME:
          case CLOCK.MONOTONIC: {
            const t = BigInt(Date.now()) * BigInt(1e6)
            view.setBigUint64(timestamp_out, t, true)
            break
          }

          default:
            throw new Error("unhandled clock type")
        }

        return 0
      },

      // Args functions for command line arguments
      args_sizes_get: (argc_ptr: number, argv_buf_size_ptr: number): number => {
        const view = this.getDataView()
        const args = ["xtc", "80", "24"]

        view.setUint32(argc_ptr, args.length, true)

        let buf_size = 0
        for (const arg of args) {
          buf_size += new TextEncoder().encode(arg + "\0").length
        }
        view.setUint32(argv_buf_size_ptr, buf_size, true)

        return WASI_ESUCCESS
      },

      args_get: (argv_ptr: number, argv_buf_ptr: number): number => {
        const view = this.getDataView()
        const args = ["xtc", "80", "24"]
        const textEncoder = new TextEncoder()

        let buf_offset = argv_buf_ptr
        for (let i = 0; i < args.length; i++) {
          const arg_bytes = textEncoder.encode(args[i] + "\0")

          // Set pointer to string
          view.setUint32(argv_ptr + i * 4, buf_offset, true)

          // Copy string to buffer
          const memory_view = new Uint8Array(this.memory!.buffer)
          memory_view.set(arg_bytes, buf_offset)
          buf_offset += arg_bytes.length
        }

        return WASI_ESUCCESS
      },

      // Environment functions
      environ_sizes_get: (
        environc_ptr: number,
        environ_buf_size_ptr: number
      ): number => {
        const view = this.getDataView()
        view.setUint32(environc_ptr, 0, true) // no env vars
        view.setUint32(environ_buf_size_ptr, 0, true)
        return WASI_ESUCCESS
      },

      environ_get: (environ_ptr: number, environ_buf_ptr: number): number => {
        return WASI_ESUCCESS
      },

      // File descriptor stat function
      fd_fdstat_get: (fd: number, fdstat_ptr: number): number => {
        const view = this.getDataView()

        // Set basic file descriptor stats for stdout/stderr
        if (fd === WASI_STDOUT_FILENO || fd === WASI_STDERR_FILENO) {
          // fs_filetype (u8): character device
          view.setUint8(fdstat_ptr, 2)
          // fs_flags (u16): append
          view.setUint16(fdstat_ptr + 2, 1, true)
          // fs_rights_base (u64): write rights
          view.setBigUint64(fdstat_ptr + 8, BigInt(0x40), true)
          // fs_rights_inheriting (u64): same as base
          view.setBigUint64(fdstat_ptr + 16, BigInt(0x40), true)
        }

        return WASI_ESUCCESS
      },

      // File descriptor seek function
      fd_seek: (
        fd: number,
        offset: bigint,
        whence: number,
        newoffset_ptr: number
      ): number => {
        const view = this.getDataView()

        // For stdout/stderr, seeking is not supported
        if (fd === WASI_STDOUT_FILENO || fd === WASI_STDERR_FILENO) {
          // Set new offset to 0 (no change)
          view.setBigUint64(newoffset_ptr, BigInt(0), true)
          return WASI_ESUCCESS
        }

        // For other file descriptors, return success with no change
        view.setBigUint64(newoffset_ptr, BigInt(0), true)
        return WASI_ESUCCESS
      },

      "thread-spawn": (instancePtr: number): number => {
        if (!this.threadSpawn) {
          console.warn("WASI thread-spawn requested but no handler installed")
          return -1
        }

        try {
          return this.threadSpawn(instancePtr)
        } catch (error) {
          console.error("thread-spawn handler threw", error)
          return -1
        }
      }
    }
  }

  start(instance: WebAssembly.Instance): void {
    this.memory = instance.exports.memory as WebAssembly.Memory
    const entry = instance.exports._initialize as (() => void) | undefined
    if (entry) {
      entry()
    }
  }
}

export { WASI }
