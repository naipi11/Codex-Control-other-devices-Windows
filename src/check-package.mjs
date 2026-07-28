#!/usr/bin/env node

import { createReadStream } from "node:fs";
import { access, readdir } from "node:fs/promises";
import path from "node:path";

const [asarPath, nativeDirectory] = process.argv.slice(2);

if (!asarPath || !nativeDirectory) {
  console.error("Usage: node check-package.mjs <app.asar> <native-directory>");
  process.exit(2);
}

const signatures = new Map([
  ["invertedGate", Buffer.from("782640499")],
  ["deviceKeyModuleReference", Buffer.from("remote-control-device-key.node")],
  ["macOnlyGuard", Buffer.from("Remote control device keys are only available on macOS")],
  ["windowsControllerUi", Buffer.from("Control other devices from this PC")],
]);

async function scanFile(file, needles) {
  const found = Object.fromEntries([...needles.keys()].map((name) => [name, false]));
  const longest = Math.max(...[...needles.values()].map((needle) => needle.length));
  let carry = Buffer.alloc(0);

  for await (const chunk of createReadStream(file, { highWaterMark: 4 * 1024 * 1024 })) {
    const searchable = carry.length === 0 ? chunk : Buffer.concat([carry, chunk]);
    for (const [name, needle] of needles) {
      if (!found[name] && searchable.indexOf(needle) !== -1) {
        found[name] = true;
      }
    }

    if (Object.values(found).every(Boolean)) break;
    carry = searchable.subarray(Math.max(0, searchable.length - longest + 1));
  }

  return found;
}

async function containsNativeDeviceKeyModule(directory) {
  const pending = [directory];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT" && current === directory) return false;
      throw error;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(fullPath);
      if (entry.isFile() && entry.name === "remote-control-device-key.node") return true;
    }
  }
  return false;
}

try {
  await access(asarPath);
  const signatureState = await scanFile(asarPath, signatures);
  const nativeModulePresent = await containsNativeDeviceKeyModule(nativeDirectory);
  const affected = signatureState.invertedGate
    && signatureState.deviceKeyModuleReference
    && signatureState.macOnlyGuard
    && signatureState.windowsControllerUi
    && !nativeModulePresent;

  process.stdout.write(JSON.stringify({
    affected,
    asarPath,
    nativeDirectory,
    nativeModulePresent,
    signatures: signatureState,
  }));
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
