// ============================================================================
// jsdom harness for pbjsBridgeScript.js — the fake native half.
// ============================================================================
//
// The bridge script is not a module. It is an IIFE with three placeholders that
// the PureBasic host substitutes (PrepateBridgeScript, pbjsBridge.pb), delivered
// into a <script> tag, and it talks to the host through ~20 `window.pbjsNative*`
// functions that PureBasic binds with BindWebViewCallback.
//
// So the harness does exactly what the host does, minus the webview:
//
//   1. substitute the three placeholders,
//   2. install a fake native (the `pbjsNative*` binds below),
//   3. eval the script into the jsdom window,
//   4. drive the INBOUND direction the way native does — by calling the global
//      entry points the script installs: pbjsHandleMessage, pbjsHandleResponse,
//      pbjsWindowEvent, pbjsSetGetAllExpectedCount.
//
// Everything the bridge sends outward lands in `native.calls` / the per-channel
// arrays, so a test asserts on real wire frames rather than on internals.
//
// WHAT IS DELIBERATELY NOT STUBBED
// --------------------------------
// `window.pbjsNativeIsWindowReady` is left undefined, because the host does not
// bind it either (verified: it appears in no BindWebViewCallback call in
// JSWindow.pb). `pbjs.isWindowReady` therefore returns its hard-coded `true`
// fallback here exactly as it does in production — which is the whole of
// roadmap 2.6's finding. Stubbing it would hide the thing the harness exists to
// pin down.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BRIDGE_PATH = resolve(HERE, "../../pbjsBridge/pbjsBridgeScript.js");

/** Raw bridge source, read once. */
export const bridgeSource = readFileSync(BRIDGE_PATH, "utf8");

// Globals the bridge script installs on `window`. Removed before each load so a
// second load in the same jsdom window is a genuinely fresh bridge (the script
// self-guards against double init on `window.pbjs.version`).
const BRIDGE_GLOBALS = [
  "pbjs",
  "pbjsReady",
  "pbjsHandleMessage",
  "pbjsHandleResponse",
  "pbjsWindowEvent",
  "pbjsSetGetAllExpectedCount",
  "pbjsLogLevel",
  "pbjsDeadLetterGraceMs",
];

const NATIVE_GLOBALS = [
  "pbjsNativeGetWindow",
  "pbjsNativeGet",
  "pbjsNativeGetAll",
  "pbjsNativeSend",
  "pbjsNativeSendAll",
  "pbjsNativeReply",
  "pbjsNativeLog",
  "pbjsNativeOpenWindow",
  "pbjsNativeOpenInstance",
  "pbjsNativeHideWindow",
  "pbjsNativeCloseWindow",
  "pbjsNativeIsWindowOpen",
  "pbjsNativeIsWindowReady",
];

/**
 * Build the fake native surface.
 *
 * @param {object} opts
 * @param {string[]} opts.knownWindows  Names pbjsNativeGetWindow will resolve.
 *                                      Anything else answers "not found", which
 *                                      is what a closed/unknown window does.
 */
function makeNative(opts) {
  const known = new Set(opts.knownWindows ?? []);

  const native = {
    /** Every outbound native call, in order: {fn, args}. */
    calls: [],
    /** Parsed frames per channel — what a test usually wants. */
    get: [],
    getAll: [],
    send: [],
    sendAll: [],
    reply: [],
    log: [],
    openInstance: [],
    getWindow: [],

    /** Windows pbjsNativeGetWindow reports as existing. */
    knownWindows: known,

    /** Next result for pbjsNativeOpenInstance (a JSON string, like native). */
    openInstanceResult: JSON.stringify({ success: true, name: "instance-1" }),

    reset() {
      native.calls.length = 0;
      for (const k of ["get", "getAll", "send", "sendAll", "reply", "log", "openInstance", "getWindow"]) {
        native[k].length = 0;
      }
    },

    /** The last frame on a channel, already JSON-parsed. */
    last(channel) {
      const list = native[channel];
      return list.length ? list[list.length - 1] : undefined;
    },
  };

  const record = (fn, args) => native.calls.push({ fn, args });

  const install = (window) => {
    // --- outbound: request/response ---------------------------------------
    window.pbjsNativeGet = (json) => {
      record("pbjsNativeGet", [json]);
      native.get.push(JSON.parse(json));
    };
    window.pbjsNativeGetAll = (json) => {
      record("pbjsNativeGetAll", [json]);
      native.getAll.push(JSON.parse(json));
    };
    window.pbjsNativeReply = (json) => {
      record("pbjsNativeReply", [json]);
      const frame = JSON.parse(json);
      // `data` travels as a JSON *string* inside the frame (HandleReply parses
      // it separately) — pre-parse it so assertions read naturally.
      if (typeof frame.data === "string") {
        try {
          frame.dataParsed = JSON.parse(frame.data);
        } catch {
          frame.dataParsed = undefined;
        }
      }
      native.reply.push(frame);
    };

    // --- outbound: fire-and-forget ----------------------------------------
    window.pbjsNativeSend = (json) => {
      record("pbjsNativeSend", [json]);
      native.send.push(JSON.parse(json));
    };
    window.pbjsNativeSendAll = (json) => {
      record("pbjsNativeSendAll", [json]);
      native.sendAll.push(JSON.parse(json));
    };

    // --- outbound: logging -------------------------------------------------
    window.pbjsNativeLog = (json) => {
      record("pbjsNativeLog", [json]);
      native.log.push(JSON.parse(json));
    };

    // --- outbound: window management --------------------------------------
    // Native returns JSON *strings*; the bridge handles both, but returning the
    // string is what actually ships.
    window.pbjsNativeGetWindow = (name) => {
      record("pbjsNativeGetWindow", [name]);
      native.getWindow.push(name);
      if (!known.has(name)) return Promise.resolve(undefined);
      return Promise.resolve(JSON.stringify({ id: name, name }));
    };
    window.pbjsNativeOpenWindow = (id, paramJson) => {
      record("pbjsNativeOpenWindow", [id, paramJson]);
      return Promise.resolve(JSON.stringify({ success: true }));
    };
    window.pbjsNativeHideWindow = (id) => {
      record("pbjsNativeHideWindow", [id]);
      return Promise.resolve(JSON.stringify({ success: true }));
    };
    window.pbjsNativeCloseWindow = (id) => {
      record("pbjsNativeCloseWindow", [id]);
      return Promise.resolve(JSON.stringify({ success: true }));
    };
    window.pbjsNativeIsWindowOpen = (id) => {
      record("pbjsNativeIsWindowOpen", [id]);
      return Promise.resolve(JSON.stringify({ isOpen: known.has(id) }));
    };
    window.pbjsNativeOpenInstance = (...args) => {
      record("pbjsNativeOpenInstance", args);
      native.openInstance.push(args);
      return Promise.resolve(native.openInstanceResult);
    };

    // pbjsNativeIsWindowReady: deliberately NOT installed. See the header.
  };

  return { native, install };
}

