(function () {
  "use strict";

  if (window.pbjsBridgeReady) return;

  const WINDOW_NAME = "_WINDOW_NAME_INJECTED_BY_NATIVE_";
  const OS_NAME = "_OS_NAME_INJECTED_BY_NATIVE_";

  const handlers = new Map();
  const pendingRequests = new Map();
  const getAllPendingRequests = new Map();
  let nextRequestId = 1;

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

  window.pbjs = {
    ...(window.pbjs || {}),
    windowName: WINDOW_NAME,
    os: OS_NAME,
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
      if (!windowName || typeof windowName !== "string") {
        throw new Error("windowName must be a non-empty string");
      }
      if (!name || typeof name !== "string") {
        throw new Error("name must be a non-empty string");
      }
      if (typeof handler !== "function") {
        throw new TypeError("Handler must be a function");
      }
      const key = windowName + ":" + name;
      handlers.set(key, handler);
    },

    handleAll: function (name, handler) {
      if (!name || typeof name !== "string") {
        throw new Error("name must be a non-empty string");
      }
      if (typeof handler !== "function") {
        throw new TypeError("Handler must be a function");
      }
      handlers.set("*:" + name, handler);
    },

    removeHandler: function (windowName, name) {
      const key = windowName ? windowName + ":" + name : "*:" + name;
      handlers.delete(key);
    },

    removeAllHandlers: function () {
      handlers.clear();
    },
  };

  function serializeResponse(value) {
    if (value === undefined || value === null) {
      return true;
    }
    if (
      typeof value === "string" ||
      typeof value === "number" ||
      typeof value === "boolean"
    ) {
      return value;
    }
    if (value instanceof Error) {
      return value.message;
    }
    return value;
  }

  window.pbjsHandleMessage = function (messageJson) {
    try {
      const msg = JSON.parse(messageJson);
      const key = msg.fromWindow + ":" + msg.name;
      const globalKey = "*:" + msg.name;
      const handler = handlers.get(key) || handlers.get(globalKey);

      log.handler(msg.fromWindow, msg.name, msg.type);

      if (!handler) {
        if (
          (msg.type === "get" || msg.type === "getAll") &&
          msg.requestId !== undefined &&
          window.pbjsNativeReply
        ) {
          window.pbjsNativeReply(
            JSON.stringify({
              requestId: msg.requestId,
              toWindow: msg.fromWindow,
              fromWindow: WINDOW_NAME,
              data: JSON.stringify({
                error: "No handler registered for: " + msg.name,
              }),
              isGetAll: msg.type === "getAll",
            })
          );
        }
        return;
      }

      const event = {
        type: msg.type,
        fromWindow: msg.fromWindow,
        toWindow: WINDOW_NAME,
        _responded: false,

        success: function (data) {
          if (this._responded) {
            console.warn("Response already sent for this event");
            return;
          }
          this._responded = true;
          if (msg.requestId !== undefined && window.pbjsNativeReply) {
            const responseData = { success: serializeResponse(data) };
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

        error: function (error) {
          if (this._responded) {
            console.warn("Response already sent for this event");
            return;
          }
          this._responded = true;
          if (msg.requestId !== undefined && window.pbjsNativeReply) {
            const responseData = { error: serializeResponse(error) };
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

        reply: function (data) {
          if (this._responded) {
            console.warn("Response already sent for this event");
            return;
          }
          this._responded = true;
          if (msg.requestId !== undefined && window.pbjsNativeReply) {
            window.pbjsNativeReply(
              JSON.stringify({
                requestId: msg.requestId,
                toWindow: msg.fromWindow,
                fromWindow: WINDOW_NAME,
                data: JSON.stringify(data),
                isGetAll: msg.type === "getAll",
              })
            );
          }
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
              if (!event._responded) {
                log.error("handler exception", err);
                event.error(err instanceof Error ? err.message : String(err));
              }
            });
        } catch (err) {
          if (!event._responded) {
            log.error("handler exception", err);
            event.error(err instanceof Error ? err.message : String(err));
          }
        }
      } else {
        try {
          handler(event, msg.params, msg.data);
        } catch (err) {
          log.error("handler exception", err);
        }
      }
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
          const hasError = response.data && response.data.error;
          log.response(
            response.fromWindow,
            pending.name,
            response.data,
            hasError
          );

          pending.responses.push({
            windowName: response.fromWindow,
            response: response.data,
          });
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
            pending.reject(
              new Error(
                typeof response.data.error === "string"
                  ? response.data.error
                  : JSON.stringify(response.data.error)
              )
            );
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

  window.pbjsBridgeReady = true;
  console.log(
    "%c✓ PBJS Bridge Ready %c" + WINDOW_NAME,
    "color: #4CAF50; font-weight: bold; font-size: 1.1em",
    "color: #2196F3; font-weight: bold"
  );
  window.dispatchEvent(new Event("pbjs-bridge-ready"));
})();
