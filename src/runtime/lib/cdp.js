// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const http = require("node:http");

function transportError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function getJson(port, pathname, timeoutMs) {
  return new Promise((resolve, reject) => {
    const request = http.get(
      {
        agent: false,
        family: 4,
        headers: { Accept: "application/json", Connection: "close" },
        host: "127.0.0.1",
        path: pathname,
        port,
        timeout: timeoutMs,
      },
      (response) => {
        if (response.statusCode !== 200) {
          response.resume();
          reject(transportError("DISCOVERY_HTTP_STATUS", `Debugger discovery returned HTTP ${response.statusCode}`));
          return;
        }
        const chunks = [];
        let length = 0;
        response.on("data", (chunk) => {
          length += chunk.length;
          if (length > 8 * 1024 * 1024) {
            request.destroy(transportError("DISCOVERY_TOO_LARGE", "Debugger discovery response is too large"));
            return;
          }
          chunks.push(chunk);
        });
        response.on("end", () => {
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch {
            reject(transportError("DISCOVERY_INVALID_JSON", "Debugger discovery returned invalid JSON"));
          }
        });
      },
    );
    request.on("timeout", () => request.destroy(transportError("DISCOVERY_TIMEOUT", "Debugger discovery timed out")));
    request.on("error", reject);
  });
}

async function discoverTargets(port, timeoutMs) {
  let value;
  try {
    value = await getJson(port, "/json/list", timeoutMs);
  } catch (firstError) {
    if (firstError?.code !== "DISCOVERY_HTTP_STATUS") {
      throw firstError;
    }
    value = await getJson(port, "/json", timeoutMs);
  }
  if (!Array.isArray(value)) {
    throw transportError("DISCOVERY_INVALID_SHAPE", "Debugger discovery did not return a target list");
  }
  return value.filter((target) => target && typeof target.webSocketDebuggerUrl === "string");
}

function forceLoopbackWebSocketUrl(reportedUrl, port) {
  let parsed;
  try {
    parsed = new URL(reportedUrl);
  } catch {
    throw transportError("WEBSOCKET_URL_INVALID", "Debugger reported an invalid WebSocket URL");
  }
  if (parsed.protocol !== "ws:" || !parsed.pathname.startsWith("/")) {
    throw transportError("WEBSOCKET_URL_INVALID", "Debugger reported an unsupported WebSocket URL");
  }
  return `ws://127.0.0.1:${port}${parsed.pathname}${parsed.search}`;
}

function messageText(data) {
  if (typeof data === "string") {
    return Promise.resolve(data);
  }
  if (data instanceof ArrayBuffer) {
    return Promise.resolve(Buffer.from(data).toString("utf8"));
  }
  if (ArrayBuffer.isView(data)) {
    return Promise.resolve(Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8"));
  }
  if (data && typeof data.text === "function") {
    return data.text();
  }
  return Promise.reject(transportError("WEBSOCKET_MESSAGE_INVALID", "WebSocket returned an unsupported message"));
}

class JsonRpcWebSocket {
  constructor(url, options = {}) {
    this.url = url;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.eventHandlers = new Set();
  }

  connect() {
    if (this.socket) {
      return Promise.resolve(this);
    }
    return new Promise((resolve, reject) => {
      if (typeof WebSocket !== "function") {
        reject(transportError("WEBSOCKET_UNAVAILABLE", "Node.js WebSocket support is unavailable"));
        return;
      }
      const socket = new WebSocket(this.url);
      this.socket = socket;
      const timer = setTimeout(() => {
        try {
          socket.close();
        } catch {
          // Nothing else to clean up.
        }
        reject(transportError("WEBSOCKET_CONNECT_TIMEOUT", "WebSocket connection timed out"));
      }, this.timeoutMs);
      timer.unref?.();

      socket.addEventListener(
        "open",
        () => {
          clearTimeout(timer);
          resolve(this);
        },
        { once: true },
      );
      socket.addEventListener(
        "error",
        () => {
          clearTimeout(timer);
          reject(transportError("WEBSOCKET_CONNECT_FAILED", "WebSocket connection failed"));
        },
        { once: true },
      );
      socket.addEventListener("message", (event) => {
        messageText(event.data).then((text) => this._onMessage(text)).catch(() => {});
      });
      socket.addEventListener("close", () => {
        const error = transportError("WEBSOCKET_CLOSED", "WebSocket connection closed");
        for (const pending of this.pending.values()) {
          clearTimeout(pending.timer);
          pending.reject(error);
        }
        this.pending.clear();
      });
    });
  }

  _onMessage(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    if (Number.isInteger(message.id)) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        return;
      }
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        const detail = typeof message.error.message === "string"
          ? message.error.message.replace(/[\r\n]+/gu, " ").slice(0, 160)
          : "unknown error";
        pending.reject(transportError(
          "CDP_PROTOCOL_ERROR",
          `Debugger protocol error ${message.error.code ?? "unknown"} in ${pending.method}: ${detail}`,
        ));
      } else {
        pending.resolve(message.result ?? {});
      }
      return;
    }
    if (typeof message.method === "string") {
      for (const handler of this.eventHandlers) {
        try {
          handler(message.method, message.params ?? {});
        } catch {
          // Event consumers are isolated from transport processing.
        }
      }
    }
  }

  onEvent(handler) {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  call(method, params = {}, timeoutMs = this.timeoutMs) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(transportError("WEBSOCKET_NOT_OPEN", "WebSocket is not open"));
    }
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(transportError("CDP_CALL_TIMEOUT", `Debugger call timed out: ${method}`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { method, reject, resolve, timer });
      try {
        this.socket.send(JSON.stringify({ id, method, params }));
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(transportError("WEBSOCKET_SEND_FAILED", "WebSocket send failed"));
      }
    });
  }

  close() {
    if (!this.socket) {
      return;
    }
    try {
      this.socket.close();
    } catch {
      // A closed debugger may already have torn down the socket.
    }
  }
}

async function connectTarget(target, port, timeoutMs) {
  const url = forceLoopbackWebSocketUrl(target.webSocketDebuggerUrl, port);
  const client = new JsonRpcWebSocket(url, { timeoutMs });
  await client.connect();
  return client;
}

async function evaluate(client, expression, timeoutMs, awaitPromise = true) {
  const result = await client.call(
    "Runtime.evaluate",
    {
      awaitPromise,
      expression,
      generatePreview: false,
      returnByValue: true,
      userGesture: false,
    },
    timeoutMs,
  );
  if (result.exceptionDetails) {
    throw transportError("EVALUATION_FAILED", "Debugger evaluation failed");
  }
  if (result.result?.subtype === "error") {
    throw transportError("EVALUATION_FAILED", "Debugger evaluation returned an error");
  }
  return result.result?.value;
}

module.exports = {
  JsonRpcWebSocket,
  connectTarget,
  discoverTargets,
  evaluate,
  forceLoopbackWebSocketUrl,
};
