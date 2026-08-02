#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { access, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const signatures = new Map([
  ["invertedGate", Buffer.from("782640499")],
  ["deviceKeyModuleReference", Buffer.from("remote-control-device-key.node")],
  ["macOnlyGuard", Buffer.from("Remote control device keys are only available on macOS")],
  ["windowsControllerUi", Buffer.from("Control other devices from this PC")],
]);

export async function inspectPackage(asarPath, nativeDirectory) {
  const hash = createHash("sha256");
  const signatureState = Object.fromEntries([...signatures.keys()].map((name) => [name, false]));
  const longest = Math.max(...[...signatures.values()].map((needle) => needle.length));
  let carry = Buffer.alloc(0);

  for await (const chunk of createReadStream(asarPath, { highWaterMark: 4 * 1024 * 1024 })) {
    hash.update(chunk);
    const searchable = carry.length === 0 ? chunk : Buffer.concat([carry, chunk]);
    for (const [name, needle] of signatures) {
      if (!signatureState[name] && searchable.indexOf(needle) !== -1) signatureState[name] = true;
    }
    carry = searchable.subarray(Math.max(0, searchable.length - longest + 1));
  }

  const nativeModulePresent = await containsNativeDeviceKeyModule(nativeDirectory);
  const allSignatures = Object.values(signatureState).every(Boolean);
  const classification = nativeModulePresent
    ? "NativeModulePresent"
    : allSignatures ? "CandidateCompatible" : "UnknownOrIncompatible";
  return {
    affected: classification === "CandidateCompatible",
    appAsarSha256: hash.digest("hex"),
    classification,
    nativeModulePresent,
    schemaVersion: 1,
    signatures: signatureState,
  };
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

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [asarPath, nativeDirectory] = process.argv.slice(2);
  if (!asarPath || !nativeDirectory) {
    console.error("Usage: node check-package.mjs <app.asar> <native-directory>");
    process.exit(2);
  }

  try {
    await access(asarPath);
    const result = await inspectPackage(asarPath, nativeDirectory);
    process.stdout.write(JSON.stringify({ asarPath, nativeDirectory, ...result }));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
