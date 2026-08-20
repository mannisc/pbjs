/**
 * Pbjs - Singleton wrapper for the PBJS bridge (window.pbjs)
 *
 * Provides a clean, importable API following the Bridge Service pattern.
 *
 * Usage:
 *   import { pbjs } from "./pbjsClient";
 *
 *   // Methods automatically wait for the bridge to be ready
 *   const result = await pbjs.invoke("target-window", "methodName", params);
 */

/**
 * The request envelope handed to a `handle`/`handleAll` callback.
 *
 * A handler replies by returning a value; `success`/`error` are the explicit
 * form for the same thing (see `pbjs/README.md`). Both are optional because a
 * fire-and-forget `send`/`sendAll` has no caller to reply to.
 */
export interface PbjsEvent {
  /** Name of the window the message came from. */
  fromWindow?: string;
  /** Resolve the caller's `invoke` with this value. */
  success?: (value?: unknown) => void;
  /** Reject the caller's `invoke` with this message. */
  error?: (message: string) => void;
}

/**
 * A `handle`/`handleAll` callback.
 *
 * `params` and `data` are the bridge's two payload slots, and the transport
 * interprets neither — CLAUDE.md's convention is that senders put the payload
 * in `data` and handlers read `data || params`. So `T` is what THIS handler
 * expects to find there: an assertion about its callers, in the same sense that
 * typing a `JSON.parse` result is. It is not checked at runtime, which is why
 * every handler below still guards the fields it actually uses.
 *
 * Both slots are `T | undefined` because a sender may fill only one of them.
 */
export type PbjsHandler<T = unknown, R = unknown> = (
  event: PbjsEvent,
  params: T | undefined,
  data: T | undefined
) => R | Promise<R>;

/** Metadata delivered to a channel subscriber alongside the payload. */
export interface PbjsChannelMeta {
  /** Window name the message originated from. */
  from: string;
}

/** A channel subscriber callback. */
export type ChannelHandler<T = unknown> = (
  payload: T,
  meta: PbjsChannelMeta
) => void;
/**
 * Internal registry entry. `never` is the payload type every `ChannelHandler<T>`
 * is assignable to (parameters are contravariant), so one Set can hold
 * subscribers that each declared a different `T`. The fan-out below widens back
 * to `unknown` to call them — the erasure is real, and each subscriber owns the
 * assertion it made when it declared its own `T`.
 */
type ChannelSubscriber = ChannelHandler<never>;

/** A named pub/sub channel over the pbjs bridge (see {@link Pbjs.channel}). */
export interface PbjsChannel<T = unknown> {
  /** Broadcast to every other window's subscribers (sender excluded). */
  post(payload: T): void;
  /** Send to a single window's subscribers. */
  send(targetWindow: string, payload: T): void;
  /** Subscribe; returns an unsubscribe function. */
  subscribe(handler: ChannelHandler<T>): () => void;
  /** Remove all subscriptions created via this channel instance. */
  close(): void;
}

/**
 * Strip the bridge's `{ success: value }` reply envelope to the bare value.
 * The `typeof === "object"` guard leaves primitives / strings / arrays / null
 * untouched. Errors reject upstream, so a resolved invoke is always `{ success }`
 * — but this stays defensive for any unexpected shape.
 */
function unwrapSuccess(reply: unknown): unknown {
  return reply && typeof reply === "object" && "success" in reply
    ? (reply as { success: unknown }).success
    : reply;
}

/**
 * Integration points an embedding app installs via {@link Pbjs.configureHost}.
 *
 * This client knows nothing about any particular app's windows, dev-server
 * layout, or browser-hosting arrangements — this is where that knowledge is
 * handed in. Everything here is optional; unset, the client behaves as if the
 * page were always running inside a real native webview.
 */
export interface PbjsHostHooks {
  /** True when this page is a browser tab rather than a native webview. */
  isBrowserHosted?: () => boolean;
  /**
   * Called after {@link Pbjs.openInstance} succeeds *while browser-hosted*.
   *
   * A browser-hosted instance is created HEADLESS by the host: it exists and is
   * addressable, but nothing is on screen until a tab attaches to it. The
   * embedding app is the only layer that knows how one of its tabs is reached,
   * so surfacing it is its job, not the transport's.
   */
  onInstanceOpened?: (info: {
    templateName: string;
    instanceName: string;
    params?: Record<string, unknown>;
  }) => void;
}

export class Pbjs {
  private initialized = false;

  // --- Channel (pub/sub) state ---
  // topic -> set of local subscriber callbacks. The bridge allows only one
  // handler per name, so each topic registers a single handleAll() that fans
  // out to every local subscriber here.
  private channelSubs = new Map<string, Set<ChannelSubscriber>>();
  private channelRegistered = new Set<string>();

  // --- Host integration ---

  private hooks: PbjsHostHooks = {};

