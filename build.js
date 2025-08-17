#!/usr/bin/env bun

import { build } from 'bun';
import { existsSync, mkdirSync } from 'fs';

const outdir = './zig-out/web-dist';

// Ensure output directory exists
if (!existsSync(outdir)) {
  mkdirSync(outdir, { recursive: true });
}

try {
  const result = await build({
    entrypoints: ['./web/index.html'],
    outdir,
    naming: {
      entry: "[dir]/[name].[ext]",
      asset: "[name].[hash].[ext]",
    },
    target: 'browser',
    splitting: false,
    minify: process.env.NODE_ENV === 'production',
    sourcemap: process.env.NODE_ENV !== 'production' ? 'external' : 'none',
  });

  if (result.success) {
    console.log('✅ Build completed successfully');
    console.log(`📁 Output: ${outdir}`);
  } else {
    console.error('❌ Build failed');
    for (const message of result.logs) {
      console.error(message);
    }
    process.exit(1);
  }
} catch (error) {
  console.error('❌ Build error:', error);
  process.exit(1);
}