#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const { connectTarget, discoverTargets, evaluate } = require("./lib/cdp.js");

const MAIN_OPTIONS_SLOT = "__CODEX_CLEANROOM_MAIN_OPTIONS__";

function cliError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function parseInteger(value, name, minimum, maximum) {
  if (!/^[0-9]+$/u.test(value ?? "")) {
    throw cliError("ARGUMENT_INVALID", `${name} must be an integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw cliError("ARGUMENT_INVALID", `${name} is outside its allowed range`);
  }
  return parsed;
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--help" || token === "-h") {
      return { help: true };
    }
    if (!token.startsWith("--")) {
      throw cliError("ARGUMENT_UNKNOWN", `Unexpected argument: ${token}`);
    }
    const name = token.slice(2);
    if (!["renderer-port", "main-port", "timeout-ms", "main-payload"].includes(name) || values.has(name)) {
      throw cliError("ARGUMENT_UNKNOWN", `Unknown or duplicate option: ${token}`);
    }
    const value = argv[index + 1];
    if (value == null || value.startsWith("--")) {
      throw cliError("ARGUMENT_MISSING", `Missing value for ${token}`);
    }
    values.set(name, value);
    index += 1;
  }
  for (const required of ["renderer-port", "main-port", "timeout-ms", "main-payload"]) {
    if (!values.has(required)) {
      throw cliError("ARGUMENT_MISSING", `Required option is missing: --${required}`);
    }
  }
  return {
    help: false,
    mainPayload: path.resolve(values.get("main-payload")),
    mainPort: parseInteger(values.get("main-port"), "main port", 1, 65_535),
    rendererPort: parseInteger(values.get("renderer-port"), "renderer port", 1, 65_535),
    timeoutMs: parseInteger(values.get("timeout-ms"), "timeout", 500, 300_000),
  };
}

function remaining(deadline) {
  const value = deadline - Date.now();
  if (value < 25) {
    throw cliError("DEADLINE_EXCEEDED", "Compatibility bridge timed out");
  }
  return value;
}

function chooseTarget(targets, kind) {
  if (kind === "renderer") {
    const exactUrl = targets.find(
      (candidate) =>
        (candidate.type === "page" || candidate.type === "webview") && candidate.url === "app://-/index.html",
    );
    if (exactUrl) {
      return exactUrl;
    }
    throw cliError("TARGET_NOT_FOUND", "No page or webview target with the exact Codex renderer URL was found");
  }

  const preferences = ["node", "other"];
  for (const type of preferences) {
    const target = targets.find((candidate) => candidate.type === type);
    if (target) {
      return target;
    }
  }
  const fallback = targets[0];
  if (!fallback) {
    throw cliError("TARGET_NOT_FOUND", `No ${kind} debugger target was found`);
  }
  return fallback;
}

async function waitForTarget(port, kind, deadline) {
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await discoverTargets(port, Math.min(1_000, remaining(deadline)));
      return chooseTarget(targets, kind);
    } catch (error) {
      lastError = error;
      await delay(Math.min(75, Math.max(1, deadline - Date.now())));
    }
  }
  const error = cliError("TARGET_NOT_READY", `Timed out waiting for the ${kind} debugger target`);
  error.cause = lastError;
  throw error;
}

function sanitizeReport(value, depth = 0) {
  if (depth > 6) {
    return "[truncated]";
  }
  if (value === null || typeof value === "boolean" || typeof value === "number") {
    return value;
  }
  if (typeof value === "string") {
    return value.slice(0, 300);
  }
  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => sanitizeReport(item, depth + 1));
  }
  if (typeof value === "object") {
    const output = {};
    for (const [key, child] of Object.entries(value).slice(0, 100)) {
      if (/(?:private|secret|token|signature|signedPayload|cipher|credential)/iu.test(key)) {
        output[key] = "[redacted]";
      } else {
        output[key] = sanitizeReport(child, depth + 1);
      }
    }
    return output;
  }
  return String(value).slice(0, 100);
}

function readPayload(payloadPath) {
  let stat;
  try {
    stat = fs.statSync(payloadPath);
  } catch {
    throw cliError("PAYLOAD_UNREADABLE", "Main payload file cannot be read");
  }
  if (!stat.isFile() || stat.size === 0 || stat.size > 4 * 1024 * 1024) {
    throw cliError("PAYLOAD_INVALID", "Main payload must be a non-empty file no larger than 4 MiB");
  }
  try {
    return fs.readFileSync(payloadPath, "utf8");
  } catch {
    throw cliError("PAYLOAD_UNREADABLE", "Main payload file cannot be read");
  }
}

function injectionExpression(source) {
  const options = {
    inject: true,
    inspectorCloseDelayMs: 500,
    scheduleInspectorClose: true,
  };
  return [
    "(() => {",
    `  globalThis[${JSON.stringify(MAIN_OPTIONS_SLOT)}] = ${JSON.stringify(options)};`,
    "  try {",
    `    return (0, eval)(${JSON.stringify(source)});`,
    "  } finally {",
    `    delete globalThis[${JSON.stringify(MAIN_OPTIONS_SLOT)}];`,
    "  }",
    "})()",
  ].join("\n");
}

function checkPortOnce(port, timeoutMs = 300) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ family: 4, host: "127.0.0.1", port });
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs, () => done({ state: "timeout" }));
    socket.once("connect", () => done({ state: "open" }));
    socket.once("error", (error) => done({ code: error?.code ?? "UNKNOWN", state: "error" }));
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForExplicitRefusal(port, timeoutMs) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let attempts = 0;
  let lastState = "unknown";
  while (Date.now() < deadline) {
    attempts += 1;
    const result = await checkPortOnce(port, Math.min(300, Math.max(25, deadline - Date.now())));
    lastState = result.code ?? result.state;
    if (result.state === "error" && result.code === "ECONNREFUSED") {
      return { attempts, code: "ECONNREFUSED", confirmed: true, elapsedMs: Date.now() - startedAt };
    }
    await delay(Math.min(75, Math.max(1, deadline - Date.now())));
  }
  const error = cliError("INSPECTOR_NOT_CLOSED", "Main Inspector port did not reach explicit ECONNREFUSED");
  error.lastState = lastState;
  throw error;
}

async function installMainPayload(options, source, deadline) {
  const target = await waitForTarget(options.mainPort, "main", deadline);
  const client = await connectTarget(target, options.mainPort, remaining(deadline));
  let report;
  try {
    await client.call("Runtime.enable", {}, remaining(deadline));
    report = await evaluate(client, injectionExpression(source), remaining(deadline), false);
  } finally {
    client.close();
  }
  const closure = await waitForExplicitRefusal(options.mainPort, remaining(deadline));
  return { closure, report: sanitizeReport(report) };
}

async function waitForRendererProof(client, deadline) {
  while (Date.now() < deadline) {
    const probe = await evaluate(
      client,
      "globalThis.__CODEX_STATSIG_GATE_BRIDGE__?.scan?.() ?? null",
      remaining(deadline),
    );
    if (probe?.proof === true && probe?.targetGate === "782640499") {
      return sanitizeReport(probe);
    }
    await delay(Math.min(100, Math.max(1, deadline - Date.now())));
  }
  throw cliError("RENDERER_PROBE_FAILED", "Renderer payload did not prove the target gate override before timeout");
}

async function installRendererPayload(options, source, deadline) {
  const target = await waitForTarget(options.rendererPort, "renderer", deadline);
  const client = await connectTarget(target, options.rendererPort, remaining(deadline));
  try {
    await client.call("Runtime.enable", {}, remaining(deadline));
    await client.call("Page.enable", {}, remaining(deadline));
    const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, remaining(deadline));
    const installReport = await evaluate(client, source, remaining(deadline));
    const probe = await waitForRendererProof(client, deadline);
    return {
      currentDocument: sanitizeReport(installReport),
      newDocumentScriptInstalled: typeof persistent.identifier === "string",
      probe,
    };
  } finally {
    client.close();
  }
}

async function runBridge(options) {
  const deadline = Date.now() + options.timeoutMs;
  const mainSource = readPayload(options.mainPayload);
  const rendererSource = readPayload(path.join(__dirname, "renderer-payload.js"));
  let stage = "main-install";
  try {
    const main = await installMainPayload(options, mainSource, deadline);
    stage = "renderer-install";
    const renderer = await installRendererPayload(options, rendererSource, deadline);
    return {
      main: {
        inspectorPortClosed: main.closure,
        payloadReport: main.report,
      },
      ok: true,
      protocolVersion: 1,
      renderer,
    };
  } catch (error) {
    error.stage = error.stage ?? stage;
    throw error;
  }
}

function safeError(error) {
  const code = typeof error?.code === "string" ? error.code : "UNEXPECTED_ERROR";
  const message = typeof error?.message === "string" ? error.message.replace(/[\r\n]+/gu, " ").slice(0, 300) : "Unexpected error";
  return { code, message };
}

async function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArguments(argv);
    if (options.help) {
      process.stdout.write(`${JSON.stringify({
        ok: true,
        usage: "node orchestrator.js --renderer-port PORT --main-port PORT --timeout-ms MS --main-payload FILE",
      })}\n`);
      return 0;
    }
    const result = await runBridge(options);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ error: safeError(error), ok: false, stage: error?.stage ?? "arguments" })}\n`);
    return 1;
  }
}

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}

module.exports = {
  checkPortOnce,
  chooseTarget,
  injectionExpression,
  parseArguments,
  runBridge,
  waitForTarget,
  waitForExplicitRefusal,
};