  /**
   * Install the embedding app's integration points. Merges, so separate
   * concerns can register independently; call it before the first
   * {@link openInstance}.
   */
  configureHost(hooks: PbjsHostHooks): void {
    this.hooks = { ...this.hooks, ...hooks };
  }

  // --- Properties ---

  /**
   * Check if the bridge is ready (synchronous).
   */
  get isReady(): boolean {
    return !!window.pbjsReady || !!window.pbjs?.ready;
  }

  /**
   * Get the current window's name.
   */
  get windowName(): string {
    return window.pbjs?.windowName ?? "";
  }

  /**
   * Get the operating system.
   */
  get os(): "windows" | "mac" | "linux" | "other" {
    return this.getOs() as "windows" | "mac" | "linux" | "other";
  }

  // --- Initialization & Waiters ---

  /**
   * Initialize the Pbjs service.
   * Currently a no-op since pbjsBridgeScript.js handles setup,
   * but included for API consistency with other bridge services.
   */
  init(): void {
    if (this.initialized) return;
    this.initialized = true;
    // pbjsBridgeScript.js handles all initialization
  }

  getOs(): string {
    if (this.isReady) {
      return window.pbjs?.os ?? "other";
    }
    const getOSName = (): "windows" | "mac" | "linux" | "other" => {
      // Strategy 1: Modern User Agent Data (High confidence).
      // Experimental API — not in lib.dom, so it is declared inline here rather
      // than asserted away.
      const navData = (
        navigator as Navigator & { userAgentData?: { platform?: string } }
      ).userAgentData;
      if (navData?.platform) {
        const p = navData.platform.toLowerCase();
        if (p.includes("win")) return "windows";
        if (p.includes("mac")) return "mac";
        if (p.includes("linux")) return "linux";
      }

      // Strategy 2: Legacy Navigator Platform
      const navPlatform = (navigator.platform || "").toLowerCase();
      if (navPlatform.startsWith("mac")) return "mac";
      if (navPlatform.startsWith("win")) return "windows";
      if (navPlatform.includes("linux")) return "linux";

      // Strategy 3: User Agent String Parsing (Broadest compatibility)
      const ua = navigator.userAgent.toLowerCase();
      if (ua.includes("macintosh") || ua.includes("mac os x")) return "mac";
      if (ua.includes("windows") || ua.includes("win32")) return "windows";
      if (ua.includes("linux")) return "linux";

      // Strategy 4: Fallback for less common identifiers
      if (
        navPlatform.includes("iphone") ||
        navPlatform.includes("ipad") ||
        navPlatform.includes("ipod")
      )
        return "mac"; // iOS often treated as Mac

      return "other";
    };
    return getOSName();
  }

  /**
   * Wait for the PBJS bridge to be ready.
   * @param timeout Optional timeout in milliseconds for warning logs (default: 3000)
   */
  waitForReady(timeout = 3000): Promise<void> {
    return new Promise<void>((resolve) => {
      if (this.isReady) {
        resolve();
        return;
      }

      console.log("[Pbjs] Waiting for Bridge Ready...");
      const handler = () => {
        window.removeEventListener("pbjs-ready", handler);
        console.log("[Pbjs] Bridge Ready Event Received");
        resolve();
      };
      window.addEventListener("pbjs-ready", handler);

      // Warning log only - do NOT resolve on timeout
      setTimeout(() => {
        if (!this.isReady) {
          console.warn(
            `[Pbjs] Still waiting for pbjs-ready after ${timeout}ms...`
          );
        }
      }, timeout);
    });
  }

  /**
   * Wait for the PBJS Filesystem to be ready (including native bindings).
   *
   * REJECTS on timeout — it must never report readiness it hasn't observed.
   * This used to resolve() instead, so callers proceeded believing `window.fs`
   * existed when the bridge was simply slow (routine when browser-hosted, where
   * the FS bridge only lands after the socket attach). A store hydrating on boot
   * then read nothing, and its fallback wrote defaults over the user's real
   * data file.
   *
   * The default is generous on purpose. Natively the bridge is up in
   * milliseconds, but browser-hosted it cannot exist until the page has connected
   * to the relay AND the PureBasic host has bootstrapped the tab — a chain that
   * starts only once PB itself has finished compiling and launching. A short
   * budget there just reports a failure that hasn't happened yet.
   * @param timeout Maximum time to wait in milliseconds
   */
  waitForFSReady(timeout = 30000): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (window.pbjsFileSystemReady) {
        resolve();
        return;
      }

      // `timer` is declared after `handler` but referenced inside it: the
      // closure only runs once the event fires, by which point the binding is
      // initialized.
      const handler = () => {
        window.removeEventListener("pbjs-fs-ready", handler);
        clearTimeout(timer);
        resolve();
      };

      window.addEventListener("pbjs-fs-ready", handler);

