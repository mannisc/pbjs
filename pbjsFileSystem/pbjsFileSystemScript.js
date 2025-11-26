(function () {
  "use strict";

  // Helper to generate unique request IDs
  let nextRequestId = 1;
  const pendingRequests = new Map();

  // Logger similar to pbjsBridge
  const log = {
    fs: (method, path, params) => {
      console.log(
        "%cFS %c" + method + " %c" + (path || ""),
        "color: #9C27B0; font-weight: bold",
        "color: #2196F3; font-weight: bold",
        "color: #9E9E9E",
        params || ""
      );
    },
    error: (method, error) => {
      console.error(
        "%cFS ERROR %c" + method,
        "color: #F44336; font-weight: bold",
        "color: #9E9E9E",
        error
      );
    },
  };

  // Native communication wrapper
  function nativeFS(method, args) {
    return new Promise((resolve, reject) => {
      if (!window.pbjsNativeFS) {
        const error = new Error("Native file system not available");
        log.error(method, error);
        reject(error);
        return;
      }

      const requestId = nextRequestId++;
      pendingRequests.set(requestId, { resolve, reject, method });

      // Timeout safety
      setTimeout(() => {
        if (pendingRequests.has(requestId)) {
          pendingRequests.delete(requestId);
          const error = new Error("FS Operation timeout: " + method);
          log.error(method, error);
          reject(error);
        }
      }, 30000);

      try {
        window.pbjsNativeFS(
          JSON.stringify({
            method: method,
            args: args,
            requestId: requestId,
            contextId: window.pbjsFSContextId || ""
          })
        );
      } catch (e) {
        pendingRequests.delete(requestId);
        reject(e);
      }
    });
  }

  // Handle responses from Native
  window.pbjsHandleFSResponse = function (responseJson) {
    try {
      const response = JSON.parse(responseJson);
      const pending = pendingRequests.get(response.requestId);

      if (pending) {
        pendingRequests.delete(response.requestId);
        if (response.error) {
          // Create a proper Error object
          const err = new Error(response.error);
          if (response.code) err.code = response.code;
          pending.reject(err);
        } else {
          pending.resolve(response.data);
        }
      }
    } catch (error) {
      console.error("Error handling FS response:", error);
    }
  };

  // ---------------------------------------------------------
  // FS Implementation
  // ---------------------------------------------------------

  const fs = {};
  const promises = {};

  // Helper to support both callback and promise styles
  function implement(name, fn) {
    // Promise version (fs.promises.xxx)
    promises[name] = fn;

    // Callback version (fs.xxx)
    fs[name] = function (...args) {
      const lastArg = args[args.length - 1];
      if (typeof lastArg === "function") {
        const callback = args.pop();
        fn(...args)
          .then((data) => callback(null, data))
          .catch((err) => callback(err));
      } else {
        // If no callback provided, it behaves like a promise (or just triggers execution)
        // Node.js fs methods usually throw if callback is missing for async methods,
        // but here we can return the promise for convenience.
        return fn(...args);
      }
    };
  }

  // --- Operations ---

  implement("access", (path, mode) => {
    log.fs("access", path, { mode });
    return nativeFS("access", { path, mode });
  });

  implement("appendFile", (path, data, options) => {
    log.fs("appendFile", path);
    return nativeFS("appendFile", { path, data, options });
  });

  implement("chmod", (path, mode) => {
    log.fs("chmod", path, { mode });
    return nativeFS("chmod", { path, mode });
  });

  implement("copyFile", (src, dest, flags) => {
    log.fs("copyFile", src + " -> " + dest, { flags });
    return nativeFS("copyFile", { src, dest, flags });
  });

  // exists is deprecated in Node, but useful.
  // Node's fs.exists has a weird signature (callback(exists) instead of callback(err, exists)).
  // We will implement a custom version or stick to access.
  // Let's implement it as a wrapper around access for convenience, but following Node's deprecated signature style for callback is tricky.
  // Let's stick to a Promise-returning exists that returns boolean.
  fs.exists = function (path, callback) {
    log.fs("exists", path);
    nativeFS("exists", { path })
      .then((result) => {
        if (callback) callback(result);
      })
      .catch(() => {
        if (callback) callback(false);
      });
  };

  implement("mkdir", (path, options) => {
    log.fs("mkdir", path, options);
    return nativeFS("mkdir", { path, options });
  });

  implement("readdir", (path, options) => {
    log.fs("readdir", path, options);
    return nativeFS("readdir", { path, options });
  });

  implement("readFile", (path, options) => {
    log.fs("readFile", path, options);
    return nativeFS("readFile", { path, options });
  });

  implement("rename", (oldPath, newPath) => {
    log.fs("rename", oldPath + " -> " + newPath);
    return nativeFS("rename", { oldPath, newPath });
  });

  implement("rmdir", (path, options) => {
    log.fs("rmdir", path, options);
    return nativeFS("rmdir", { path, options });
  });

  implement("rm", (path, options) => {
    log.fs("rm", path, options);
    return nativeFS("rm", { path, options });
  });

  implement("stat", (path, options) => {
    log.fs("stat", path, options);
    return nativeFS("stat", { path, options }).then((stats) => {
      // Add helper methods to the stats object to mimic Node's fs.Stats
      stats.isFile = () => (stats.mode & 0o100000) === 0o100000; // S_IFREG
      stats.isDirectory = () => (stats.mode & 0o040000) === 0o040000; // S_IFDIR
      stats.isBlockDevice = () => false; // Not supported
      stats.isCharacterDevice = () => false; // Not supported
      stats.isSymbolicLink = () => false; // Not supported
      stats.isFIFO = () => false; // Not supported
      stats.isSocket = () => false; // Not supported
      return stats;
    });
  });

  implement("unlink", (path) => {
    log.fs("unlink", path);
    return nativeFS("unlink", { path });
  });

  implement("writeFile", (file, data, options) => {
    log.fs("writeFile", file);
    return nativeFS("writeFile", { file, data, options });
  });

  // Attach to window
  fs.promises = promises;
  window.fs = fs;

  // Constants
  fs.constants = {
    F_OK: 0,
    R_OK: 4,
    W_OK: 2,
    X_OK: 1,
  };

  console.log(
    "%c✓ JSFileSystem Ready",
    "color: #4CAF50; font-weight: bold; font-size: 1.1em"
  );
})();