/**
 * Load the bridge into the current jsdom window, exactly as the host delivers it.
 *
 * @param {object}   [opts]
 * @param {string}   [opts.windowName="main-window"]  the _WINDOW_NAME_ placeholder
 * @param {string}   [opts.os="mac"]                  the _OS_NAME_ placeholder
 * @param {boolean}  [opts.dnd=false]                 the _DND_ENABLED_ placeholder
 * @param {string[]} [opts.knownWindows]              windows native reports as existing
 * @param {boolean}  [opts.silenceConsole=true]       capture console instead of printing
 *
 * @returns {Promise<{pbjs, native, console, deliver, respond, windowEvent,
 *                    setGetAllExpectedCount, source}>}
 */
export async function loadBridge(opts = {}) {
  const {
    windowName = "main-window",
    os = "mac",
    dnd = false,
    knownWindows = ["other-window"],
    silenceConsole = true,
  } = opts;

  // 1. A clean slate. The script's own double-init guard reads window.pbjs, so
  //    a leftover from a previous load would make this a no-op.
  for (const g of [...BRIDGE_GLOBALS, ...NATIVE_GLOBALS]) delete window[g];

  // 2. Console. The bridge wraps console.log/warn/error at eval time and keeps
  //    the pre-wrap functions as `originalConsole` — so whatever is installed
  //    HERE is what the bridge's own internal logging reaches. Capturing rather
  //    than printing keeps test output readable and lets a test assert on the
  //    warnings the bridge treats as real faults (dead-letter, buffer drop).
  const captured = { log: [], warn: [], error: [] };
  const realConsole = { log: console.log, warn: console.warn, error: console.error };
  if (silenceConsole) {
    console.log = (...a) => captured.log.push(a);
    console.warn = (...a) => captured.warn.push(a);
    console.error = (...a) => captured.error.push(a);
  }

  // 3. The fake native, installed BEFORE eval: the script's waitForNative()
  //    polls for pbjsNativeGetWindow at 50 ms intervals, and having it present
  //    up front means init completes on the first microtask instead of needing
  //    a timer advance.
  const { native, install } = makeNative({ knownWindows });
  install(window);

  // 4. The three host substitutions (pbjsBridge.pb PrepateBridgeScript).
  const source = bridgeSource
    .replace(/_WINDOW_NAME_INJECTED_BY_NATIVE_/g, windowName)
    .replace(/_OS_NAME_INJECTED_BY_NATIVE_/g, os)
    .replace(/_DND_ENABLED_INJECTED_BY_NATIVE_/g, dnd ? "1" : "0");

  // 5. Run it. Indirect eval so the script's own top-level scope is the global
  //    one, as it is inside a <script> tag.
  (0, eval)(source);

  // 6. Init is async (`await waitForNative()` before window.pbjs is assigned).
  //    Drain microtasks until the script signals readiness.
  for (let i = 0; i < 50 && !window.pbjsReady; i++) {
    await Promise.resolve();
  }
  if (!window.pbjsReady) {
    throw new Error("bridge did not become ready — did waitForNative() stall?");
  }

  const restoreConsole = () => Object.assign(console, realConsole);

  return {
    pbjs: window.pbjs,
    native,
    console: captured,
    restoreConsole,
    source,
    windowName,

    // --- inbound drivers: what the host injects into the page -------------
    // Native ships these as `pbjsHandleMessage('<json>')` script strings; the
    // JSON-string boundary is preserved here because it is where R3's escaping
    // bug lived.

    /** Deliver an inbound message. `msg` is the frame native builds. */
    deliver(msg) {
      window.pbjsHandleMessage(JSON.stringify(msg));
    },
    /** Deliver a raw (already serialized) message — for escaping round trips. */
    deliverRaw(messageJson) {
      window.pbjsHandleMessage(messageJson);
    },
    /** Deliver a response to an outstanding invoke/invokeAll. */
    respond(resp) {
      window.pbjsHandleResponse(JSON.stringify(resp));
    },
    /** The §6.5 lifecycle push: kind is "ready" | "closed" | "reloaded". */
    windowEvent(name, kind) {
      window.pbjsWindowEvent(name, kind);
    },
    /** The invokeAll fan-out size, which native sends separately. */
    setGetAllExpectedCount(requestId, count) {
      window.pbjsSetGetAllExpectedCount(requestId, count);
    },
  };
}

/** Let queued microtasks (promise continuations) run. */
export async function flush(times = 5) {
  for (let i = 0; i < times; i++) await Promise.resolve();
}