      const timer = setTimeout(() => {
        window.removeEventListener("pbjs-fs-ready", handler);
        reject(new Error(`FS bridge not ready after ${timeout}ms`));
      }, timeout);
    });
  }

  /**
   * Helper to execute an action only when the bridge is ready.
   * If not ready, waits for the readiness event indefinitely to ensure
   * handlers are never dropped due to timeout.
   */
  private executeWhenReady(action: () => void, description: string) {
    if (this.isReady) {
      try {
        action();
      } catch (e) {
        console.error(`[Pbjs] Error executing ${description}:`, e);
      }
      return;
    }

    console.log(`[Pbjs] Waiting for bridge to execute: ${description}`);
    const handler = () => {
      window.removeEventListener("pbjs-ready", handler);
      try {
        console.log(`[Pbjs] Bridge ready, executing delayed: ${description}`);
        action();
      } catch (e) {
        console.error(`[Pbjs] Error executing ${description} (delayed):`, e);
      }
    };
    window.addEventListener("pbjs-ready", handler);
  }
  // --- IPC Methods ---

  /**
   * Invoke a method on a specific window.
   * @param targetWindow The window to invoke on
   * @param name The method name
   * @param params Optional parameters
   * @param data Optional data payload
   * @param options Optional `{ signal }` — abort the request to stop waiting on a
   *   superseded call (the late reply, if any, is ignored). Rejects with an
   *   AbortError on abort. (F9.)
   *
   * Resolves to the **handler's return value**. The bridge's internal
   * `{ success: value }` reply envelope (its wire shape, used to distinguish
   * success from error) is unwrapped here, so app code never sees it. Error
   * replies reject, so a resolved invoke is always the bare value.
   */
  async invoke<T = unknown>(
    targetWindow: string,
    name: string,
    params?: unknown,
    data?: unknown,
    options?: { signal?: AbortSignal }
  ): Promise<T> {
    if (!this.isReady) {
      await this.waitForReady();
    }
    if (!window.pbjs?.invoke) {
      return Promise.reject(new Error("Pbjs not ready: invoke not available"));
    }
    // Forward `options` only when provided so call sites without it keep the
    // historical 4-arg shape.
    const reply = options
      ? window.pbjs.invoke(targetWindow, name, params, data, options)
      : window.pbjs.invoke(targetWindow, name, params, data);
    return reply.then(unwrapSuccess) as Promise<T>;
  }

  /**
   * Invoke a method on all windows (broadcast request/response).
   *
   * ⚠️ **Discouraged — has no production caller.** Prefer the alternatives:
   * `channel`/`sendAll` for fire-and-forget events/patches, and a per-window
   * `invoke` for RPC. `invokeAll` is a true "ask everyone and aggregate"
   * primitive only — and it has sharp edges (it can't surface per-window failure;
   * its replies are the raw `{ success }`/`{ error }` envelope per window; spare
   * filtering must stay correct — see pbjs.md F8/F13). Reach for it only if you
   * genuinely need to collect a reply from every window at once.
   *
   * @param name The method name
   * @param params Optional parameters
   * @param data Optional data payload
   */
  async invokeAll<T = unknown>(
    name: string,
    params?: unknown,
    data?: unknown
  ): Promise<T[]> {
    if (!this.isReady) {
      await this.waitForReady();
    }
    if (!window.pbjs?.invokeAll) {
      return Promise.reject(
        new Error("Pbjs not ready: invokeAll not available")
      );
    }
    return window.pbjs.invokeAll(name, params, data) as Promise<T[]>;
  }

  /**
   * Fire-and-forget message to a single window. No response, no Promise, no
   * timeout — use when you don't need a reply (events, notifications, state
   * patches). For request/response use {@link invoke}.
   *
   * Defers until the bridge is ready (never dropped). If the target window
   * exists but isn't ready, the native side buffers the message; if it doesn't
   * exist, the message is dropped silently.
   * @param targetWindow The window to message
   * @param name The handler name
   * @param params Optional parameters
   * @param data Optional data payload
   */
  send(
    targetWindow: string,
    name: string,
    params?: unknown,
    data?: unknown
  ): void {
    this.executeWhenReady(() => {
      window.pbjs?.send?.(targetWindow, name, params, data);
    }, `send for ${targetWindow}:${name}`);
  }

  /**
   * Fire-and-forget broadcast to all windows except the sender. Same no-reply
   * semantics as {@link send}. The cheap primitive for events and cross-window
   * state sync; for request/response use {@link invokeAll}.
   * @param name The handler name
   * @param params Optional parameters
   * @param data Optional data payload
   */
  sendAll(
    name: string,
    params?: unknown,
    data?: unknown
  ): void {
    this.executeWhenReady(() => {
      window.pbjs?.sendAll?.(name, params, data);
    }, `sendAll for *:${name}`);
  }

  /**
   * Snapshot of bridge counters for diagnostics (P5 observability): in-flight
   * requests, buffered/dropped messages, dead-letters, ready-cache size, handler
   * count. Returns `{}` if the bridge isn't ready. Also queryable directly via
   * `window.pbjs.stats()` in any window's devtools.
   */
  stats(): Record<string, number | string> {
    return window.pbjs?.stats?.() ?? {};
  }

  /**
   * Register a handler for a specific window.
   * @param targetWindow The window to handle messages from (empty string for current)
   * @param name The handler name
   * @param handler The callback function
   */
  handle<T = unknown, R = unknown>(
    targetWindow: string,
    name: string,
    handler: PbjsHandler<T, R>
  ): void {
    this.executeWhenReady(() => {
      window.pbjs?.handle?.(targetWindow, name, handler as PbjsHandler);
    }, `handle for ${targetWindow}:${name}`);
  }

  /**
   * Register a handler for all windows.
   * @param name The handler name
   * @param handler The callback function
   */
  handleAll<T = unknown, R = unknown>(
    name: string,
    handler: PbjsHandler<T, R>
  ): void {
    this.executeWhenReady(() => {
      window.pbjs?.handleAll?.(name, handler as PbjsHandler);
    }, `handleAll for *:${name}`);
  }

  /**
   * Remove a handler for a specific window.
   */
  removeHandler(targetWindow: string, name: string): void {
    this.executeWhenReady(() => {
      window.pbjs?.removeHandler?.(targetWindow, name);
    }, `removeHandler for ${targetWindow}:${name}`);
  }

  /**
   * Remove all handlers.
   */
  removeAllHandlers(): void {
    window.pbjs?.removeAllHandlers?.();
  }

  // --- Channels (pub/sub topics) ---

  /**
   * Open a named broadcast channel — a BroadcastChannel-like pub/sub layer over
   * the fire-and-forget `send`/`sendAll` primitives. Decouples senders from
   * concrete window names and supports multiple local subscribers per topic
   * (which raw `handleAll` does not). Echo-free: the native broadcast excludes
   * the sender, so a window never receives its own `post`.
   *
   * ```ts
   * const ch = pbjs.channel("items");
   * const off = ch.subscribe((payload, { from }) => applyPatch(payload));
   * ch.post({ id, status: "running" });   // reaches other windows' subscribers
   * off();                                 // unsubscribe; ch.close() removes all
   * ```
   *
   * @param name Logical topic name (namespaced internally; can't collide with
   *   plain `handle`/`handleAll` names).
   */
  channel<T = unknown>(name: string): PbjsChannel<T> {
    const topic = `chan:${name}`;
    const localUnsubs = new Set<() => void>();
    return {
      post: (payload: T): void => {
        this.sendAll(topic, {}, { v: payload });
      },
      send: (targetWindow: string, payload: T): void => {
        this.send(targetWindow, topic, {}, { v: payload });
      },
      subscribe: (handler: ChannelHandler<T>): (() => void) => {
        const baseUnsub = this.channelSubscribe(topic, handler as ChannelSubscriber);
        const unsub = () => {
          baseUnsub();
          localUnsubs.delete(unsub);
        };
        localUnsubs.add(unsub);
        return unsub;
      },
      close: (): void => {
        // Only tears down subscriptions created via this channel instance.
        localUnsubs.forEach((u) => u());
        localUnsubs.clear();
      },
    };
  }

  /**
   * Internal: add a subscriber for a topic, lazily registering the single
   * bridge handler that fans out to all subscribers. Returns an unsubscribe
   * that removes the bridge handler once the last subscriber leaves.
   */
  private channelSubscribe(
    topic: string,
    handler: ChannelSubscriber
  ): () => void {
    let subs = this.channelSubs.get(topic);
    if (!subs) {
      subs = new Set();
      this.channelSubs.set(topic, subs);
    }
    subs.add(handler);

    if (!this.channelRegistered.has(topic)) {
      this.channelRegistered.add(topic);
      this.handleAll<{ v?: unknown }>(topic, (event, _params, data) => {
        const set = this.channelSubs.get(topic);
        if (!set) return;
        const meta = { from: event?.fromWindow ?? "" };
        // Payload is wrapped as { v } so primitives/falsy values survive.
        const payload = data?.v;
        set.forEach((h) => {
          try {
            // Widen back from the erased `never` the registry stores; see
            // ChannelSubscriber.
            (h as ChannelHandler<unknown>)(payload, meta);
          } catch (e) {
            console.error(`[Pbjs.channel:${topic}] subscriber error`, e);
          }
        });
      });
    }

    return () => {
      const set = this.channelSubs.get(topic);
      if (!set) return;
      set.delete(handler);
      if (set.size === 0) {
        this.channelSubs.delete(topic);
        this.channelRegistered.delete(topic);
        this.removeHandler("", topic);
      }
    };
  }

  // --- Window Management ---

  /**
   * Get a reference to a window by name.
   */
  async getWindow(name: string): Promise<PBWindow | undefined> {
    if (!this.isReady) {
      await this.waitForReady();
    }
    if (!window.pbjs?.getWindow) {
      return Promise.resolve(undefined);
    }
    return window.pbjs.getWindow(name);
  }

  /**
   * Wait for a window to become available.
   * @param name The window name
   * @param maxAttempts Maximum attempts to find the window
   */
  async waitForWindow(
    name: string,
    maxAttempts?: number
  ): Promise<PBWindow | undefined> {
    if (!this.isReady) {
      await this.waitForReady();
    }
    if (!window.pbjs?.waitForWindow) {
      return Promise.resolve(undefined);
    }
    return window.pbjs.waitForWindow(name, maxAttempts);
  }

  /**
   * Open or focus an instance of a registered multi-instance template.
   *
   * - `templateName` is an opaque string registered on the PB side via
   *   `JSWindow::RegisterTemplate` (e.g. `"editor-window"`).
   * - `instanceKey` is a caller-supplied opaque dedupe key. If a window for
   *   the same key is already open, it is brought to front instead of a new
   *   one being created. Pass `""` to disable dedupe (every call opens a
   *   new window).
   * - `params` is delivered to the target window as a `"handleParameters"`
   *   bridge message. JSWindow does not interpret it.
   *
   * Browser-hosted: the host still does the work — it creates the instance
   * HEADLESS (no OS window) and returns the runtime name. A headless instance
   * only becomes visible once a browser tab attaches to it, so
   * {@link PbjsHostHooks.onInstanceOpened} fires to let the embedding app
   * surface that tab however it wants. Nothing happens here without the hook.
   */
  async openInstance(
    templateName: string,
    instanceKey: string,
    params?: Record<string, unknown>,
    options?: {
      reloadOnReuse?: boolean;
      smartPosition?: boolean;
      /** Explicit position in desktop coords (DnD drop-point placement). */
      atScreen?: { x: number; y: number };
    },
  ): Promise<{ success?: boolean; name?: string; id?: number; error?: string }> {
    if (!this.isReady) {
      await this.waitForReady();
    }
    if (!window.pbjs?.openInstance) {
      const error = "pbjs.openInstance not available (no host bridge)";
      console.warn(`openInstance("${templateName}"): ${error}`);
      return { success: false, error };
    }
    const result = await window.pbjs.openInstance(
      templateName,
      instanceKey,
      params,
      options?.reloadOnReuse ?? false,
      {
        smartPosition: options?.smartPosition ?? false,
        atScreen: options?.atScreen,
      },
    );

    if (this.hooks.isBrowserHosted?.() && result?.name) {
      this.hooks.onInstanceOpened?.({
        templateName,
        instanceName: result.name,
        params,
      });
    }
    return result;
  }

  /**
   * Set the OS title bar text of a window by its runtime name.
   * Targets the current window when called from within that window's context.
   */
  async setWindowTitle(newTitle: string): Promise<void> {
    if (!this.isReady) await this.waitForReady();
    if (!window.pbjsNativeSetWindowTitle) return;
    await window.pbjsNativeSetWindowTitle(this.windowName, newTitle);
  }

  /**
   * Bring a window to the foreground by its runtime name. Used by the
   * cross-window singleton agent-tab logic to surface the window that already
   * hosts an agent's tab. No-op if the bridge or window isn't available.
   */
  async focusWindow(name: string): Promise<void> {
    if (!this.isReady) await this.waitForReady();
    if (!window.pbjsNativeFocusWindow) return;
    await window.pbjsNativeFocusWindow(name);
  }

  /**
   * Begin a native window drag, for a title bar drawn by the page.
   *
   * The window's content view spans the whole frame, so the OS never sees a
   * caption mousedown — DefaultWindowComponent forwards it here on pointerdown.
   * The host hands the drag straight to the window manager, so snapping and
   * multi-monitor behaviour stay native. Deliberately not awaited by callers:
   * on macOS the selector blocks for the duration of the drag.
   *
   * `screenX`/`screenY` are only used on Linux, where GTK needs the press
   * position in root coordinates.
   */
  /**
   * Minimize / maximize / restore / close this window, for the buttons the page
   * draws. `"close"` goes through the same event the OS close button raised, so
   * the app-close confirmation flow still runs — it is not a hard teardown.
   */
  async setWindowState(
    state: "minimize" | "maximize" | "restore" | "toggle" | "close",
  ): Promise<void> {
    if (!this.isReady) await this.waitForReady();
    if (!window.pbjsNativeSetWindowState) return;
    await window.pbjsNativeSetWindowState(this.windowName, state);
  }

  /**
   * The real window size — NOT the page viewport.
   *
   * The host creates the WebViewGadget at desktop size and lets the window clip
   * it, so `window.innerWidth/innerHeight` report the desktop, not the window
   * (e.g. 1512x982 inside an 1291x850 window). Anything anchored to the right or
   * bottom edge has to use these numbers. Prefer the `useWindowMetrics` hook,
   * which also tracks resizes.
   */
  async getWindowMetrics(): Promise<{
    width: number;
    height: number;
    maximized: boolean;
  } | null> {
    if (!this.isReady) await this.waitForReady();
    if (!window.pbjsNativeGetWindowMetrics) return null;
    try {
      const raw = await window.pbjsNativeGetWindowMetrics(this.windowName);
      const m = typeof raw === "string" ? JSON.parse(raw) : raw;
      if (typeof m?.width !== "number" || typeof m?.height !== "number") {
        return null;
      }
      return { width: m.width, height: m.height, maximized: !!m.maximized };
    } catch {
      return null;
    }
  }

  startWindowDrag(screenX: number, screenY: number): void {
    if (!window.pbjsNativeStartWindowDrag) return;
    void window.pbjsNativeStartWindowDrag(
      this.windowName,
      String(Math.round(screenX)),
      String(Math.round(screenY)),
    );
  }

  // --- Theme ---

  /**
   * Check if dark mode is active.
   */
  isDarkMode(): boolean {
    return window.pbjs?.isDarkMode?.() ?? false;
  }

  /**
   * Register a handler for dark mode changes.
   */
  onDarkModeChange(handler: (isDark: boolean) => void): void {
    this.executeWhenReady(() => {
      window.pbjs?.registerDarkModeChangeHandler?.(handler);
    }, "onDarkModeChange");
  }

  /**
   * Register a handler for window close requests.
   * Return true to allow closing, false to prevent it.
   */
  onCloseWindow(handler: () => boolean | Promise<boolean>): void {
    console.log("Pbjs: onCloseWindow register executeWhenReady");

    this.executeWhenReady(() => {
      console.log("Pbjs: onCloseWindow register");

      window.pbjs?.onCloseWindow?.(handler);
    }, "onCloseWindow");
  }

  // --- Cross-window drag & drop ---

  private _drag?: PbjsDragService;

  /**
   * Cross-window drag & drop sessions (native cursor badge, window hit-testing,
   * targeted drops). Feature-detect with `pbjs.drag.available` — absent on
   * hosts without DndService (old binary, non-macOS, PBJS_DND=0) and when
   * browser-hosted, in which case callers fall back to their legacy behavior.
   */
  get drag(): PbjsDragService {
    if (!this._drag) this._drag = new PbjsDragService(this);
    return this._drag;
  }
}

