(function () {
  "use strict";

  // Prevent multiple initializations, but allows extending if needed
  if (window.pbjs && window.pbjs.version && window.pbjs.handleAll) {
    console.log("[PBJS] Bridge already fully initialized.");
    return;
  }

  const WINDOW_NAME = "_WINDOW_NAME_INJECTED_BY_NATIVE_";
  const OS_NAME = "_OS_NAME_INJECTED_BY_NATIVE_";

  const handlers = new Map();
  const pendingRequests = new Map();
  const getAllPendingRequests = new Map();
  let nextRequestId = 1;
  const unhandledMessages = [];
  // Cap the inbound buffer so a window that never registers a handler can't
  // accumulate messages unboundedly; drop oldest and count drops. (P2 / §5.3.)
  const MAX_UNHANDLED_MESSAGES = 500;
  let droppedUnhandledCount = 0;

  // Window names we've proven are ready. While a name is in this set,
  // invoke()/send() skip the waitForWindow() probe (two native round-trips).
  // Populated when a probe resolves (waitForWindow) or a reply arrives
  // (single or broadcast). Evicted only on a request *timeout* — the signal of
  // an open-but-unresponsive window (e.g. mid-reload). A closed/missing window
  // returns an immediate native error instead, so it stays cached and keeps
  // failing fast (and routes correctly once reopened). (Finding F3.)
  const readyWindows = new Set();

  // --- NATIVE LOGGING WRAPPERS ---
  const originalConsole = {
    log: console.log,
    warn: console.warn,
    error: console.error,
  };

  // Native-log level gate (F11). Forwarding every console.* call to native
  // competes with real IPC on the main loop, especially under store-sync
  // traffic. Levels below the threshold are not forwarded. Override at runtime:
  //   window.pbjsLogLevel = "INFO" | "WARN" | "ERROR" | "OFF"
  // Default "INFO" preserves the previous behavior for ordinary app logs; the
  // high-frequency IPC *traces* are handled separately (see `log` below).
  const LOG_PRIORITY = { INFO: 20, WARN: 30, ERROR: 40, OFF: 100 };
  function nativeLogThreshold() {
    const lvl = String(window.pbjsLogLevel || "INFO").toUpperCase();
    return LOG_PRIORITY[lvl] !== undefined
      ? LOG_PRIORITY[lvl]
      : LOG_PRIORITY.INFO;
  }

  function sendToNativeLog(level, args) {
    if (!window.pbjsNativeLog) return;
    if ((LOG_PRIORITY[level] || 0) < nativeLogThreshold()) return;
    try {
      const message = args
        .map((arg) => {
          if (typeof arg === "object") {
            try {
              return JSON.stringify(arg);
            } catch (e) {
              return String(arg);
            }
          }
          return String(arg);
        })
        .join(" ");

      window.pbjsNativeLog(
        JSON.stringify({
          level: level,
          message: message,
          window: WINDOW_NAME,
        })
      );
    } catch (err) {
      // Avoid infinite loops
    }
  }

  console.log = function (...args) {
    originalConsole.log.apply(console, args);
    sendToNativeLog("INFO", args);
  };
  console.warn = function (...args) {
    originalConsole.warn.apply(console, args);
    sendToNativeLog("WARN", args);
  };
  console.error = function (...args) {
    originalConsole.error.apply(console, args);
    sendToNativeLog("ERROR", args);
  };

  // High-frequency IPC trace logs. These print to devtools via the *original*
  // console (captured above) so they are NOT forwarded to native — every
  // invoke/response/handler would otherwise ship a log over the bridge and
  // compete with real IPC on the main loop, especially under store-sync traffic
  // (F11). Full devtools richness is kept; only the native forward is dropped.
  // log.error (below) still forwards: bridge errors are rare and worth seeing in
  // the native terminal.
  const log = {
    invoke: (targetWindow, name, params, data) => {
      originalConsole.log(
        "%c→ INVOKE %c" + name + " %c→ " + targetWindow,
        "color: #2196F3; font-weight: bold",
        "color: #FF9800; font-weight: bold",
        "color: #9E9E9E",
        { params: params, data: data }
      );
    },
    response: (fromWindow, name, response, isError) => {
      if (isError) {
        originalConsole.error(
          "%c← RESPONSE %c" + name + " %c← " + fromWindow,
          "color: #F44336; font-weight: bold",
          "color: #FF9800; font-weight: bold",
          "color: #9E9E9E",
          response
        );
      } else {
        originalConsole.log(
          "%c← RESPONSE %c" + name + " %c← " + fromWindow + " %c✓",
          "color: #4CAF50; font-weight: bold",
          "color: #FF9800; font-weight: bold",
          "color: #9E9E9E",
          "color: #4CAF50",
          response
        );
      }
    },
    handler: (fromWindow, name, type) => {
      originalConsole.log(
        "%c◆ HANDLER %c" + name + " %c← " + fromWindow + " %c[" + type + "]",
        "color: #9C27B0; font-weight: bold",
        "color: #FF9800; font-weight: bold",
        "color: #9E9E9E",
        "color: #607D8B; font-size: 0.9em"
      );
    },
    error: (context, error) => {
      console.error(
        "%c✗ ERROR %c" + context,
        "color: #F44336; font-weight: bold",
        "color: #9E9E9E",
        error
      );
    },
  };

  // --- WAIT FOR NATIVE BINDINGS ---
  const waitForNative = async () => {
    let attempts = 0;
    // We check for one specific binding as a proxy for all. Increased to 50 attempts (2.5s) for slower inits.
    while (!window.pbjsNativeGetWindow && attempts < 50) {
      await new Promise((r) => setTimeout(r, 50));
      attempts++;
    }
    if (!window.pbjsNativeGetWindow) {
      console.error("[PBJS] pbjsNativeGetWindow failed to appear after wait.");
    }
  };

  // --- MAIN INIT EXECUTION ---
  (async () => {
    await waitForNative();

    window.pbjs = {
      ...(window.pbjs || {}),
      version: "UNIFIED_V2",
      windowName: WINDOW_NAME,
      os: OS_NAME,
      darkModeHandlers: [],
      ready: true,

      // --- DARK MODE SUPPORT ---
      registerDarkModeChangeHandler: (handler) => {
        if (typeof handler === "function") {
          window.pbjs.darkModeHandlers.push(handler);
        }
      },
      isDarkMode: () => {
        if (typeof window.pbjs.darkMode !== "undefined") {
          return window.pbjs.darkMode;
        }
        return (
          window.matchMedia &&
          window.matchMedia("(prefers-color-scheme: dark)").matches
        );
      },
      updateDarkMode: (isDark) => {
        window.pbjs.darkMode = isDark;
        if (isDark) {
          document.documentElement.classList.add("dark");
        } else {
          document.documentElement.classList.remove("dark");
        }
        window.pbjs.darkModeHandlers.forEach((h) => {
          try {
            h(isDark);
          } catch (e) {
            console.error("Error in darkModeHandler", e);
          }
        });
      },
      init: () => {
        console.log("PBJS Script Init (Unified)");
        if (window.pbjs.isDarkMode()) {
          document.documentElement.classList.add("dark");
        } else {
          document.documentElement.classList.remove("dark");
        }
      },

      // --- WINDOW MANAGEMENT ---
      getWindow: function (windowName) {
        if (!window.pbjsNativeGetWindow) {
          return Promise.resolve(undefined);
        }

        return window
          .pbjsNativeGetWindow(windowName)
          .then((winData) => {
            console.log(
              "pbjs.getWindow(" + windowName + ") raw data:",
              winData
            );

            if (!winData) return undefined;

            let winObj = winData;
            // Native bridge might return string or object depending on binding
            if (typeof winData === "string") {
              try {
                winObj = JSON.parse(winData);
              } catch (e) {
                console.error("pbjs.getWindow JSON parse error:", e);
                return undefined;
              }
            }

            if (winObj && winObj.error) return undefined; // Window not found

            // Wrap with helper methods
            return {
              ...winObj,
              open: function (params) {
                const param = this.id || winObj.id || windowName;
                console.log(
                  "[PBJS] open called for:",
                  param,
                  "with params:",
                  params
                );
                return new Promise((resolve) => {
                  if (window.pbjsNativeOpenWindow && param) {
                    const stringParam = String(param);

                    const paramJson = params
                      ? JSON.stringify(params)
                      : undefined;

                    console.log(
                      "[PBJS] calling pbjsNativeOpenWindow with:",
                      stringParam,
                      paramJson
                    );

                    const promise = paramJson
                      ? window.pbjsNativeOpenWindow(stringParam, paramJson)
                      : window.pbjsNativeOpenWindow(stringParam);

                    promise
                      .then((result) => {
                        console.log("[PBJS] open native result:", result);
                        if (!result) {
                          resolve(false);
                          return;
                        }
                        try {
                          const json =
                            typeof result === "string"
                              ? JSON.parse(result)
                              : result;
                          resolve(!!json.success);
                        } catch (e) {
                          console.error("[PBJS] open parse error:", e);
                          resolve(false);
                        }
                      })
                      .catch((err) => {
                        console.error("[PBJS] open native error:", err);
                        resolve(false);
                      });
                  } else {
                    console.error("[PBJS] pbjsNativeOpenWindow NOT DEFINED");
                    resolve(false);
                  }
                });
              },
              hide: function () {
                const param = this.id || winObj.id || windowName;
                return new Promise((resolve) => {
                  if (window.pbjsNativeHideWindow && param) {
                    const stringParam = String(param);

                    window
                      .pbjsNativeHideWindow(stringParam)
                      .then((result) => {
                        if (!result) {
                          resolve(false);
                          return;
                        }
                        try {
                          const json =
                            typeof result === "string"
                              ? JSON.parse(result)
                              : result;
                          resolve(!!json.success);
                        } catch (e) {
                          resolve(false);
                        }
                      })
                      .catch(() => resolve(false));
                  } else {
                    resolve(false);
                  }
                });
              },
              close: function () {
                const param = this.id || winObj.id;
                return new Promise((resolve) => {
                  if (window.pbjsNativeCloseWindow && param) {
                    const stringParam = String(param);
                    window
                      .pbjsNativeCloseWindow(stringParam)
                      .then((result) => {
                        if (!result) {
                          resolve(false);
                          return;
                        }
                        try {
                          const json =
                            typeof result === "string"
                              ? JSON.parse(result)
                              : result;
                          resolve(!!json.success);
                        } catch (e) {
                          resolve(false);
                        }
                      })
                      .catch(() => resolve(false));
                  } else {
                    resolve(false);
                  }
                });
              },
              isOpen: function () {
                const param = this.id || winObj.id || windowName;
                return new Promise((resolve) => {
                  if (window.pbjsNativeIsWindowOpen) {
                    window
                      .pbjsNativeIsWindowOpen(String(param))
                      .then((result) => {
                        if (!result) {
                          resolve(false);
                          return;
                        }
                        if (
                          typeof result === "object" &&
                          result.isOpen !== undefined
                        ) {
                          resolve(!!result.isOpen);
                          return;
                        }
                        try {
                          const json =
                            typeof result === "string"
                              ? JSON.parse(result)
                              : result;
                          resolve(!!json.isOpen);
                        } catch (e) {
                          resolve(false);
                        }
                      })
                      .catch(() => resolve(false));
                  } else {
                    resolve(false);
                  }
                });
              },
            };
          })
          .catch((err) => {
            console.error("pbjs.getWindow native error:", err);
            return undefined;
          });
      },

      isWindowReady: function (windowName) {
        if (window.pbjsNativeIsWindowReady) {
          return window
            .pbjsNativeIsWindowReady(windowName)
            .then((result) => result) // Ensure Promise return
            .catch(() => false);
        }
        return Promise.resolve(true); // Default to true if not defined
      },

      waitForWindow: function (windowName, timeout = 6000) {
        return new Promise((resolve, reject) => {
          let attempts = 0;
          const maxAttempts = Math.floor(timeout / 100);

          const check = () => {
            // getWindow is now async
            this.getWindow(windowName)
              .then((win) => {
                if (!win) {
                  // win is null/undefined if not found
                  if (attempts < maxAttempts) {
                    attempts++;
                    setTimeout(check, 100);
                  } else {
                    reject(
                      new Error(
                        "Window '" +
                          windowName +
                          "' not found after " +
                          timeout +
                          "ms"
                      )
                    );
                  }
                  return;
                }

                // Check ready state
                this.isWindowReady(windowName)
                  .then((isReady) => {
                    if (isReady) {
                      console.log(
                        "[PBJS] waitForWindow resolving for " + windowName,
                        win
                      );
                      // Warm the readiness cache (F3) for every waitForWindow
                      // caller — invoke, send, and external callers alike.
                      readyWindows.add(windowName);
                      resolve(win);
                    } else {
                      if (attempts < maxAttempts) {
                        attempts++;
                        setTimeout(check, 100);
                      } else {
                        reject(
                          new Error(
                            "Window '" +
                              windowName +
                              "' not ready after " +
                              timeout +
                              "ms"
                          )
                        );
                      }
                    }
                  })
                  .catch((err) => {
                    console.error(
                      "[PBJS] isWindowReady error for " + windowName,
                      err
                    );
                    // Treat check error as not ready -> retry?
                    if (attempts < maxAttempts) {
                      attempts++;
                      setTimeout(check, 100);
                    } else {
                      reject(err);
                    }
                  });
              })
              .catch((err) => {
                console.error("[PBJS] getWindow error for " + windowName, err);
                if (attempts < maxAttempts) {
                  attempts++;
                  setTimeout(check, 100);
                } else {
                  reject(err);
                }
              });
          };
          check();
        });
      },

      // --- IPC / BRIDGE ---

      invoke: function (windowName, name, params, data) {
        if (!windowName || typeof windowName !== "string") {
          const error = new Error("windowName must be a non-empty string");
          log.error("invoke", error);
          return Promise.reject(error);
        }
        if (!name || typeof name !== "string") {
          const error = new Error("name must be a non-empty string");
          log.error("invoke", error);
          return Promise.reject(error);
        }

        log.invoke(windowName, name, params, data);

        // The actual native "get" dispatch + pending-request bookkeeping.
        const dispatchGet = () => {
          return new Promise((resolve, reject) => {
            if (!window.pbjsNativeGet) {
              const error = new Error("Native bridge not available");
              log.error("invoke", error);
              reject(error);
              return;
            }

            const requestId = nextRequestId++;
            pendingRequests.set(requestId, {
              resolve: resolve,
              reject: reject,
              windowName: windowName,
              name: name,
            });

            setTimeout(() => {
              if (pendingRequests.has(requestId)) {
                pendingRequests.delete(requestId);
                // Unresponsive target — stop trusting the readiness cache so the
                // next call re-probes via waitForWindow.
                readyWindows.delete(windowName);
                const error = new Error(
                  "Request timeout for " + name + " to " + windowName
                );
                log.error("invoke timeout", error);
                reject(error);
              }
            }, 30000);

            window.pbjsNativeGet(
              JSON.stringify({
                type: "get",
                fromWindow: WINDOW_NAME,
                toWindow: windowName,
                name: name,
                params: JSON.stringify(params || {}),
                data: JSON.stringify(data || {}),
                requestId: requestId,
              })
            );
          });
        };

        // Fast path: window already proven ready — skip the waitForWindow probe
        // (two native round-trips). Cold path: probe once; waitForWindow warms
        // readyWindows on resolve, so later calls take the fast path.
        if (readyWindows.has(windowName)) {
          return dispatchGet().catch((err) => {
            log.error("invoke failed", err);
            throw err;
          });
        }

        return this.waitForWindow(windowName)
          .then(() => dispatchGet())
          .catch((err) => {
            log.error("invoke failed", err);
            throw err;
          });
      },

      invokeAll: function (name, params, data) {
        if (!name || typeof name !== "string") {
          const error = new Error("name must be a non-empty string");
          log.error("invokeAll", error);
          return Promise.reject(error);
        }

        log.invoke("ALL WINDOWS", name, params, data);

        return new Promise((resolve, reject) => {
          if (!window.pbjsNativeGetAll) {
            const error = new Error("Native bridge not available");
            log.error("invokeAll", error);
            reject(error);
            return;
          }

          const requestId = nextRequestId++;
          getAllPendingRequests.set(requestId, {
            resolve: resolve,
            reject: reject,
            responses: [],
            expectedCount: 0,
            receivedCount: 0,
            name: name,
          });

          setTimeout(() => {
            if (getAllPendingRequests.has(requestId)) {
              const pending = getAllPendingRequests.get(requestId);
              getAllPendingRequests.delete(requestId);
              resolve(pending.responses);
            }
          }, 30000);

          window.pbjsNativeGetAll(
            JSON.stringify({
              type: "getAll",
              fromWindow: WINDOW_NAME,
              name: name,
              params: JSON.stringify(params || {}),
              data: JSON.stringify(data || {}),
              requestId: requestId,
            })
          );
        });
      },

      // Fire-and-forget message to a single window. No requestId, no pending
      // entry, no Promise, no 30s timer — the receiver's handle()/handleAll()
      // fires but is not expected to reply. If the target exists but isn't
      // ready yet, native buffers it (PendingMessages); if it doesn't exist,
      // native drops it silently. Use invoke() when you need a response.
      send: function (windowName, name, params, data) {
        if (!windowName || typeof windowName !== "string") {
          log.error("send", new Error("windowName must be a non-empty string"));
          return;
        }
        if (!name || typeof name !== "string") {
          log.error("send", new Error("name must be a non-empty string"));
          return;
        }
        if (!window.pbjsNativeSend) {
          log.error("send", new Error("Native bridge not available"));
          return;
        }

        const fire = () => {
          log.invoke(windowName, name, params, data);
          window.pbjsNativeSend(
            JSON.stringify({
              type: "send",
              fromWindow: WINDOW_NAME,
              toWindow: windowName,
              name: name,
              params: JSON.stringify(params || {}),
              data: JSON.stringify(data || {}),
            })
          );
        };

        // Cache-gated like invoke(): if the target is already proven ready, fire
        // immediately (the warm path — instant, no probe). Otherwise wait for the
        // window once so a message to a not-yet-registered window isn't dropped
        // (waitForWindow warms readyWindows on resolve). Still returns void; the
        // caller never awaits.
        if (readyWindows.has(windowName)) {
          fire();
        } else {
          this.waitForWindow(windowName)
            .then(() => fire())
            .catch((err) => log.error("send failed", err));
        }
      },

      // Fire-and-forget broadcast to every window except the sender. Same
      // no-reply semantics as send(). This is the cheap primitive for events,
      // presence, and store-sync patches (see iplan/pbjszustand.md).
      //
      // Note: unlike invoke()/send(), there is no single target to wait on, so
      // the readiness cache (F3) does not apply here. The native router already
      // buffers not-ready windows (PendingMessages) and excludes dormant pool
      // spares (F13), so no per-target probe is needed.
      sendAll: function (name, params, data) {
        if (!name || typeof name !== "string") {
          log.error("sendAll", new Error("name must be a non-empty string"));
          return;
        }
        if (!window.pbjsNativeSendAll) {
          log.error("sendAll", new Error("Native bridge not available"));
          return;
        }
        log.invoke("ALL WINDOWS", name, params, data);
        window.pbjsNativeSendAll(
          JSON.stringify({
            type: "sendAll",
            fromWindow: WINDOW_NAME,
            name: name,
            params: JSON.stringify(params || {}),
            data: JSON.stringify(data || {}),
          })
        );
      },

      onCloseWindow: function (handler) {
        window.pbjs.handle("system", "close-window", handler);
      },

      // Open a multi-instance window from a registered template.
      // - templateName: opaque string matching a JSWindow::RegisterTemplate call.
      // - instanceKey:  opaque caller string for dedupe. Empty string disables
      //                 dedupe (every call opens a new window).
      // - params:       JSON-serializable payload, delivered to the target
      //                 window as a "handleParameters" message.
      // Resolves to { success, name, id } or { error }.
      openInstance: function (templateName, instanceKey, params) {
        return new Promise((resolve, reject) => {
          if (!window.pbjsNativeOpenInstance) {
            reject(new Error("pbjsNativeOpenInstance not available"));
            return;
          }
          const paramJson = params !== undefined ? JSON.stringify(params) : "";
          window
            .pbjsNativeOpenInstance(
              String(templateName),
              String(instanceKey || ""),
              paramJson
            )
            .then((result) => {
              if (!result) {
                resolve({ success: false });
                return;
              }
              try {
                const json =
                  typeof result === "string" ? JSON.parse(result) : result;
                resolve(json);
              } catch (e) {
                console.error("[PBJS] openInstance parse error:", e);
                resolve({ success: false });
              }
            })
            .catch((err) => {
              console.error("[PBJS] openInstance native error:", err);
              reject(err);
            });
        });
      },

      handle: function (windowName, name, handler) {
        if (!windowName || typeof windowName !== "string")
          throw new Error("windowName must be a non-empty string");
        if (!name || typeof name !== "string")
          throw new Error("name must be a non-empty string");
        if (typeof handler !== "function")
          throw new TypeError("Handler must be a function");

        const key = windowName + ":" + name;
        console.log("[PBJS] Registered handler for: " + key);
        handlers.set(key, handler);
        replayUnhandledMessages();
      },

      handleAll: function (name, handler) {
        if (!name || typeof name !== "string")
          throw new Error("name must be a non-empty string");
        if (typeof handler !== "function")
          throw new TypeError("Handler must be a function");

        console.log("[PBJS] Registered global handler for: *:" + name);
        handlers.set("*:" + name, handler);
        replayUnhandledMessages();
      },

      removeHandler: function (windowName, name) {
        const key = windowName ? windowName + ":" + name : "*:" + name;
        handlers.delete(key);
      },

      removeAllHandlers: function () {
        handlers.clear();
      },
    };

    // Initialize themes immediately
    if (window.pbjs.init) window.pbjs.init();

    // Signal Readiness
    window.pbjsReady = true;
    console.log(
      "%c✓ PBJS Bridge Ready %c" + WINDOW_NAME,
      "color: #4CAF50; font-weight: bold; font-size: 1.1em",
      "color: #2196F3; font-weight: bold"
    );
    window.dispatchEvent(new Event("pbjs-ready"));
  })();

  // --- INTERNAL MESSAGE HANDLING (Needs to be global) ---

  const MESSAGE_TIMEOUT_MS = 30000;

  function replayUnhandledMessages() {
    if (unhandledMessages.length === 0) return;
    console.log(
      "[PBJS] Replaying " + unhandledMessages.length + " unhandled messages..."
    );

    const now = Date.now();
    for (let i = 0; i < unhandledMessages.length; i++) {
      const msg = unhandledMessages[i];
      const messageAge = now - (msg._bufferedAt || 0);

      // Discard stale known messages after timeout
      if (messageAge > MESSAGE_TIMEOUT_MS) {
        unhandledMessages.splice(i, 1);
        i--;
        continue;
      }

      const key = msg.fromWindow + ":" + msg.name;
      const globalKey = "*:" + msg.name;
      const handler = handlers.get(key) || handlers.get(globalKey);

      if (handler) {
        unhandledMessages.splice(i, 1);
        i--;
        dispatchMessage(msg, handler);
      }
    }
  }

  function dispatchMessage(msg, handler) {
    log.handler(msg.fromWindow, msg.name, msg.type);

    const event = {
      type: msg.type,
      fromWindow: msg.fromWindow,
      toWindow: WINDOW_NAME,
      _responded: false,

      _send: function (responseData) {
        if (this._responded) {
          console.warn("Response already sent");
          return;
        }
        this._responded = true;
        if (msg.requestId !== undefined && window.pbjsNativeReply) {
          window.pbjsNativeReply(
            JSON.stringify({
              requestId: msg.requestId,
              toWindow: msg.fromWindow,
              fromWindow: WINDOW_NAME,
              data: JSON.stringify(responseData),
              isGetAll: msg.type === "getAll",
            })
          );
        }
      },

      success: function (data) {
        this._send({ success: serializeResponse(data) });
      },
      error: function (error) {
        this._send({ error: serializeResponse(error) });
      },
      reply: function (data) {
        this.success(data);
      },
    };

    if (msg.type === "get" || msg.type === "getAll") {
      try {
        Promise.resolve(handler(event, msg.params, msg.data))
          .then((result) => {
            if (!event._responded) {
              event.success(result !== undefined ? result : true);
            }
          })
          .catch((err) => {
            if (!event._responded)
              event.error(err instanceof Error ? err.message : String(err));
          });
      } catch (err) {
        if (!event._responded)
          event.error(err instanceof Error ? err.message : String(err));
      }
    } else {
      try {
        handler(event, msg.params, msg.data);
      } catch (err) {
        log.error("handler exception", err);
      }
    }
  }

  function serializeResponse(value) {
    if (value === undefined || value === null) return true;
    if (
      typeof value === "string" ||
      typeof value === "number" ||
      typeof value === "boolean"
    )
      return value;
    if (value instanceof Error) return value.message;
    return value;
  }

  window.pbjsHandleMessage = function (messageJson) {
    try {
      const msg = JSON.parse(messageJson);
      const key = msg.fromWindow + ":" + msg.name;
      const globalKey = "*:" + msg.name;
      const handler = handlers.get(key) || handlers.get(globalKey);

      if (!handler) {
        // Special Case: IGNORE close-window messages if unhandled
        // Do NOT buffer them, as they will hang if no handler exists.
        if (msg.name === "close-window") {
          console.warn(
            "[PBJS] Ignored unhandled close-window message (will not buffer)"
          );
          return;
        }

        // Buffer other unhandled messages — the handler should register soon and
        // the message will replay. Cap the buffer (drop oldest, count drops) so a
        // window that never registers a handler can't grow it unboundedly.
        msg._bufferedAt = Date.now();
        if (unhandledMessages.length >= MAX_UNHANDLED_MESSAGES) {
          unhandledMessages.shift();
          droppedUnhandledCount++;
        }
        unhandledMessages.push(msg);
        console.warn(
          "Buffered unhandled message: " +
            msg.name +
            " [" +
            msg.type +
            "]" +
            (droppedUnhandledCount
              ? " (dropped " + droppedUnhandledCount + " over cap)"
              : "")
        );
        return;
      }
      dispatchMessage(msg, handler);
    } catch (error) {
      log.error("pbjsHandleMessage", error);
    }
  };

  window.pbjsHandleResponse = function (responseJson) {
    try {
      const response = JSON.parse(responseJson);

      if (response.isGetAll) {
        const pending = getAllPendingRequests.get(response.requestId);
        if (pending) {
          log.response(
            response.fromWindow,
            pending.name,
            response.data,
            response.data && response.data.error
          );
          pending.responses.push({
            windowName: response.fromWindow,
            response: response.data,
          });
          // A window that replied to a broadcast is provably ready — warm the
          // cache (F3) so a later single invoke/send to it skips the probe.
          readyWindows.add(response.fromWindow);
          pending.receivedCount++;
          if (
            pending.receivedCount >= pending.expectedCount &&
            pending.expectedCount > 0
          ) {
            getAllPendingRequests.delete(response.requestId);
            pending.resolve(pending.responses);
          }
        }
      } else {
        const pending = pendingRequests.get(response.requestId);
        if (pending) {
          pendingRequests.delete(response.requestId);
          const hasError = response.data && response.data.error;
          log.response(
            response.fromWindow,
            pending.name,
            response.data,
            hasError
          );
          if (hasError) {
            // Do NOT evict on an error response. A closed/missing window returns
            // an immediate native error, so keeping it cached lets the next call
            // fail fast too (and route correctly once reopened). Evicting would
            // force the next call down the cold path, where waitForWindow polls a
            // non-existent window for the full 6s before rejecting. The genuinely
            // stale case (open but unresponsive, e.g. mid-reload) surfaces as a
            // timeout, which the request setTimeout evicts.
            const errMsg =
              typeof response.data.error === "string"
                ? response.data.error
                : JSON.stringify(response.data.error);
            pending.reject(new Error(errMsg));
          } else {
            // Confirmed reachable — (re)mark ready. Idempotent on the fast path.
            readyWindows.add(pending.windowName);
            pending.resolve(response.data);
          }
        }
      }
    } catch (error) {
      log.error("pbjsHandleResponse", error);
    }
  };

  window.pbjsSetGetAllExpectedCount = function (requestId, count) {
    const pending = getAllPendingRequests.get(requestId);
    if (pending) {
      pending.expectedCount = count;
      if (pending.receivedCount >= count && count > 0) {
        getAllPendingRequests.delete(requestId);
        pending.resolve(pending.responses);
      } else if (count === 0) {
        getAllPendingRequests.delete(requestId);
        pending.resolve([]);
      }
    }
  };
})();
