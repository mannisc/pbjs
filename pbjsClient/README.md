# `pbjsClient` — the typed client

`window.pbjs` is the bridge: a flat, untyped surface installed by
`pbjsBridgeScript.js` and the PureBasic host. This directory is the **client** —
an optional TypeScript layer over it that adds the conveniences every multi-window
app ends up writing anyway.

```ts
import { pbjs } from "../pbjsClient/pbjsClient";

await pbjs.waitForReady();
const reply = await pbjs.invoke("main-window", "getStatus", {}, { id });
pbjs.handleAll("updateItem", (event, params, data) => ({ ok: true }));
const ch = pbjs.channel("items");
```

| File | What |
|---|---|
| `pbjsClient.ts` | the `Pbjs` class, the `pbjs` singleton, and `PbjsDragService` |
| `pbjs.d.ts` | ambient declarations for the **bridge** (`window.pbjs`, `window.fs`, the `pbjsNative*` verbs) |

## Bridge vs client — keep them apart

The distinction is easy to lose and the docs have lost it before (README
Deviations §10):

| Bridge (`window.pbjs`) | Client (`pbjs`) |
|---|---|
| `dndStart`, `dndRegisterTarget`, `dndAvailable` | `drag.start`, `drag.registerTarget`, `drag.available` |
| `invoke` → `{ success: value }` | `invoke` → the bare value |
| — | `channel`, `waitForReady`, `waitForFSReady`, `isReady` |
| `pbjsNativeSetWindowTitle`, `pbjsNativeFocusWindow`, … | `setWindowTitle`, `focusWindow`, `setWindowState`, `getWindowMetrics`, `startWindowDrag` |

That last row is why this exists: those natives were bound in `JSWindow.pb` with
**no JS caller at all** until the client shipped.

## It is a library — it names no app

`pbjsClient.ts` has **zero imports** and mentions no host application. Everything
app-specific is handed in:

```ts
pbjs.configureHost({
  isBrowserHosted: () => !!window.__myAppWebAdapter,
  onInstanceOpened: ({ templateName, instanceName, params }) => {
    // your app knows how one of its own tabs is reached; this layer does not
  },
});
```

`ci/check-sources.mjs` enforces this — a host-app name appearing in `pbjsClient/`
fails `ci/pre-push`. It is the TypeScript twin of the `UseModule Ptym` check that
file was written for.

## ⚠ It is vendored into the host app

pbjs is developed as a git-ignored nested repo inside its host app, whose CI does
a plain checkout that does not contain pbjs — so the host **cannot** import from
here. It keeps a tracked copy instead, and the two must stay byte-identical.

**This repo is canonical. Edit here, then copy out.** Both files keep the same
names on both sides and must match byte for byte, so the check is a plain diff:
`ci/pre-push` refuses a push that has let them part company, and skips when the
parent checkout is absent so pbjs stays pushable on its own.