// ─── Cross-window drag & drop (pbjs.drag) ───────────────────────────────────

export interface DragBadgeSpec {
  /** Named native icon (e.g. "terminal"; unknown names fall back to it). */
  icon?: string;
  /** One-line label next to the icon (the dragged item's display name). */
  label?: string;
}

export interface DragStartSpec {
  /** Payload type, e.g. "application/x-myapp-tab". */
  type: string;
  /** JSON-serializable payload, delivered verbatim to target handlers. */
  payload: unknown;
  badge?: DragBadgeSpec;
}

export type DragOverState =
  | { over: "source" }
  | { over: "none" }
  | { over: "target"; window: string };

export type DropReason =
  | "no-target"
  | "rejected"
  | "reverted"
  | "over-source"
  | "timeout"
  | "cancelled";

export interface DropResult {
  accepted: boolean;
  /** Accepting window (accepted drops only). */
  window?: string;
  /** The target onDrop handler's return value (accepted drops only). */
  response?: unknown;
  reason?: DropReason;
  /** Drop point in desktop coords (reason "no-target" only). */
  screenX?: number;
  screenY?: number;
}

export interface DragTargetEvent {
  sessionId: string;
  type: string;
  /** Delivered verbatim from the source's {@link DragStartSpec.payload}. */
  payload: unknown;
  sourceWindow: string;
  /** Cursor in this window's CSS px. */
  x: number;
  y: number;
  /** Cursor in desktop coords. */
  screenX: number;
  screenY: number;
}

