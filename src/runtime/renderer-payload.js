// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

(function installCleanroomStatsigGateBridge() {
  "use strict";

  const API_SLOT = "__CODEX_STATSIG_GATE_BRIDGE__";
  const TARGET_GATE = "782640499";
  const REMOTE_CONTROL_CLIENT_ENVIRONMENTS_GATE = "2055603567";
  const REMOTE_CONTROL_REFRESH_MESSAGE = "refresh-remote-control-connections";
  const GATE_OVERRIDES = Object.freeze({
    [TARGET_GATE]: false,
    [REMOTE_CONTROL_CLIENT_ENVIRONMENTS_GATE]: true,
  });
  const CHECK_GATE_METHODS = Object.freeze([
    "checkGate",
    "checkGateWithExposureLoggingDisabled",
  ]);
  const STRUCTURED_GATE_METHODS = Object.freeze([
    "getFeatureGate",
    "getGate",
    "getGateValue",
  ]);
  const GATE_METHODS = Object.freeze([...CHECK_GATE_METHODS, ...STRUCTURED_GATE_METHODS]);

  const existing = globalThis[API_SLOT];
  if (existing?.version === 1 && existing?.targetGate === TARGET_GATE &&
      existing?.remoteControlClientEnvironmentsGate === REMOTE_CONTROL_CLIENT_ENVIRONMENTS_GATE &&
      typeof existing.install === "function") {
    return existing.install();
  }

  const wrapperMarker = Symbol("codex.cleanroom.statsig.gate-wrapper");
  const records = [];
  const refreshedClients = new WeakSet();
  let remoteControlRefreshRequested = false;
  let scans = 0;

  function isObjectLike(value) {
    return (typeof value === "object" && value !== null) || typeof value === "function";
  }

  function getGateOverride(value) {
    if (typeof value !== "string" && typeof value !== "number") {
      return null;
    }
    const override = GATE_OVERRIDES[String(value)];
    return typeof override === "boolean" ? override : null;
  }

  function isTargetGate(value) {
    return String(value) === TARGET_GATE && getGateOverride(value) !== null;
  }

  function findDataMethod(receiver, methodName) {
    let holder = receiver;
    let depth = 0;
    while (isObjectLike(holder) && depth < 10) {
      let descriptor;
      try {
        descriptor = Object.getOwnPropertyDescriptor(holder, methodName);
      } catch {
        return null;
      }
      if (descriptor) {
        return typeof descriptor.value === "function" ? { descriptor, holder, method: descriptor.value } : null;
      }
      try {
        holder = Object.getPrototypeOf(holder);
      } catch {
        return null;
      }
      depth += 1;
    }
    return null;
  }

  function isActive(record) {
    try {
      return record.receiver[record.methodName] === record.wrapper;
    } catch {
      return false;
    }
  }

  function gateMethodKind(methodName) {
    return CHECK_GATE_METHODS.includes(methodName) ? "check" : "structured";
  }

  function forceResolvedGateResult(result, enabled) {
    if (!isObjectLike(result)) {
      return enabled;
    }
    try {
      const descriptors = Object.getOwnPropertyDescriptors(result);
      for (const field of ["value", "enabled"]) {
        if (Object.hasOwn(descriptors, field)) {
          const descriptor = descriptors[field];
          descriptors[field] = {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            value: enabled,
            writable: Object.hasOwn(descriptor, "writable") ? descriptor.writable : true,
          };
        }
      }
      const clone = Array.isArray(result)
        ? Object.assign([], result)
        : Object.create(Object.getPrototypeOf(result), descriptors);
      for (const field of ["value", "enabled"]) {
        if (field in result && !Object.hasOwn(descriptors, field)) {
          Object.defineProperty(clone, field, {
            configurable: true,
            enumerable: true,
            value: enabled,
            writable: true,
          });
        } else if (Array.isArray(result) && field in result) {
          clone[field] = enabled;
        }
      }
      return clone;
    } catch {
      const clone = { ...result };
      if ("value" in result) clone.value = enabled;
      if ("enabled" in result) clone.enabled = enabled;
      return clone;
    }
  }

  function forceStructuredGateResult(result, enabled) {
    if (result != null && typeof result.then === "function") {
      return result.then((value) => forceResolvedGateResult(value, enabled));
    }
    return forceResolvedGateResult(result, enabled);
  }

  function recordExistingWrapper(receiver, methodName, wrapper, kind) {
    if (records.some((record) => record.receiver === receiver && record.methodName === methodName && record.wrapper === wrapper)) {
      return;
    }
    records.push({ kind, methodName, receiver, wrapper });
  }

  function refreshStatsigClient(value) {
    if (!isObjectLike(value) || refreshedClients.has(value) || typeof value.refreshValuesAsync !== "function") {
      return;
    }
    refreshedClients.add(value);
    try {
      const result = Reflect.apply(value.refreshValuesAsync, value, []);
      if (result != null && typeof result.catch === "function") {
        result.catch(() => {});
      }
    } catch {
      // A refresh failure must not disable the gate wrappers or break the renderer.
    }
  }

  function requestRemoteControlRefresh() {
    if (remoteControlRefreshRequested) {
      return;
    }
    const sender = globalThis.electronBridge?.sendMessageFromView;
    if (typeof sender !== "function") {
      return;
    }
    remoteControlRefreshRequested = true;
    try {
      const result = Reflect.apply(sender, globalThis.electronBridge, [{ type: REMOTE_CONTROL_REFRESH_MESSAGE }]);
      if (result != null && typeof result.catch === "function") {
        result.catch(() => {});
      }
    } catch {
      // The main process may not have registered the message yet; the renderer bridge remains usable.
    }
  }

  function wrapGateMethod(receiver, methodName) {
    const found = findDataMethod(receiver, methodName);
    if (!found) {
      return false;
    }
    const kind = gateMethodKind(methodName);
    if (found.method[wrapperMarker]?.kind === kind) {
      recordExistingWrapper(receiver, methodName, found.method, kind);
      return true;
    }

    const original = found.method;
    const wrapper = function cleanroomStatsigGateMethod(...args) {
      const override = getGateOverride(args[0]);
      if (override !== null) {
        if (kind === "check") {
          return override;
        }
        return forceStructuredGateResult(Reflect.apply(original, this, args), override);
      }
      return Reflect.apply(original, this, args);
    };
    try {
      Object.defineProperty(wrapper, wrapperMarker, { value: Object.freeze({ kind }) });
    } catch {
      return false;
    }

    const ownDescriptor = Object.getOwnPropertyDescriptor(receiver, methodName);
    let installed = false;
    if (ownDescriptor) {
      if (ownDescriptor.writable) {
        try {
          Object.defineProperty(receiver, methodName, { ...ownDescriptor, value: wrapper });
          installed = true;
        } catch {
          installed = false;
        }
      }
    } else if (Object.isExtensible(receiver)) {
      try {
        Object.defineProperty(receiver, methodName, {
          configurable: true,
          enumerable: false,
          value: wrapper,
          writable: true,
        });
        installed = true;
      } catch {
        installed = false;
      }
    }

    if (!installed && found.descriptor.writable) {
      try {
        Object.defineProperty(found.holder, methodName, { ...found.descriptor, value: wrapper });
        installed = true;
      } catch {
        installed = false;
      }
    }
    if (installed) {
      records.push({ kind, methodName, receiver, wrapper });
    }
    return installed;
  }

  function enqueueDescriptorValues(value, queue, depth) {
    let descriptors;
    try {
      descriptors = Object.getOwnPropertyDescriptors(value);
    } catch {
      return;
    }
    for (const descriptor of Object.values(descriptors)) {
      if (Object.hasOwn(descriptor, "value") && isObjectLike(descriptor.value)) {
        queue.push({ depth: depth + 1, value: descriptor.value });
      }
    }
    if (Array.isArray(value)) {
      return;
    }
    try {
      if (value instanceof Map) {
        for (const [mapKey, mapValue] of value) {
          if (isObjectLike(mapKey)) queue.push({ depth: depth + 1, value: mapKey });
          if (isObjectLike(mapValue)) queue.push({ depth: depth + 1, value: mapValue });
        }
      } else if (value instanceof Set) {
        for (const setValue of value) {
          if (isObjectLike(setValue)) queue.push({ depth: depth + 1, value: setValue });
        }
      }
    } catch {
      // Cross-realm or proxied collections are covered by descriptor traversal.
    }
  }

  function scan() {
    scans += 1;
    requestRemoteControlRefresh();
    const root = globalThis.__STATSIG__;
    if (!isObjectLike(root)) {
      return probe();
    }
    const queue = [{ depth: 0, value: root }];
    const visited = new WeakSet();
    let inspected = 0;
    while (queue.length > 0 && inspected < 2_000) {
      const current = queue.shift();
      if (!current || current.depth > 8 || !isObjectLike(current.value) || visited.has(current.value)) {
        continue;
      }
      visited.add(current.value);
      inspected += 1;
      for (const methodName of GATE_METHODS) {
        wrapGateMethod(current.value, methodName);
      }
      refreshStatsigClient(current.value);
      enqueueDescriptorValues(current.value, queue, current.depth);
    }
    return probe();
  }

  function probe() {
    const active = records.filter(isActive);
    const clients = new Set(active.map((record) => record.receiver));
    const checkRecords = active.filter((record) => record.kind === "check");
    let passedMethods = 0;
    for (const record of checkRecords) {
      try {
        if (Reflect.apply(record.wrapper, record.receiver, [TARGET_GATE]) === false) {
          passedMethods += 1;
        }
      } catch {
        // A throwing probe is a failed proof, not a reason to call the original gate.
      }
    }
    const installedMethods = active.length;
    const allFalse = checkRecords.length > 0 && passedMethods === checkRecords.length;
    return {
      allFalse,
      checkMethods: checkRecords.length,
      installedClients: clients.size,
      installedMethods,
      passedMethods,
      proof: allFalse,
      scans,
      structuredMethods: active.length - checkRecords.length,
      targetGate: TARGET_GATE,
    };
  }

  const api = Object.freeze({
    install: scan,
    probe,
    scan,
    targetGate: TARGET_GATE,
    remoteControlClientEnvironmentsGate: REMOTE_CONTROL_CLIENT_ENVIRONMENTS_GATE,
    version: 1,
  });
  try {
    Object.defineProperty(globalThis, API_SLOT, {
      configurable: false,
      enumerable: false,
      value: api,
      writable: false,
    });
  } catch {
    globalThis[API_SLOT] = api;
  }

  const interval = setInterval(scan, 100);
  interval.unref?.();
  return scan();
})();
