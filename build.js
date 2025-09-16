#!/usr/bin/env bun

import { build } from "bun"
import { existsSync, mkdirSync } from "fs"
import { relative } from "path"

const outdir = "./zig-out/web-dist"

// Ensure output directory exists
if (!existsSync(outdir)) {
  mkdirSync(outdir, { recursive: true })
}

try {
  const x = await build({
    entrypoints: ["./web/xtcworker.ts", "./web/threadworker.ts"],
    root: "./web",
    outdir,
    target: "browser",
    naming: {
      entry: "[dir]/[name].[hash].[ext]"
    },
    splitting: false,
    sourcemap: "inline",
    loader: {
      ".wren": "text",
      ".wasm": "file"
    }
  })

  const worker_path = relative(outdir, x.outputs[0].path)
  const wasm_thread_worker_path = relative(outdir, x.outputs[1].path)

  console.log("✅ Worker build completed successfully")
  console.log(`📁    XTC worker: ${worker_path}`)
  console.log(`📁 Thread worker: ${wasm_thread_worker_path}`)

  const result = await build({
    entrypoints: ["./web/index.html"],
    root: "./web",
    outdir,
    define: {
      "process.env.XTC_WORKER": JSON.stringify(worker_path),
      "process.env.THREAD_WORKER": JSON.stringify(wasm_thread_worker_path)
    },
    naming: {
      entry: "[dir]/[name].[ext]",
      asset: "[name].[hash].[ext]"
    },
    target: "browser",
    splitting: false,
    sourcemap: "inline",
    loader: {
      ".wren": "text",
      ".wasm": "file"
    }
  })

  if (result.success) {
    console.log("✅ Build completed successfully")
    console.log(`📁 Output: ${outdir}`)
  } else {
    console.error("❌ Build failed")
    for (const message of result.logs) {
      console.error(message)
    }
    process.exit(1)
  }
} catch (error) {
  console.error("❌ Build error:", error)
  process.exit(1)
}