// ── Native → page DnD frames ────────────────────────────────────────────────
// The shapes the host puts in the `params` slot of the `dnd:*` messages. They
// are declared here rather than inferred because they are a wire contract with
// `pbjs/modules/DndService.pb` — see docs/dnd.md.

/** Any dnd frame: the session id is what routes it to the right session. */
interface DndSessionFrame {
  sessionId?: string;
  /** Present on target-side frames; selects the registration to notify. */
  type?: string;
}

/** `dnd:state` — which window the cursor is currently over. */
interface DndStateFrame extends DndSessionFrame {
  over?: "source" | "target" | "none";
  /** The target window's name (`over: "target"` only). */
  window?: string;
}

/** `dnd:dropResult` — the resolved outcome, forwarded to the waiting `drop()`. */
interface DndDropResultFrame extends DndSessionFrame {
  result?: DropResult;
}

/** `dnd:over` — a cursor move within an already-entered target. */
interface DndPointerFrame extends DndSessionFrame {
  x: number;
  y: number;
  screenX: number;
  screenY: number;
}

export interface DragSession {
  readonly id: string;
  /** Subscribe to over-state changes; returns an unsubscribe function. */
  onStateChange(cb: (s: DragOverState) => void): () => void;
  /** Swap badge icon/label mid-drag. */
  updateBadge(patch: DragBadgeSpec): void;
  /**
   * Resolve the session at pointer-up. Routes by what the cursor is over:
   * target window → its onDrop decides (accepted / reverted / rejected);
   * source window → over-source; nothing → no-target with the drop point.
   */
  drop(): Promise<DropResult>;
  cancel(): Promise<void>;
}

