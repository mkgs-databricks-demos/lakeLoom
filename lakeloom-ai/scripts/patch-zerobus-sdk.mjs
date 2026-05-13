#!/usr/bin/env node
/**
 * Copies locally-built NAPI-RS JS shim into node_modules.
 * Runs via postinstall after every npm install.
 *
 * The published @databricks/zerobus-ingest-sdk tarball is missing index.js
 * and index.d.ts (the NAPI-RS platform-detection shim). Without these files,
 * Node.js cannot resolve the package's "main" entry point at runtime.
 *
 * This script is a no-op if either the patches directory or the SDK package
 * is not installed. Safe to run unconditionally.
 *
 * See: skills/zerobus-sdk/SKILL.md for full context.
 */
import { existsSync, copyFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const PATCH_DIR = join(ROOT, "patches", "zerobus-ingest-sdk");
const TARGET_DIR = join(ROOT, "node_modules", "@databricks", "zerobus-ingest-sdk");
const FILES = ["index.js", "index.d.ts"];

if (!existsSync(PATCH_DIR)) {
  console.log("[patch:zerobus-sdk] No patches directory found. Skipping.");
  process.exit(0);
}
if (!existsSync(TARGET_DIR)) {
  console.log("[patch:zerobus-sdk] SDK not installed. Skipping.");
  process.exit(0);
}

let patched = 0;
for (const file of FILES) {
  const src = join(PATCH_DIR, file);
  const dst = join(TARGET_DIR, file);
  if (!existsSync(src)) { console.log(`[patch:zerobus-sdk] SKIP ${file} (not found in patches)`); continue; }
  copyFileSync(src, dst);
  console.log(`[patch:zerobus-sdk] OK   ${file}`);
  patched++;
}
console.log(`[patch:zerobus-sdk] Patched ${patched}/${FILES.length} files.`);
