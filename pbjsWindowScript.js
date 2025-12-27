// This script is injected by JSWindow::CreateJSWindow
(async function() {
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
    init: () => { console.log("PBJS Script Version: DEBUG_V1"); },
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
        open: async (params) => window.pbjsNativeOpenWindow(pbWindow.id, JSON.stringify(params)),
        hide: async () => window.pbjsNativeHideWindow(pbWindow.id),
        close: async () => window.pbjsNativeCloseWindow(pbWindow.id),
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
})();
