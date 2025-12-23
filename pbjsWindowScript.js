window.pbjs = {
  ...(window.pbjs || {}),
  version: "DEBUG_V1",
  ready: true,
  init: () => { console.log("PBJS Script Version: DEBUG_V1"); },
  getWindow: async (name) => {
    const pbWindow = await window.pbjsNativeGetWindow(name);
    if (pbWindow.id) {
      return {
        id: pbWindow.id,
        open: async () => {
          return await window.pbjsNativeOpenWindow(pbWindow.id);
        },
        hide: async () => {
          return await window.pbjsNativeHideWindow(pbWindow.id);
        },
        close: async () => {
          return await window.pbjsNativeCloseWindow(pbWindow.id);
        },
      };
    }
    console.log("pbjs.getWindow failed for", name, JSON.stringify(pbWindow));
    return undefined;
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
