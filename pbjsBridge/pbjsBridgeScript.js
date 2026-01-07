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

  // --- NATIVE LOGGING WRAPPERS ---
  const originalConsole = {
    log: console.log,
    warn: console.warn,
    error: console.error,
  };

  function sendToNativeLog(level, args) {
    if (window.pbjsNativeLog) {
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

  const log = {
    invoke: (targetWindow, name, params, data) => {
      console.log(
        "%c→ INVOKE %c" + name + " %c→ " + targetWindow,
        "color: #2196F3; font-weight: bold",
        "color: #FF9800; font-weight: bold",
        "color: #9E9E9E",
        { params: params, data: data }
      );
    },
    response: (fromWindow, name, response, isError) => {
      if (isError) {
        console.error(
          "%c← RESPONSE %c" + name + " %c← " + fromWindow,
          "color: #F44336; font-weight: bold",
          "color: #FF9800; font-weight: bold",
          "color: #9E9E9E",
          response
        );
      } else {
        console.log(
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
      console.log(
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
      await new Promise(r => setTimeout(r, 50));
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
        if (typeof handler === 'function') {
          window.pbjs.darkModeHandlers.push(handler);
        }
      },
      isDarkMode: () => {
        if (typeof window.pbjs.darkMode !== 'undefined') {
          return window.pbjs.darkMode;
        }
        return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
      },
      updateDarkMode: (isDark) => {
        window.pbjs.darkMode = isDark;
        if (isDark) {
          document.documentElement.classList.add('dark');
        } else {
          document.documentElement.classList.remove('dark');
        }
        window.pbjs.darkModeHandlers.forEach(h => {
          try { h(isDark); } catch (e) { console.error("Error in darkModeHandler", e); }
        });
      },
      init: () => {
        console.log("PBJS Script Init (Unified)");
        if (window.pbjs.isDarkMode()) {
          document.documentElement.classList.add('dark');
        } else {
          document.documentElement.classList.remove('dark');
        }
      },

      // --- WINDOW MANAGEMENT ---
      getWindow: function (windowName) {
        if (window.pbjsNativeGetWindow) {
          const winData = window.pbjsNativeGetWindow(windowName);
          // console.log("pbjs.getWindow(" + windowName + ") raw data:", winData);

          if (!winData) return undefined;

          let winObj = winData;
          if (typeof winData === "string") {
            try {
              winObj = JSON.parse(winData);
            } catch (e) {
              console.error("pbjs.getWindow JSON parse error:", e);
            }
          }

          if (winObj && winObj.error) return undefined; // Window not found

          // Wrap with helper methods
          return {
            ...winObj,
            open: function (params) {
              // Use windowName from closure if ID is missing (backend now supports Name lookup)
              const param = this.id || winObj.id || windowName;
              if (window.pbjsNativeOpenWindow) {
                if (params) {
                  window.pbjsNativeOpenWindow(param, JSON.stringify(params));
                } else {
                  window.pbjsNativeOpenWindow(param);
                }
              }
            },
            hide: function () {
              const param = this.id || winObj.id || windowName;
              if (window.pbjsNativeHideWindow) {
                window.pbjsNativeHideWindow(param);
              }
            },
            close: function () {
              const param = this.id || winObj.id;
              if (window.pbjsNativeCloseWindow && param) {
                window.pbjsNativeCloseWindow(param);
              }
            },
          };
        }
        return undefined;
      },

      isWindowReady: function (windowName) {
        if (window.pbjsNativeIsWindowReady) {
          return window.pbjsNativeIsWindowReady(windowName);
        }
        return true; 
      },

      waitForWindow: function (windowName, timeout = 6000) {
        return new Promise((resolve, reject) => {
          let attempts = 0;
          const maxAttempts = Math.floor(timeout / 100);

          const check = () => {
            const win = this.getWindow(windowName);
            if (win === null) {
               // Explicit non-existence
               reject(new Error("Window '" + windowName + "' does not exist"));
               return;
            }

            if (this.isWindowReady(windowName)) {
              resolve(this.getWindow(windowName));
            } else {
              if (attempts < maxAttempts) {
                attempts++;
                setTimeout(check, 100);
              } else {
                reject(new Error("Window '" + windowName + "' not ready after " + timeout + "ms"));
              }
            }
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

        return this.waitForWindow(windowName)
            .then(() => {
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
                            const error = new Error("Request timeout for " + name + " to " + windowName);
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
            })
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

      handle: function (windowName, name, handler) {
        if (!windowName || typeof windowName !== "string") throw new Error("windowName must be a non-empty string");
        if (!name || typeof name !== "string") throw new Error("name must be a non-empty string");
        if (typeof handler !== "function") throw new TypeError("Handler must be a function");
        
        const key = windowName + ":" + name;
        console.log("[PBJS] Registered handler for: " + key);
        handlers.set(key, handler);
        replayUnhandledMessages();
      },

      handleAll: function (name, handler) {
        if (!name || typeof name !== "string") throw new Error("name must be a non-empty string");
        if (typeof handler !== "function") throw new TypeError("Handler must be a function");
        
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

  function replayUnhandledMessages() {
    if (unhandledMessages.length === 0) return;
    console.log("[PBJS] Replaying " + unhandledMessages.length + " unhandled messages...");

    for (let i = 0; i < unhandledMessages.length; i++) {
      const msg = unhandledMessages[i];
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
        if (this._responded) { console.warn("Response already sent"); return; }
        this._responded = true;
        if (msg.requestId !== undefined && window.pbjsNativeReply) {
          window.pbjsNativeReply(JSON.stringify({
            requestId: msg.requestId,
            toWindow: msg.fromWindow,
            fromWindow: WINDOW_NAME,
            data: JSON.stringify(responseData),
            isGetAll: msg.type === "getAll",
          }));
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
      }
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
                    if (!event._responded) event.error(err instanceof Error ? err.message : String(err));
                });
        } catch (err) {
            if (!event._responded) event.error(err instanceof Error ? err.message : String(err));
        }
    } else {
        try { handler(event, msg.params, msg.data); } 
        catch (err) { log.error("handler exception", err); }
    }
  }

  function serializeResponse(value) {
    if (value === undefined || value === null) return true;
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
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
        unhandledMessages.push(msg);
        console.warn("Buffered unhandled message: " + msg.name + " [" + msg.type + "]");
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
                  log.response(response.fromWindow, pending.name, response.data, response.data && response.data.error);
                  pending.responses.push({ windowName: response.fromWindow, response: response.data });
                  pending.receivedCount++;
                  if (pending.receivedCount >= pending.expectedCount && pending.expectedCount > 0) {
                      getAllPendingRequests.delete(response.requestId);
                      pending.resolve(pending.responses);
                  }
              }
          } else {
              const pending = pendingRequests.get(response.requestId);
              if (pending) {
                  pendingRequests.delete(response.requestId);
                  const hasError = response.data && response.data.error;
                  log.response(response.fromWindow, pending.name, response.data, hasError);
                  if (hasError) {
                       const errMsg = typeof response.data.error === "string" ? response.data.error : JSON.stringify(response.data.error);
                       pending.reject(new Error(errMsg));
                  } else {
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
