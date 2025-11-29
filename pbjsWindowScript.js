window.pbjs = {
  ...(window.pbjs || {}),
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
    return undefined;
  },
};
