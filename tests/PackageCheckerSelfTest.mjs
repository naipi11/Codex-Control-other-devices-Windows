import assert from "node:assert/strict";
import { inspectPackage, runCheckPackageCli } from "../src/check-package.mjs";

const firstChunk = Buffer.concat([
  Buffer.from("782640499 remote-control-device-key.node Remote control device keys are only available on macOS Control other devices from this PC "),
  Buffer.alloc(4 * 1024 * 1024),
]);
const trailingChunk = Buffer.from("trailing-hash-bytes");
const incompleteFirstChunk = Buffer.from(
  "782640499 remote-control-device-key.node Remote control device keys are only available on macOS",
);
const expectedDigest = `fake-sha256:${Buffer.concat([firstChunk, trailingChunk]).toString("hex")}`;
const expectedSignatures = {
  invertedGate: true,
  deviceKeyModuleReference: true,
  macOnlyGuard: true,
  windowsControllerUi: true,
};

function createFakeAdapters({
  nativeModulePresent = false,
  chunks = [firstChunk, trailingChunk],
} = {}) {
  const stdout = [];
  return {
    adapters: {
      async access(asarPath) {
        if (asarPath !== "fixture.asar") throw new Error(`missing fixture: ${asarPath}`);
      },
      createHash(algorithm) {
        const chunks = [];
        return {
          update(chunk) { chunks.push(Buffer.from(chunk)); },
          digest(encoding) {
            if (encoding !== "hex") throw new Error(`unexpected digest encoding: ${encoding}`);
            return `fake-${algorithm}:${Buffer.concat(chunks).toString("hex")}`;
          },
        };
      },
      createReadStream(asarPath, options) {
        if (asarPath !== "fixture.asar") throw new Error(`missing fixture: ${asarPath}`);
        if (options.highWaterMark !== 4 * 1024 * 1024) throw new Error("unexpected chunk size");
        return (async function* () {
          yield* chunks;
        })();
      },
      async readdir(directory) {
        if (directory !== "fixture.native") throw new Error(`unexpected directory: ${directory}`);
        if (!nativeModulePresent) {
          const error = new Error("missing native directory");
          error.code = "ENOENT";
          throw error;
        }
        return [{
          isDirectory: () => false,
          isFile: () => true,
          name: "remote-control-device-key.node",
        }];
      },
      joinPath: (...parts) => parts.join("/"),
      process: {
        argv: ["node", "check-package.mjs", "fixture.asar", "fixture.native"],
        stderr: { write: () => {} },
        stdout: { write: (text) => stdout.push(text) },
      },
    },
    stdout,
  };
}

{
  const { adapters } = createFakeAdapters();
  const result = await inspectPackage("fixture.asar", "fixture.native", adapters);
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.classification, "CandidateCompatible");
  assert.equal(result.affected, true);
  assert.equal(result.appAsarSha256, expectedDigest);
  assert.deepEqual(result.signatures, expectedSignatures);
}

{
  const { adapters } = createFakeAdapters({ nativeModulePresent: true });
  const result = await inspectPackage("fixture.asar", "fixture.native", adapters);
  assert.equal(result.classification, "CandidateCompatible");
  assert.equal(result.affected, true);
  assert.equal(result.nativeModulePresent, true);
  assert.deepEqual(result.signatures, expectedSignatures);
}

{
  const { adapters } = createFakeAdapters({
    nativeModulePresent: true,
    chunks: [incompleteFirstChunk, trailingChunk],
  });
  const result = await inspectPackage("fixture.asar", "fixture.native", adapters);
  assert.equal(result.classification, "NativeModulePresent");
  assert.equal(result.affected, false);
  assert.equal(result.signatures.windowsControllerUi, false);
}

{
  const { adapters } = createFakeAdapters({
    chunks: [incompleteFirstChunk, trailingChunk],
  });
  const result = await inspectPackage("fixture.asar", "fixture.native", adapters);
  assert.equal(result.classification, "UnknownOrIncompatible");
  assert.equal(result.affected, false);
  assert.equal(result.signatures.windowsControllerUi, false);
}

{
  const { adapters, stdout } = createFakeAdapters();
  assert.equal(await runCheckPackageCli(adapters), 0);
  assert.deepEqual(JSON.parse(stdout.join("")), {
    affected: true,
    appAsarSha256: expectedDigest,
    asarPath: "fixture.asar",
    classification: "CandidateCompatible",
    nativeDirectory: "fixture.native",
    nativeModulePresent: false,
    schemaVersion: 1,
    signatures: expectedSignatures,
  });
}
