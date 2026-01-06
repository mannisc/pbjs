// This script is injected by JSWindow::CreateJSWindow
(async function () {
  const waitForNative = async () => {
    let attempts = 0;
    while (!window.pbjsNativeGetWindow && attempts < 20) {
      await new Promise(r => setTimeout(r, 50));
      attempts++;
    }
    if (!window.pbjsNativeGetWindow) {
      console.error("pbjsNativeGetWindow failed to appear");
    }
  };

  await waitForNative();

  window.pbjs = {
    ...(window.pbjs || {}),
    version: "DEBUG_V1",
    ready: true,
    darkModeHandlers: [],
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
      console.log("PBJS Script Version: DEBUG_V1");
      if (window.pbjs.isDarkMode()) {
        document.documentElement.classList.add('dark');
      } else {
        document.documentElement.classList.remove('dark');
      }
    },
    getWindow: async (name) => {
      if (!window.pbjsNativeGetWindow) {
        console.error("pbjsNativeGetWindow missing");
        return undefined;
      }
      const pbWindow = await window.pbjsNativeGetWindow(name);
      if (!pbWindow || pbWindow.error) {
        console.log("pbjs.getWindow failed for", name, JSON.stringify(pbWindow));
        return undefined;
      }
      return {
        ...pbWindow,
        open: async (params) => window.pbjsNativeOpenWindow(String(pbWindow.id), JSON.stringify(params)),
        hide: async () => window.pbjsNativeHideWindow(String(pbWindow.id)),
        close: async () => window.pbjsNativeCloseWindow(String(pbWindow.id)),
      };
    },
    waitForWindow: async (name, maxAttempts = 50) => {
      for (let i = 0; i < maxAttempts; i++) {
        const win = await window.pbjs.getWindow(name);
        if (win && win.id) {
          return win;
        }
        // Wait 100ms before retry
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      console.error(`[pbjs] Failed to resolve window '${name}' after ${maxAttempts} attempts`);
      return undefined;
    },
  };

  window.pbjsReady = true;
  console.log(
    "%c✓ PBJS Bridge Core Ready %c" + WINDOW_NAME,
    "color: #4CAF50; font-weight: bold; font-size: 1.1em",
    "color: #2196F3; font-weight: bold"
  );
  window.dispatchEvent(new Event("pbjs-ready"));
})();