export interface DragTargetRegistration {
  types: string[];
  onEnter?(e: DragTargetEvent): void;
  onOver?(e: DragTargetEvent): void;
  onLeave?(): void;
  /**
   * Return `{ revert: true }` to send the tab back to its source (cursor
   * inside the window but outside the drop zone), `{ reject: true }` on
   * failure; any other value is delivered to the source as `response`.
   */
  onDrop?(e: DragTargetEvent): Promise<unknown> | unknown;
}

export interface DragTargetHandle {
  /**
   * Report whether the cursor is inside this target's drop zone. Drives the
   * native badge: hidden while a zone is active (the target's own preview
   * represents the drag), revert-styled otherwise.
   */
  setZoneActive(active: boolean): void;
  unregister(): void;
}

/** See {@link Pbjs.drag}. One instance per window, owned by the Pbjs singleton. */
export class PbjsDragService {
  private readonly bridge: Pbjs;
  private wired = false;
  private wiring?: Promise<void>;
  private activeSession: DragSessionImpl | null = null;
  private targets = new Set<DragTargetRegistration>();
  /** Cached dnd:enter event of the incoming drag (this window as target). */
  private incoming: DragTargetEvent | null = null;

  constructor(bridge: Pbjs) {
    this.bridge = bridge;
  }

