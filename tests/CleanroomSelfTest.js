#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const {
  DeviceKeyService,
  resolveStorePath,
  resolveWindowsPowerShellPath,
  runDpapi,
} = require("../src/runtime/main-payload.js");
const {
  checkPortOnce,
  chooseTarget,
  parseArguments,
  runProbeBridge,
  runRendererBridge,
  waitForExplicitRefusal,
} = require("../src/runtime/orchestrator.js");

function listJavaScriptFiles(directory) {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      output.push(...listJavaScriptFiles(fullPath));
    } else if (entry.isFile() && entry.name.endsWith(".js")) {
      output.push(fullPath);
    }
  }
  return output;
}

function reservePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0 }, () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : null;
      server.close((error) => {
        if (error) reject(error);
        else resolve(port);
      });
    });
  });
}

function waitForOutput(stream, marker, timeoutMs) {
  return new Promise((resolve, reject) => {
    let text = "";
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for child marker: ${marker}`));
    }, timeoutMs);
    const onData = (chunk) => {
      text += chunk.toString("utf8");
      if (text.includes(marker)) {
        cleanup();
        resolve();
      }
    };
    const cleanup = () => {
      clearTimeout(timer);
      stream.off("data", onData);
    };
    stream.on("data", onData);
  });
}

function waitForChildExit(child, timeoutMs) {
  return new Promise((resolve) => {
    if (child.exitCode != null || child.signalCode != null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      child.kill();
      resolve();
    }, timeoutMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

async function syntaxTest(root) {
  const runtimeRoot = path.join(root, "..", "src", "runtime");
  const files = [...listJavaScriptFiles(runtimeRoot), __filename];
  assert(files.length >= 5);
  for (const file of files) {
    const result = childProcess.spawnSync(process.execPath, ["--check", file], {
      encoding: "utf8",
      windowsHide: true,
    });
    assert.equal(result.status, 0, `Syntax check failed for ${path.basename(file)}`);
  }
  return { filesChecked: files.length };
}

async function deviceKeyLifecycleTest(storePath) {
  const service = new DeviceKeyService({ storePath });
  const created = await service.createDeviceKey("allow_os_protected_nonextractable");
  assert.equal(created.algorithm, "ecdsa_p256_sha256");
  assert.equal(created.protectionClass, "os_protected_nonextractable");
  const fetched = await service.getDeviceKeyPublic(created.keyId);
  assert.deepEqual(fetched, created);

  const payload = Buffer.from([0x00, 0xff, 0x43, 0x00, 0x80, 0x7f]);
  const signed = await service.signDeviceKey(created.keyId, payload);
  assert.equal(signed.algorithm, "ecdsa_p256_sha256");
  const publicKey = crypto.createPublicKey({
    format: "der",
    key: Buffer.from(created.publicKeySpkiDerBase64, "base64"),
    type: "spki",
  });
  assert.equal(crypto.verify("sha256", payload, publicKey, Buffer.from(signed.signatureDerBase64, "base64")), true);

  const surrounding = new Uint8Array([0xaa, 0x10, 0x00, 0xfe, 0x7f, 0xbb]);
  const byteView = surrounding.subarray(1, 5);
  const viewSignature = await service.signDeviceKey(created.keyId, byteView);
  assert.equal(
    crypto.verify("sha256", Buffer.from(byteView), publicKey, Buffer.from(viewSignature.signatureDerBase64, "base64")),
    true,
  );
  assert.equal(
    crypto.verify("sha256", Buffer.from(surrounding), publicKey, Buffer.from(viewSignature.signatureDerBase64, "base64")),
    false,
  );

  const serialized = fs.readFileSync(storePath, "utf8");
  const parsed = JSON.parse(serialized);
  assert.equal(parsed.schemaVersion, 1);
  assert.equal(typeof parsed.keys[created.keyId].encryptedPrivateKeyBase64, "string");
  assert.equal(Object.hasOwn(parsed.keys[created.keyId], "privateKeyPkcs8DpapiBase64"), false);
  assert.equal(serialized.includes("BEGIN PRIVATE KEY"), false);

  await service.deleteDeviceKey(created.keyId);
  await assert.rejects(() => service.getDeviceKeyPublic(created.keyId), { code: "KEY_NOT_FOUND" });
  return { algorithm: created.algorithm, rawBufferAndUint8ArrayVerified: true, signatureVerified: true };
}

async function storeFilenameTest(tempDirectory) {
  const resolved = resolveStorePath({ codexHome: tempDirectory });
  assert.equal(path.basename(resolved), "remote-control-device-keys.windows.json");
  assert.equal(path.dirname(resolved), path.resolve(tempDirectory));
  const powershellPath = resolveWindowsPowerShellPath();
  assert.equal(path.win32.isAbsolute(powershellPath), true);
  assert.equal(path.win32.basename(powershellPath).toLowerCase(), "powershell.exe");
  assert.equal(fs.existsSync(powershellPath), true);
  const windowsRoots = [process.env.SystemRoot, process.env.SYSTEMROOT, process.env.WINDIR, process.env.windir]
    .filter((value) => typeof value === "string" && path.win32.isAbsolute(value.trim()))
    .map((value) => `${path.win32.normalize(value.trim()).toLowerCase()}\\`);
  assert.equal(windowsRoots.some((root) => powershellPath.toLowerCase().startsWith(root)), true);
  return { filename: path.basename(resolved), powershellAbsolute: true };
}

async function protectionModeTest(storePath) {
  const service = new DeviceKeyService({ storePath });
  await assert.rejects(() => service.createDeviceKey("hardware_only"), { code: "PROTECTION_MODE_UNSUPPORTED" });
  assert.equal(fs.existsSync(storePath), false);
  return { rejected: true };
}

async function malformedPreservationTest(storePath) {
  const original = "{\"schemaVersion\":1,\"keys\":[]}\n";
  fs.writeFileSync(storePath, original, "utf8");
  const service = new DeviceKeyService({ storePath });
  await assert.rejects(() => service.createDeviceKey("allow_os_protected_nonextractable"));
  assert.equal(fs.readFileSync(storePath, "utf8"), original);
  return { preservedByteForByte: true };
}

async function legacyStoreTest(storePath) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = Buffer.from(privateKey.export({ format: "pem", type: "pkcs8" }), "utf8");
  const protectedPem = await runDpapi("protect", pem);
  const keyId = "legacy-self-test-key";
  const validRecord = {
    algorithm: "ecdsa_p256_sha256",
    encryptedPrivateKeyBase64: protectedPem.toString("base64"),
    keyId,
    protectionClass: "os_protected_nonextractable",
    publicKeySpkiDerBase64: publicKey.export({ format: "der", type: "spki" }).toString("base64"),
  };

  const mismatchedRaw = `${JSON.stringify({ [keyId]: { ...validRecord, keyId: "different-inner-key" } })}\n`;
  fs.writeFileSync(storePath, mismatchedRaw, "utf8");
  const mismatchedService = new DeviceKeyService({ storePath });
  await assert.rejects(() => mismatchedService.getDeviceKeyPublic(keyId), { code: "STORE_MALFORMED" });
  assert.equal(fs.readFileSync(storePath, "utf8"), mismatchedRaw);

  const unknownFieldRaw = `${JSON.stringify({ [keyId]: { ...validRecord, unexpected: true } })}\n`;
  fs.writeFileSync(storePath, unknownFieldRaw, "utf8");
  const unknownFieldService = new DeviceKeyService({ storePath });
  await assert.rejects(() => unknownFieldService.getDeviceKeyPublic(keyId), { code: "STORE_MALFORMED" });
  assert.equal(fs.readFileSync(storePath, "utf8"), unknownFieldRaw);

  fs.writeFileSync(storePath, `${JSON.stringify({ [keyId]: validRecord })}\n`, "utf8");
  pem.fill(0);
  protectedPem.fill(0);

  const service = new DeviceKeyService({ storePath });
  const payload = Buffer.from("legacy-pem", "utf8");
  const signed = await service.signDeviceKey(keyId, payload);
  assert.equal(crypto.verify("sha256", payload, publicKey, Buffer.from(signed.signatureDerBase64, "base64")), true);
  const added = await service.createDeviceKey("allow_os_protected_nonextractable");
  const migrated = JSON.parse(fs.readFileSync(storePath, "utf8"));
  assert.equal(migrated.schemaVersion, 1);
  assert.equal(typeof migrated.keys[keyId].encryptedPrivateKeyBase64, "string");
  await service.deleteDeviceKey(keyId);
  await service.deleteDeviceKey(added.keyId);
  return { keyIdMismatchRejected: true, migratedToSchemaVersion: 1, signatureVerified: true, unknownFieldRejected: true };
}

function hostBuiltin(name) {
  if (typeof process.getBuiltinModule === "function") {
    return process.getBuiltinModule(name);
  }
  return require(name);
}

function processFacade(getBuiltinModule) {
  const facade = {
    env: process.env,
    execPath: process.execPath,
    pid: process.pid,
    platform: process.platform,
  };
  if (typeof getBuiltinModule === "function") {
    facade.getBuiltinModule = getBuiltinModule;
  }
  return facade;
}

function loadBridgeInVm(root, { getBuiltinModule, requireBuiltin } = {}) {
  const globals = {
    Buffer,
    clearTimeout,
    console,
    process: processFacade(getBuiltinModule),
    setTimeout,
  };
  if (typeof requireBuiltin === "function") {
    globals.require = requireBuiltin;
  }
  const context = vm.createContext(globals);
  context.globalThis = context;
  const source = fs.readFileSync(path.join(root, "..", "src", "runtime", "main-payload.js"), "utf8");
  return vm.runInContext(source, context, { filename: "main-payload.js" });
}

async function vmDeviceKeyLifecycle(bridge, storePath, payloadText) {
  const service = new bridge.DeviceKeyService({ storePath });
  const created = await service.createDeviceKey("allow_os_protected_nonextractable");
  const payload = Buffer.from(payloadText, "utf8");
  const signed = await service.signDeviceKey(created.keyId, payload);
  const publicKey = crypto.createPublicKey({
    format: "der",
    key: Buffer.from(created.publicKeySpkiDerBase64, "base64"),
    type: "spki",
  });
  assert.equal(crypto.verify("sha256", payload, publicKey, Buffer.from(signed.signatureDerBase64, "base64")), true);
  await service.deleteDeviceKey(created.keyId);
}

function restrictedCryptoBuiltin(name) {
  if (name === "crypto" || name === "node:crypto") {
    return crypto.webcrypto;
  }
  return hostBuiltin(name);
}

async function electronRestrictedCryptoFallbackTest(root, storePath) {
  assert.equal(typeof crypto.webcrypto.generateKeyPair, "undefined");
  assert.equal(typeof crypto.webcrypto.createPrivateKey, "undefined");
  const bridge = loadBridgeInVm(root, { getBuiltinModule: restrictedCryptoBuiltin });
  await vmDeviceKeyLifecycle(bridge, storePath, "electron-restricted-crypto");
  const report = bridge.installMainBridge({
    interceptModules: false,
    scheduleInspectorClose: false,
    spoofPlatform: false,
    storePath,
  });
  assert.equal(report.installed, true);
  assert.equal(report.status, "installed");
  return { nativeCryptoLoadedWithCreateRequire: true, signatureVerified: true };
}

async function nodeWithoutGetBuiltinModuleTest(root, storePath) {
  const bridge = loadBridgeInVm(root, { requireBuiltin: restrictedCryptoBuiltin });
  await vmDeviceKeyLifecycle(bridge, storePath, "node-without-get-builtin-module");
  return { outerRequireFallbackVerified: true, signatureVerified: true };
}

async function synchronousKeyGenerationFallbackTest(root, storePath) {
  const syncOnlyCrypto = Object.create(crypto);
  Object.defineProperty(syncOnlyCrypto, "generateKeyPair", { value: undefined });
  assert.equal(typeof syncOnlyCrypto.generateKeyPair, "undefined");
  assert.equal(typeof syncOnlyCrypto.generateKeyPairSync, "function");

  const moduleFacade = Object.create(hostBuiltin("module"));
  Object.defineProperty(moduleFacade, "createRequire", {
    value() {
      return (name) => name === "node:crypto" ? syncOnlyCrypto : require(name);
    },
  });
  const resolveBuiltin = (name) => {
    if (name === "module" || name === "node:module") {
      return moduleFacade;
    }
    return restrictedCryptoBuiltin(name);
  };
  const bridge = loadBridgeInVm(root, { getBuiltinModule: resolveBuiltin });
  await vmDeviceKeyLifecycle(bridge, storePath, "synchronous-key-generation");
  return { signatureVerified: true, synchronousGenerationVerified: true };
}

async function incompleteCryptoRejectionTest(root) {
  const moduleFacade = Object.create(hostBuiltin("module"));
  Object.defineProperty(moduleFacade, "createRequire", {
    value() {
      return () => crypto.webcrypto;
    },
  });
  const resolveBuiltin = (name) => {
    if (name === "module" || name === "node:module") {
      return moduleFacade;
    }
    return restrictedCryptoBuiltin(name);
  };
  assert.throws(() => loadBridgeInVm(root, { getBuiltinModule: resolveBuiltin }), { code: "CRYPTO_UNAVAILABLE" });
  return { incompleteCryptoRejected: true };
}

async function rendererPayloadTest(root) {
  const avatarOverlay = {
    title: "Codex",
    type: "page",
    url: "app://-/index.html?initialRoute=%2Favatar-overlay",
  };
  const exactCodexPage = {
    title: "Codex",
    type: "page",
    url: "app://-/index.html",
  };
  assert.equal(chooseTarget([avatarOverlay, exactCodexPage], "renderer"), exactCodexPage);
  assert.throws(() => chooseTarget([avatarOverlay], "renderer"), { code: "TARGET_NOT_FOUND" });

  const calls = [];
  const client = {
    checkGate(gate) {
      calls.push(gate);
      return gate === "unrelated-gate";
    },
    getConfig(name) {
      return { name };
    },
    getFeatureGate(gate) {
      return gate === "782640499" ? targetFeatureGate : unrelatedFeatureGate;
    },
    getGate(gate) {
      return gate === "782640499" ? targetGatePromise : unrelatedGatePromise;
    },
    getGateValue(gate) {
      return gate === "782640499" ? 1 : 7;
    },
  };
  const targetFeatureGate = { enabled: true, metadata: { source: "target" }, value: true };
  const unrelatedFeatureGate = { enabled: true, metadata: { source: "unrelated" }, value: true };
  const targetGatePromise = Promise.resolve({ enabled: true, metadata: { async: true }, value: true });
  const unrelatedGatePromise = Promise.resolve({ enabled: true, metadata: { async: "unrelated" }, value: true });
  const context = vm.createContext({
    __STATSIG__: { clients: [client] },
    clearInterval() {},
    console,
    setInterval() {
      return { unref() {} };
    },
  });
  context.globalThis = context;
  const source = fs.readFileSync(path.join(root, "..", "src", "runtime", "renderer-payload.js"), "utf8");
  const initial = vm.runInContext(source, context, { filename: "renderer-payload.js" });
  assert.equal(initial.proof, true);
  assert.equal(client.checkGate("782640499"), false);
  assert.equal(client.checkGate("unrelated-gate"), true);
  assert.deepEqual(client.getConfig("kept"), { name: "kept" });
  const shaped = client.getFeatureGate("782640499");
  assert.notEqual(shaped, targetFeatureGate);
  assert.equal(shaped.value, false);
  assert.equal(shaped.enabled, false);
  assert.deepEqual(shaped.metadata, { source: "target" });
  assert.equal(targetFeatureGate.value, true);
  assert.equal(targetFeatureGate.enabled, true);
  assert.equal(client.getFeatureGate("unrelated-gate"), unrelatedFeatureGate);

  const promised = client.getGate("782640499");
  assert.equal(typeof promised.then, "function");
  const promisedShape = await promised;
  assert.equal(promisedShape.value, false);
  assert.equal(promisedShape.enabled, false);
  assert.deepEqual(promisedShape.metadata, { async: true });
  assert.equal(client.getGate("unrelated-gate"), unrelatedGatePromise);
  assert.equal(client.getGateValue("782640499"), false);
  assert.equal(client.getGateValue("unrelated-gate"), 7);

  const delayedClient = { checkGate() { return true; } };
  context.__STATSIG__.clients.push(delayedClient);
  const delayed = context.__CODEX_STATSIG_GATE_BRIDGE__.scan();
  assert.equal(delayedClient.checkGate(782640499), false);
  assert.equal(delayed.proof, true);
  assert(calls.includes("unrelated-gate"));
  assert.equal(calls.includes("782640499"), false);
  return {
    codexTargetFailClosed: true,
    delayedClientCovered: true,
    promiseShapePreserved: true,
    unrelatedDelegated: true,
  };
}

async function orchestratorModesTest(root) {
  const mainPayload = path.join(root, "..", "src", "runtime", "main-payload.js");
  const legacy = parseArguments([
    "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000", "--main-payload", mainPayload,
  ]);
  assert.equal(legacy.mode, "full");
  assert.equal(legacy.mainPort, 41002);
  const explicitFull = parseArguments([
    "--mode", "full", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000", "--main-payload", mainPayload,
  ]);
  assert.equal(explicitFull.mode, "full");
  const rendererOnly = parseArguments([
    "--mode", "renderer", "--renderer-port", "41001", "--timeout-ms", "30000",
  ]);
  assert.deepEqual(
    Object.keys(rendererOnly).sort(),
    ["help", "mode", "rendererPort", "timeoutMs"].sort(),
  );
  assert.throws(
    () => parseArguments(["--mode", "renderer", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000"]),
    { code: "ARGUMENT_MODE_CONFLICT" },
  );
  assert.throws(
    () => parseArguments(["--mode", "renderer", "--renderer-port", "41001", "--timeout-ms", "30000", "--main-payload", mainPayload]),
    { code: "ARGUMENT_MODE_CONFLICT" },
  );

  const calls = [];
  const fakeClient = {
    async call(method, parameters) {
      calls.push({ method, parameters });
      if (method === "Page.addScriptToEvaluateOnNewDocument") return { identifier: "renderer-script-1" };
      return {};
    },
    close() { calls.push({ method: "close" }); },
  };
  const result = await runRendererBridge(rendererOnly, {
    connectTarget: async (target, port) => {
      calls.push({ method: "connectTarget", port, target });
      assert.equal(port, 41001);
      return fakeClient;
    },
    evaluate: async (_client, expression) => {
      if (expression.includes("__CODEX_STATSIG_GATE_BRIDGE__")) {
        return { proof: true, targetGate: "782640499" };
      }
      return {
        allFalse: true,
        checkMethods: 0,
        installedClients: 0,
        installedMethods: 0,
        passedMethods: 0,
        proof: true,
        scans: 1,
        structuredMethods: 0,
        targetGate: "782640499",
      };
    },
    readPayload: () => "globalThis.__rendererInstalled = true; ({ proof: true, targetGate: '782640499' })",
    waitForTarget: async (port, kind) => {
      calls.push({ method: "waitForTarget", port, kind });
      assert.equal(kind, "renderer");
      return { id: "renderer-1", type: "page", url: "app://-/index.html" };
    },
  });
  assert.equal(result.ok, true);
  assert.equal(result.protocolVersion, 1);
  assert.equal(Object.hasOwn(result, "main"), false);
  assert.equal(result.renderer.targetUrl, "app://-/index.html");
  assert.deepEqual(result.renderer.currentDocument, { installed: true });
  assert.equal(result.renderer.newDocumentScriptInstalled, true);
  assert.deepEqual(result.renderer.probe, { proof: true, targetGate: "782640499" });
  assert.equal(calls.filter((entry) => entry.method === "connectTarget").length, 1);
  assert.equal(calls.some((entry) => entry.port === 41002), false);
  assert.equal(calls.some((entry) => entry.method === "Runtime.enable"), true);
  assert.equal(calls.some((entry) => entry.method === "Page.addScriptToEvaluateOnNewDocument"), true);
  return { defaultFull: true, exactRendererTarget: true, rendererNeverConnectedMain: true };
}

async function orchestratorProbeModeTest(root) {
  const mainPayload = path.join(root, "..", "src", "runtime", "main-payload.js");
  const probeOptions = parseArguments([
    "--mode", "probe", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000",
  ]);
  assert.deepEqual(
    Object.keys(probeOptions).sort(),
    ["help", "mainPort", "mode", "rendererPort", "timeoutMs"].sort(),
  );
  assert.equal(probeOptions.mode, "probe");
  assert.equal(probeOptions.rendererPort, 41001);
  assert.equal(probeOptions.mainPort, 41002);
  assert.equal(probeOptions.timeoutMs, 30000);
  for (const argv of [
    ["--mode", "probe", "--renderer-port", "41001", "--timeout-ms", "30000"],
    ["--mode", "probe", "--renderer-port", "41001", "--main-port", "41001", "--timeout-ms", "30000"],
    ["--mode", "probe", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000", "--main-payload", mainPayload],
    ["--mode", "Probe", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000"],
  ]) {
    assert.throws(() => parseArguments(argv));
  }

  const rendererSource = fs.readFileSync(path.join(root, "..", "src", "runtime", "renderer-payload.js"), "utf8");
  function executeRealRendererProbe(statsig) {
    const sandbox = {
      clearInterval() {},
      console,
      setInterval() { return { unref() {} }; },
    };
    if (statsig !== undefined) sandbox.__STATSIG__ = statsig;
    const context = vm.createContext(sandbox);
    context.globalThis = context;
    vm.runInContext(rendererSource, context, { filename: "renderer-payload.js" });
    return context.__CODEX_STATSIG_GATE_BRIDGE__.probe();
  }
  const actualPositiveProbe = executeRealRendererProbe({ clients: [{ checkGate() { return true; } }] });
  const actualNegativeProbe = executeRealRendererProbe(undefined);
  assert.deepEqual(
    Object.keys(actualPositiveProbe).sort(),
    ["allFalse", "checkMethods", "installedClients", "installedMethods", "passedMethods", "proof", "scans", "structuredMethods", "targetGate"].sort(),
  );
  assert.equal(actualPositiveProbe.proof, true);
  assert.equal(actualNegativeProbe.proof, false);

  const exactTarget = { id: "renderer-1", type: "page", url: "app://-/index.html", webSocketDebuggerUrl: "ws://ignored-host/devtools/page/1" };
  function fakeProbeDependencies({
    main = { code: "ECONNREFUSED", state: "error" },
    targets = [exactTarget],
    evaluation = actualPositiveProbe,
    failAt = null,
    calls = [],
  } = {}) {
    const client = {
      async call(method) {
        calls.push({ method: `client.${method}` });
        throw new Error(`unexpected direct CDP call: ${method}`);
      },
      close() { calls.push({ method: "close" }); },
    };
    return {
      calls,
      dependencies: {
        checkPortOnce: async (port, timeoutMs) => {
          calls.push({ method: "checkPortOnce", port, timeoutMs });
          assert.equal(port, 41002);
          assert(timeoutMs >= 1 && timeoutMs <= 300);
          if (failAt === "main") throw Object.assign(new Error("main failed"), { code: "EOTHER" });
          return main;
        },
        discoverTargets: async (port, timeoutMs) => {
          calls.push({ method: "discoverTargets", port, timeoutMs });
          assert.equal(port, 41001);
          assert(timeoutMs > 0 && timeoutMs <= 30000);
          if (failAt === "discover") throw new Error("discovery failed");
          return targets;
        },
        connectTarget: async (target, port, timeoutMs) => {
          calls.push({ method: "connectTarget", port, target, timeoutMs });
          assert.equal(target, exactTarget);
          assert.equal(port, 41001);
          if (failAt === "connect") throw new Error("connect failed");
          return client;
        },
        evaluate: async (connected, expression, timeoutMs) => {
          calls.push({ expression, method: "evaluate", timeoutMs });
          assert.equal(connected, client);
          assert.equal(expression, "globalThis.__CODEX_STATSIG_GATE_BRIDGE__?.probe?.() ?? null");
          if (failAt === "evaluate") throw new Error("evaluation failed");
          return evaluation;
        },
      },
    };
  }

  const positiveFixture = fakeProbeDependencies();
  const positive = await runProbeBridge(probeOptions, positiveFixture.dependencies);
  assert.deepEqual(positive, {
    ok: true,
    protocolVersion: 1,
    main: { inspectorPortClosed: { confirmed: true, code: "ECONNREFUSED" } },
    renderer: { targetUrl: "app://-/index.html", probe: { proof: true, targetGate: "782640499" } },
  });
  assert.deepEqual(
    positiveFixture.calls.map((entry) => entry.method),
    ["checkPortOnce", "discoverTargets", "connectTarget", "evaluate", "close"],
  );
  assert.equal(positiveFixture.calls.some((entry) => /^client\.(?:Runtime|Page|Debugger|Target)\./u.test(entry.method)), false);
  assert.equal(positiveFixture.calls.some((entry) => entry.expression?.includes("scan") || entry.expression?.includes("install")), false);

  for (const [main, expected] of [
    [{ state: "open" }, { confirmed: false, code: "OPEN" }],
    [{ state: "timeout" }, { confirmed: false, code: "TIMEOUT" }],
  ]) {
    const fixture = fakeProbeDependencies({ main });
    const result = await runProbeBridge(probeOptions, fixture.dependencies);
    assert.deepEqual(result.main.inspectorPortClosed, expected);
  }

  const noTargetFixture = fakeProbeDependencies({ targets: [{ id: "other", type: "page", url: "app://-/settings.html" }] });
  const noTarget = await runProbeBridge(probeOptions, noTargetFixture.dependencies);
  assert.deepEqual(noTarget.renderer, { targetUrl: null, probe: { proof: false, targetGate: null } });
  assert.deepEqual(noTargetFixture.calls.map((entry) => entry.method), ["checkPortOnce", "discoverTargets"]);

  for (const [evaluation, expectedGate] of [
    [null, null],
    [actualNegativeProbe, "782640499"],
  ]) {
    const fixture = fakeProbeDependencies({ evaluation });
    const result = await runProbeBridge(probeOptions, fixture.dependencies);
    assert.deepEqual(result.renderer, {
      targetUrl: "app://-/index.html",
      probe: { proof: false, targetGate: expectedGate },
    });
    assert.equal(fixture.calls.at(-1).method, "close");
  }

  const mutateRealProbe = (mutator) => {
    const value = JSON.parse(JSON.stringify(actualPositiveProbe));
    mutator(value);
    return value;
  };
  const malformedEvaluations = [
    false,
    0,
    "invalid",
    [],
    { proof: false },
    { proof: false, targetGate: null },
    { proof: false, targetGate: "782640499" },
    { proof: true, targetGate: "782640499" },
    { proof: "false", targetGate: null },
    mutateRealProbe((value) => { delete value.scans; }),
    mutateRealProbe((value) => { value.extra = true; }),
    mutateRealProbe((value) => { value.targetGate = "different"; }),
    mutateRealProbe((value) => { value.proof = false; }),
    mutateRealProbe((value) => { value.allFalse = false; }),
    mutateRealProbe((value) => { value.checkMethods = 0; }),
    mutateRealProbe((value) => { value.passedMethods = 0; }),
    mutateRealProbe((value) => { value.installedMethods += 1; }),
    mutateRealProbe((value) => { value.installedClients = value.installedMethods + 1; }),
    mutateRealProbe((value) => { value.scans = -1; }),
    mutateRealProbe((value) => { value.structuredMethods = 0.5; }),
    mutateRealProbe((value) => { value.installedMethods = Number.MAX_SAFE_INTEGER + 1; }),
  ];
  for (const evaluation of malformedEvaluations) {
    const fixture = fakeProbeDependencies({ evaluation });
    await assert.rejects(() => runProbeBridge(probeOptions, fixture.dependencies));
    assert.equal(fixture.calls.at(-1).method, "close");
  }

  const duplicateFixture = fakeProbeDependencies({ targets: [exactTarget, { ...exactTarget, id: "renderer-2" }] });
  await assert.rejects(() => runProbeBridge(probeOptions, duplicateFixture.dependencies));
  assert.deepEqual(duplicateFixture.calls.map((entry) => entry.method), ["checkPortOnce", "discoverTargets"]);

  for (const failAt of ["main", "discover", "connect", "evaluate"]) {
    const fixture = fakeProbeDependencies({ failAt });
    await assert.rejects(() => runProbeBridge(probeOptions, fixture.dependencies));
    if (failAt === "evaluate") assert.equal(fixture.calls.at(-1).method, "close");
  }

  const help = childProcess.spawnSync(process.execPath, [path.join(root, "..", "src", "runtime", "orchestrator.js"), "--help"], {
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /full\|renderer\|probe/u);
  return { completedNegativeStrict: true, fakeOnly: true, operationalFailuresRejected: true, probeMode: true };
}

async function inspectorClosureTest(root, tempDirectory) {
  const port = await reservePort();
  assert(Number.isInteger(port));
  const payloadPath = path.join(root, "..", "src", "runtime", "main-payload.js");
  const childStore = path.join(tempDirectory, "inspector-child-store.json");
  const childCode = [
    `const bridge = require(${JSON.stringify(payloadPath)});`,
    `Promise.resolve(bridge.installMainBridge({interceptModules:false,spoofPlatform:false,storePath:${JSON.stringify(childStore)},inspectorCloseDelayMs:750})).then(() => {`,
    "  process.stdout.write('SELFTEST_READY\\n');",
    "  setInterval(() => {}, 1000);",
    "});",
  ].join("\n");
  const child = childProcess.spawn(process.execPath, [`--inspect=127.0.0.1:${port}`, "-e", childCode], {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stderr.resume();
  try {
    await waitForOutput(child.stdout, "SELFTEST_READY", 5_000);
    const open = await checkPortOnce(port, 500);
    assert.equal(open.state, "open");
    const closure = await waitForExplicitRefusal(port, 5_000);
    assert.equal(closure.code, "ECONNREFUSED");
    assert.equal(closure.confirmed, true);
    return closure;
  } finally {
    child.kill();
    await waitForChildExit(child, 2_000);
  }
}

async function main() {
  const root = __dirname;
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "codex-cleanroom-selftest-"));
  const tests = [
    ["javascript-syntax", () => syntaxTest(root)],
    ["store-filename", () => storeFilenameTest(tempDirectory)],
    ["protection-mode-rejection", () => protectionModeTest(path.join(tempDirectory, "rejected.json"))],
    ["create-sign-verify-delete", () => deviceKeyLifecycleTest(path.join(tempDirectory, "lifecycle.json"))],
    ["malformed-store-preservation", () => malformedPreservationTest(path.join(tempDirectory, "malformed.json"))],
    ["legacy-pem-store", () => legacyStoreTest(path.join(tempDirectory, "legacy.json"))],
    ["electron-restricted-crypto-fallback", () => electronRestrictedCryptoFallbackTest(root, path.join(tempDirectory, "electron-crypto.json"))],
    ["node-without-get-builtin-module", () => nodeWithoutGetBuiltinModuleTest(root, path.join(tempDirectory, "node-22-0.json"))],
    ["synchronous-key-generation-fallback", () => synchronousKeyGenerationFallbackTest(root, path.join(tempDirectory, "sync-crypto.json"))],
    ["incomplete-crypto-rejection", () => incompleteCryptoRejectionTest(root)],
    ["renderer-existing-and-delayed", () => rendererPayloadTest(root)],
    ["orchestrator-full-renderer-modes", () => orchestratorModesTest(root)],
    ["orchestrator-read-only-probe-mode", () => orchestratorProbeModeTest(root)],
    ["inspector-explicit-refusal", () => inspectorClosureTest(root, tempDirectory)],
  ];
  const results = [];
  let ok = true;
  try {
    for (const [name, test] of tests) {
      const startedAt = Date.now();
      try {
        const details = await test();
        results.push({ details, durationMs: Date.now() - startedAt, name, ok: true });
      } catch (error) {
        ok = false;
        results.push({
          durationMs: Date.now() - startedAt,
          error: { code: error?.code ?? "TEST_FAILED", message: error?.message ?? "Test failed" },
          name,
          ok: false,
        });
      }
    }
  } finally {
    const resolvedTemp = path.resolve(tempDirectory);
    const resolvedRoot = path.resolve(os.tmpdir());
    if (resolvedTemp.startsWith(`${resolvedRoot}${path.sep}`) && path.basename(resolvedTemp).startsWith("codex-cleanroom-selftest-")) {
      fs.rmSync(resolvedTemp, { force: true, recursive: true });
    }
  }
  process.stdout.write(`${JSON.stringify({ ok, results }, null, 2)}\n`);
  process.exitCode = ok ? 0 : 1;
}

main().catch((error) => {
  process.stdout.write(`${JSON.stringify({ error: error?.message ?? "Self-test failed", ok: false })}\n`);
  process.exitCode = 1;
});
