import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { inspectPackage } from "../src/check-package.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "ccod-package-test-"));
try {
  const asar = path.join(root, "app.asar");
  const body = Buffer.from("782640499 remote-control-device-key.node Remote control device keys are only available on macOS Control other devices from this PC trailing-hash-bytes");
  fs.writeFileSync(asar, body);
  const result = await inspectPackage(asar, path.join(root, "native"));
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.classification, "CandidateCompatible");
  assert.equal(result.appAsarSha256, crypto.createHash("sha256").update(body).digest("hex"));
  fs.mkdirSync(path.join(root, "native"), { recursive: true });
  fs.writeFileSync(path.join(root, "native", "remote-control-device-key.node"), "fixture");
  assert.equal((await inspectPackage(asar, path.join(root, "native"))).classification, "NativeModulePresent");
} finally {
  fs.rmSync(root, { force: true, recursive: true });
}
