import type { PbjsHandler } from "./pbjsClient";

// Ambient declarations for the pbjs bridge — the surface `pbjsBridgeScript.js`
// and the PureBasic host actually install on `window`.
//
// This is the BRIDGE, not the client: `window.pbjs.dndStart` is a bridge
// method, `pbjs.drag.start` is the client's. Keeping the two apart is the whole
// point of having this file next to pbjsClient.ts.

declare global {
  /**
   * Reply to a native bridge call. The host answers in JSON, so nothing
   * stronger than "some JSON value" is knowable here; callers that need a shape
   * narrow it themselves (see e.g. Pbjs.getWindowMetrics).
   */
  type PbjsNativeReply = unknown;

  /** Node-shaped fs options, as far as the shim forwards them. */
  type FsReadOptions = string | { encoding?: string; flag?: string };

  /** The subset of `fs.Stats` the shim actually returns. */
  interface FsStats {
    size?: number;
    mtimeMs?: number;
    isDirectory?: () => boolean;
    isFile?: () => boolean;
  }

  interface PBWindow {
    id: number;
    open: (params?: Record<string, unknown>) => Promise<PbjsNativeReply>;
    isOpen: () => Promise<boolean>;
    close: () => Promise<PbjsNativeReply>;
    hide: () => Promise<PbjsNativeReply>;
    show: () => Promise<PbjsNativeReply>;
  }

  interface Window {
    pbjs: {
      ready?: boolean;
      windowName: string;
      os: string;
      /**
       * Read once at page load from the native host — true iff DndService
       * actually started (host has it, PBJS_DND!=0, macOS, not browser-hosted).
       * Unlike checking whether the pbjsNativeDnd* functions exist (they're
       * bound regardless of Enabled), this reflects reality. See
       * PbjsDragService.available in the client.
       */
      dndAvailable?: boolean;
      darkMode: boolean;
      isDarkMode: () => boolean;
      registerDarkModeChangeHandler: (
        handler: (isDark: boolean) => void
      ) => void;
      onCloseWindow: (handler: () => boolean | Promise<boolean>) => void;
      //windows
      getWindow: (name: string) => Promise<PBWindow | undefined>;
      waitForWindow: (
        name: string,
        maxAttempts?: number
      ) => Promise<PBWindow | undefined>;
      openInstance: (
        templateName: string,
        instanceKey: string,
        params?: Record<string, unknown>,
        reloadOnReuse?: boolean,
        options?: {
          smartPosition?: boolean;
          /** Explicit position in desktop coords (DnD drop-point placement). */
          atScreen?: { x: number; y: number };
        },
      ) => Promise<{
        success?: boolean;
        name?: string;
        id?: number;
        error?: string;
      }>;
      // Cross-window drag & drop (absent on hosts without DndService, and when
      // browser-hosted — feature-detect before use; see Pbjs.drag).
      dndStart?: (spec: {
        type: string;
        payloadJson: string;
        badge?: { icon?: string; label?: string };
      }) => Promise<{ sessionId?: string; error?: string }>;
      dndDrop?: (sessionId: string) => Promise<{ error?: string } | null>;
      dndCancel?: (sessionId: string) => Promise<PbjsNativeReply>;
      dndUpdateBadge?: (
        sessionId: string,
        badge: { icon?: string; label?: string },
      ) => Promise<PbjsNativeReply>;
      dndSetZoneActive?: (
        sessionId: string,
        active: boolean,
      ) => Promise<PbjsNativeReply>;
      dndRegisterTarget?: (types: string[]) => Promise<PbjsNativeReply>;
      dndUnregisterTarget?: () => Promise<PbjsNativeReply>;
      //messages
      // `params`/`data` are opaque payload slots — the transport does not
      // interpret them, so `unknown` here accepts any argument while promising
      // the callee nothing. See PbjsHandler in the client.
      invoke: (
        windowName: string,
        name: string,
        params?: unknown,
        data?: unknown,
        options?: { signal?: AbortSignal }
      ) => Promise<PbjsNativeReply>;
      invokeAll: (
        name: string,
        params?: unknown,
        data?: unknown
      ) => Promise<PbjsNativeReply[]>;
      send: (
        windowName: string,
        name: string,
        params?: unknown,
        data?: unknown
      ) => void;
      sendAll: (name: string, params?: unknown, data?: unknown) => void;
      stats?: () => Record<string, number | string>;
      handle: (
        windowName: string,
        name: string,
        handler: PbjsHandler
      ) => void;
      handleAll: (name: string, handler: PbjsHandler) => void;
      removeHandler: (windowName: string, name: string) => void;
      removeAllHandlers: () => void;
    };

    /** Flipped by the FS bridge shim once native bindings are live. */
    pbjsFileSystemReady?: boolean;

    /**
     * Native filesystem bridge (pbjsFileSystemScript.js + the PureBasic
     * dispatch). OPTIONAL on purpose: in plain-browser dev there is no host, so
     * callers must handle its absence rather than assume a bridge.
     */
    fs?: {
      promises: {
        readFile: (path: string, options?: FsReadOptions) => Promise<string>;
        writeFile: (
          path: string,
          data: string,
          options?: FsReadOptions,
        ) => Promise<void>;
        access: (path: string) => Promise<void>;
        mkdir: (path: string) => Promise<void>;
        readdir: (path: string) => Promise<string[]>;
        stat: (path: string) => Promise<FsStats>;
        unlink: (path: string) => Promise<void>;
        // NB: the JS shim (pbjsFileSystemScript.js) also exposes copyFile,
        // appendFile, chmod and rm, but the PureBasic dispatch has no case for
        // them — they reject with "Method not implemented". Deliberately not
        // declared here so they aren't reached for by accident.
      };
    };

    pbjsNativeSetWindowTitle?: (
      windowName: string,
      newTitle: string,
    ) => Promise<PbjsNativeReply>;
    pbjsNativeFocusWindow?: (
      windowName: string,
    ) => Promise<PbjsNativeReply>;
    pbjsNativeStartWindowDrag?: (
      windowName: string,
      screenX: string,
      screenY: string,
    ) => Promise<PbjsNativeReply>;
    pbjsNativeSetWindowState?: (
      windowName: string,
      state: "minimize" | "maximize" | "restore" | "toggle" | "close",
    ) => Promise<PbjsNativeReply>;
    pbjsNativeGetWindowMetrics?: (
      windowName: string,
    ) => Promise<PbjsNativeReply>;
    /**
     * Pushed by the host on every window resize: the REAL window size, which
     * differs from the page viewport (the WebViewGadget is oversized and
     * clipped). The consuming app defines it.
     */
    pbjsUpdateScale?: (
      width: number,
      height: number,
      maximized?: boolean,
    ) => void;
    pbjsHandleMessage: (messageJson: string) => void;
    pbjsHandleResponse: (responseJson: string) => void;
    pbjsSetGetAllExpectedCount: (requestId: number, count: number) => void;
    pbjsReady: boolean;
  }
}

export {};