  /**
   * True when the host's DndService is actually running — false on a host
   * without it, PBJS_DND=0, non-macOS, or browser-hosted. `dndAvailable` is
   * injected by the native host at page load (see PrepateBridgeScript in
   * pbjsBridge.pb); the function-existence check is a fallback for a bridge
   * script old enough to predate that flag (the wrapper functions themselves
   * are bound regardless of whether the service is enabled, so checking only
   * their existence would report true even when disabled).
   */
  get available(): boolean {
    if (typeof window.pbjs?.dndAvailable === "boolean") {
      return window.pbjs.dndAvailable;
    }
    return typeof window.pbjs?.dndStart === "function";
  }

  // ── source side ──

  async start(spec: DragStartSpec): Promise<DragSession> {
    await this.bridge.waitForReady();
    if (!this.available) throw new Error("pbjs.drag unavailable");
    await this.ensureWired();
    const raw = await window.pbjs.dndStart!({
      type: spec.type,
      payloadJson: JSON.stringify(spec.payload ?? {}),
      badge: spec.badge ?? {},
    });
    if (!raw?.sessionId) {
      throw new Error(raw?.error || "dnd start failed");
    }
    const session = new DragSessionImpl(raw.sessionId, this);
    this.activeSession = session;
    console.log(`[DIAG][DND] session started ${raw.sessionId}`);
    return session;
  }

  // ── target side ──

  registerTarget(reg: DragTargetRegistration): DragTargetHandle {
    this.targets.add(reg);
    void this.syncTargets();
    return {
      setZoneActive: (active: boolean) => {
        const id = this.incoming?.sessionId;
        if (id) void window.pbjs?.dndSetZoneActive?.(id, active);
      },
      unregister: () => {
        this.targets.delete(reg);
        void this.syncTargets();
      },
    };
  }

  // ── internals ──

  /** Session teardown callback (from DragSessionImpl). */
  sessionEnded(s: DragSessionImpl): void {
    if (this.activeSession === s) this.activeSession = null;
  }

  private async syncTargets(): Promise<void> {
    await this.bridge.waitForReady();
    if (!this.available) return;
    await this.ensureWired();
    const types = [...new Set([...this.targets].flatMap((t) => t.types))];
    if (types.length > 0) {
      await window.pbjs.dndRegisterTarget!(types).catch(() => {});
    } else {
      await window.pbjs.dndUnregisterTarget!().catch(() => {});
    }
  }

  private regFor(type: string): DragTargetRegistration | undefined {
    for (const t of this.targets) {
      if (t.types.includes(type)) return t;
    }
    return undefined;
  }

  private ensureWired(): Promise<void> {
    if (this.wired) return Promise.resolve();
    if (this.wiring) return this.wiring;
    this.wiring = this.bridge.waitForReady().then(() => {
      if (this.wired) return;
      this.wired = true;

      // Source-side events.
      this.bridge.handle<DndStateFrame>("system", "dnd:state", (_e, params) => {
        const s = this.activeSession;
        if (!s || !params || params.sessionId !== s.id) return;
        s.pushState(
          params.over === "target"
            ? { over: "target", window: params.window ?? "" }
            : { over: params.over === "source" ? "source" : "none" },
        );
      });
      this.bridge.handle<DndDropResultFrame>("system", "dnd:dropResult", (_e, params) => {
        const s = this.activeSession;
        if (!s || !params || params.sessionId !== s.id) return;
        s.resolveDrop(params.result ?? { accepted: false, reason: "cancelled" });
      });
      this.bridge.handle<DndSessionFrame>("system", "dnd:cancelled", (_e, params) => {
        const s = this.activeSession;
        if (!s || !params || params.sessionId !== s.id) return;
        s.resolveDrop({ accepted: false, reason: "cancelled" });
      });

      // Target-side events.
      this.bridge.handle<DragTargetEvent>("system", "dnd:enter", (_e, params) => {
        if (!params?.sessionId) return;
        this.incoming = params;
        this.regFor(params.type)?.onEnter?.(this.incoming);
      });
      this.bridge.handle<DndPointerFrame>("system", "dnd:over", (_e, params) => {
        const base = this.incoming;
        if (!base || !params || params.sessionId !== base.sessionId) return;
        const merged = { ...base, x: params.x, y: params.y, screenX: params.screenX, screenY: params.screenY };
        this.incoming = merged;
        this.regFor(merged.type)?.onOver?.(merged);
      });
      this.bridge.handle<DndSessionFrame>("system", "dnd:leave", (_e, params) => {
        const base = this.incoming;
        if (!base || !params || params.sessionId !== base.sessionId) return;
        this.incoming = null;
        this.regFor(base.type)?.onLeave?.();
      });
      // Drop request — the return value travels back as the native's reply.
      this.bridge.handle<DragTargetEvent>("system", "dnd:drop", async (_e, params) => {
        this.incoming = null;
        const reg = params?.type ? this.regFor(params.type) : undefined;
        if (!params || !reg?.onDrop) return { reject: true };
        try {
          const r = await reg.onDrop(params);
          return r ?? {};
        } catch (err) {
          console.error("[DIAG][DND] onDrop handler threw:", err);
          return { reject: true };
        }
      });
    });
    return this.wiring;
  }
}

class DragSessionImpl implements DragSession {
  readonly id: string;
  private readonly service: PbjsDragService;
  private stateCbs = new Set<(s: DragOverState) => void>();
  private dropResolve: ((r: DropResult) => void) | null = null;
  private ended = false;

  constructor(id: string, service: PbjsDragService) {
    this.id = id;
    this.service = service;
  }

  onStateChange(cb: (s: DragOverState) => void): () => void {
    this.stateCbs.add(cb);
    return () => this.stateCbs.delete(cb);
  }

  updateBadge(patch: DragBadgeSpec): void {
    if (this.ended) return;
    void window.pbjs?.dndUpdateBadge?.(this.id, patch);
  }

  async drop(): Promise<DropResult> {
    if (this.ended) return { accepted: false, reason: "cancelled" };
    const resultP = new Promise<DropResult>((res) => {
      this.dropResolve = res;
    });
    const ack = await window.pbjs!.dndDrop!(this.id).catch(() => null);
    if (!ack || ack.error) {
      this.finish();
      return { accepted: false, reason: "cancelled" };
    }
    // The native side already times the target reply out at ~2s; this outer
    // guard only covers a lost dropResult message.
    const timeout = setTimeout(
      () => this.resolveDrop({ accepted: false, reason: "timeout" }),
      4000,
    );
    const result = await resultP;
    clearTimeout(timeout);
    this.finish();
    console.log(`[DIAG][DND] drop resolved`, result);
    return result;
  }

  async cancel(): Promise<void> {
    if (this.ended) return;
    this.finish();
    await window.pbjs?.dndCancel?.(this.id)?.catch(() => {});
  }

  /** Router entry: over-state change from native. */
  pushState(s: DragOverState): void {
    if (this.ended) return;
    this.stateCbs.forEach((cb) => {
      try {
        cb(s);
      } catch (e) {
        console.error("[DIAG][DND] state callback error", e);
      }
    });
  }

  /** Router entry: final result (dropResult / cancelled). */
  resolveDrop(r: DropResult): void {
    const res = this.dropResolve;
    this.dropResolve = null;
    if (res) {
      res(r);
    } else {
      // Cancelled/resolved without a pending drop() — just end the session.
      this.finish();
    }
  }

  private finish(): void {
    if (this.ended) return;
    this.ended = true;
    this.stateCbs.clear();
    this.service.sessionEnded(this);
  }
}

export const pbjs = new Pbjs();
