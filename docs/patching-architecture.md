# Patching Architecture

This document describes the patching approach used in `claude-cowork-nix` to make Claude Desktop run on Linux with Cowork support.

## Approach

A **hybrid** strategy combining inline `perl -pe` regex substitutions with a dynamic Node.js script:

- **9 regex patches** (02, 03, 04, 06a, 06b, 08a, 08b, 09, 11, 12) use `perl -pe` with `\w+` wildcards for minified identifiers, applied directly in the Nix build phase
- **1 dynamic patch** (05) uses a Node.js script that discovers the VM start function by its `[VM:start]` log string, then injects the Linux session block
- **2 file-based patches** (00, 01, 07) append or copy standalone JavaScript files
- Each regex patch is verified with a `grep -qP` post-check that fails the build on mismatch

This approach has survived across v1.1.2685, v1.1.3770, v1.1348.0, v1.1617.0, and v1.2278.0 (including a major versioning scheme change) without requiring patch rewrites for most patches. The v1.2278.0 bump needed one narrow fix: patch 03's function-name capture widened from `\w+` to `[\w\$]+` because Anthropic's minifier produced `J$n` (with a literal `$`) for the target function.

## Why Regex Works

Claude Desktop ships as minified Electron JavaScript. Each release renames identifiers (`Li` → `Ci`, `vz()` → `fz()`), but the **code structure** is stable:

```perl
# The structure process.platform==="darwin",WORD=process.platform==="win32" is stable
# Only the variable name (WORD) changes — \w+ matches any name
perl -pe 's{(\w+=process\.platform==="darwin",)(\w+)(=process\.platform==="win32")}{...}'
```

The key insight: each function has a **stable semantic signature** (string literals, API calls, structure) that survives minification. Only the names change.

## Identifier Discovery Patterns

When a version bump breaks a patch, these grep patterns find the new targets:

```bash
INDEX=extracted/.vite/build/index.js

# Patch 02: Platform flag
grep -oP '.{0,60}process\.platform==="darwin",.{0,4}=process\.platform==="win32".{0,20}' $INDEX

# Patch 03: Availability check
grep -oP 'function \w+\(\)\{const t=process\.platform;if\(t!=="darwin"&&t!=="win32"\)return\{status:"unsupported"' $INDEX

# Patch 05: VM start (4-param async with [VM:start] log)
grep -oP 'async function \w+\(\w,\w,\w,\w\)\{var .{0,80}\[VM:start\]' $INDEX

# Patch 06a: VM getter
grep -oP 'async function \w+\(\)\{const t=await \w+\(\);return\(t==null\?void 0:t\.vm\)\?\?null\}' $INDEX

# Patch 08b: Tray icon filename
grep -oP '\w+\?\w+=\w+\.nativeTheme\.shouldUseDarkColors\?"Tray-Win32-Dark\.ico":"Tray-Win32\.ico":\w+="TrayIconTemplate\.png"' $INDEX

# Patch 11: shellPathWorker base
grep -oP 'function \w+\(\)\{return \w+\.join\(process\.resourcesPath,"app\.asar",".vite","build","shell-path-worker","shellPathWorker\.js"\)\}' $INDEX

# Patch 12: [1m] model-suffix feature flag function
grep -oP 'function \w+\(t\)\{return/\[1m\]/i\.test\(t\)\|\|!\w+\("3885610113"\)\|\|!/sonnet-4-6\|opus-4-6/i\.test\(t\)\?t:`\$\{t\}\[1m\]`\}' $INDEX
```

## Patch 12: The `[1m]` suffix and Code/LOCAL mode

Independent of patches 02–09 (which route Linux through Cowork's VM path), patch 12 enables the Code section's **LOCAL** sub-mode. LOCAL was previously documented as broken; the actual blocker is a client-side GrowthBook feature flag (`3885610113`) that appends `[1m]` to Opus-4.6 / Sonnet-4.6 model ids at session-start time. Anthropic's `/api/.../model_configs/<id>[1m]` endpoint 404s, which cascades into an `undefined.includes()` crash in the renderer and disables the send button.

The suffix function has a very specific signature — three `||`-separated conditions with a literal GrowthBook flag id — that the patch-12 regex matches precisely:

```javascript
// Before patch:
function zxt(t) {
  return /\[1m\]/i.test(t) || !rn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t
    : `${t}[1m]`;
}

// After patch:
function zxt(t) { return t }
```

Both call sites (`model: zxt(r.model || "default")` at session start, and `const i = zxt(r)` in `setModel`) are preserved; only the function body is neutralized.

## CCD's `CLAUDE_CODE_LOCAL_BINARY` escape hatch (patches 13 + 14)

Patch 12 alone isn't sufficient for LOCAL mode — the CCD daemon also throws `Unsupported platform: linux-x64` from `getHostPlatform` when preparing to download its own binary. Anthropic originally provided an undocumented escape hatch: setting `process.env.CLAUDE_CODE_LOCAL_BINARY` to a valid executable path caused the CCD constructor to short-circuit *every* entry point (`getStatus`, `prepare`, `getBinaryPathIfReady`, `prepareForVM`) **before** `getHostPlatform` is reached. The module options `programs.claude-desktop.claudeCodePackage` (NixOS + Home Manager) wire this via `makeWrapper --set-default`, so the user's external `CLAUDE_CODE_LOCAL_BINARY` (if any) still wins.

**Two regressions in v1.6608.2 broke this** and forced two new ASAR patches:

1. **Constructor bridge degraded to a dead expression.** v1.3883's constructor ended with `r=process.env.CLAUDE_CODE_LOCAL_BINARY; r && (this.localBinaryInitPromise = this.initLocalBinary(r))`. v1.6608.2 minified that down to a bare `process.env.CLAUDE_CODE_LOCAL_BINARY` standalone expression (no assignment, no call), so `localBinaryPath` stays `null` regardless of env-var contents and every CCD entry point falls through to `getHostTarget()` → `getHostPlatform()` → throw. **Patch 14** restores the original wiring.

2. **New chat-send call sites await `Ta.prepare()`.** v1.6608.2 added code paths around offsets 10478043 (`const De=await Ta.prepare(); be=(De.ready?De.path:null)??await Ta.getBinaryPathIfReady()`) and 11476159 (`const i=await Ta.getBinaryPathIfReady(); if(!i)throw...`) that propagate the synchronous `getHostPlatform` throw into the chat UI. This surfaces in **Cowork** even when `claudeCodePackage` is unset, because Cowork's send pipeline now opportunistically probes for a host claude-code binary. **Patch 13** is the defensive fix: instead of throwing, `getHostPlatform()` returns the appropriate `linux-x64` / `linux-arm64` string. `getHostTarget()` then resolves cleanly, `binaryExistsForTarget` returns false (no binary on disk), and callers handle the null fallback gracefully.

Together, patch 13 keeps Cowork (and any non-LOCAL feature that incidentally probes CCD) functional with no env var; patch 14 reactivates the LOCAL escape hatch for users who opt in via `claudeCodePackage`.

## Linux deep-link delivery (patch 22)

Fixes issues #52 and #57. Ported from PR #53 (thanks @stuckj) — renumbered from that
PR's "20", which was taken by the Swift notification loader in the meantime, and
re-anchored because the flake has since moved from a single `$INDEX` to anchor-based
discovery.

Through v1.9255.2 the main process branched on platform when wiring up deep links:

```javascript
isMac ? (app.on("open-url", …), app.on("continue-activity", …))
      : app.requestSingleInstanceLock()
          ? app.on("second-instance", (e, argv) => { focus(); dispatch(argv) })
          : app.quit();
```

**v1.24012.9 dropped the non-darwin arm.** It now registers `open-url`,
`will-continue-activity` and `continue-activity` unconditionally — and all three are
macOS-only Electron events. `requestSingleInstanceLock` and `second-instance` are absent
from the entire extracted tree, and there is no cold-start argv scan for the scheme.

On Linux the consequences are:

1. No single-instance lock, so every `claude-desktop claude://…` invocation (i.e. every
   `xdg-open` of the scheme handler) starts a second full app against one
   `--user-data-dir`.
2. The URL sits unread in that process's argv, and is silently dropped.

This breaks OAuth sign-in outright. The app hands off to the system browser — its
in-process path, `ASWebAuthenticationSession`, is macOS-only — and the `claude://login/…`
callback never gets back in. The user sees a new window still showing the login screen,
with no way to ever complete sign-in. Both reporters independently confirmed the OS-level
routing works (`xdg-open 'claude://test'` does reach the app), which is what makes this
look like an OAuth-parameter bug rather than a delivery bug.

`scripts/linux-deep-link.js` restores the missing arm. It deliberately does **not**
reimplement dispatch — the app's own `open-url` listener already owns mainView readiness,
the pending-URL stash for pre-ready arrivals, and window focus — so the patch just
re-emits that event:

```javascript
app.emit("open-url", { preventDefault() {} }, url);
```

Keeping the app as the single owner of URL handling is what makes this cheap to carry
across version bumps: the only structural assumption is that an `app.on("open-url")`
listener exists, which the build-time assertion pins.

### Details worth preserving if this is ever rewritten

- **`app.exit(0)`, not `app.quit()`, for the losing instance.** The script is appended to
  the end of `index.js`, so by then the app has registered its `before-quit`/`onQuitCleanup`
  handlers, and `app.quit()` runs all of them — including `flush-web-storage` and
  `plan-usage-history`, which write into the `--user-data-dir` the *primary* owns. A
  process that should never have started must not touch shared state on its way out.
- **The handoff is already done when the lock call returns.** Chromium's `ProcessSingleton`
  notifies the primary and waits for the ack inside `requestSingleInstanceLock()`, so
  exiting immediately afterwards loses nothing.
- **The listener assertion must accept a backtick.** This build minifies every string
  literal to a template literal, so the source reads ``app.on(`open-url`, …)``. PR #53's
  assertion grepped for `app.on("open-url"` only and would have failed the build on
  v1.34493.1 despite the listener being present.
- **Append to `index.js`, not to whichever chunk holds the listener.** `index.js` is the
  entry that requires every chunk, so appending there runs after the app's own listeners
  exist but before `ready` — the only window in which `requestSingleInstanceLock()` is
  still useful. Patch 01 appends to the same file for the same reason. Keying the append
  to the chunk that happens to hold `open-url` would re-introduce exactly the
  filename-coupling the anchor-based scheme exists to avoid.

The second build assertion (`requestSingleInstanceLock` must be *absent* before appending)
is a tripwire: if a future release restores the arm itself, the build fails loudly rather
than installing two competing single-instance handlers.

### Testing

`tests/deep-link` drives two real Electron processes against the actual script. This
cannot be covered by a headless launch: nothing crashes and no Sentry event fires, the
damage is that a *second process starts*. See that directory's README, including the
`CDT_SCRIPT_OVERRIDE` negative control — with the patch removed, three of its four
assertions must fail.

## Wrapped-Electron Path Resolution Gotcha

In a Nix build that wraps a stock Electron with `makeWrapper` and passes `app.asar` as a positional argument:

```
electron /nix/store/<hash>-claude-desktop-<ver>/lib/claude-desktop/app.asar
```

…`process.resourcesPath` resolves to the **Electron runtime's** resources directory (`/nix/store/<hash>-electron-unwrapped-<ver>/.../resources`), NOT the directory containing Claude's app.asar. Anthropic's code assumes a normal "Electron app" layout where `process.resourcesPath` IS the directory containing app.asar (the macOS/Windows install pattern).

When a patch needs to resolve a file inside Claude's app.asar at runtime, use one of:

1. `process.argv[1]` — the asar path passed by `makeWrapper`. Pass it directly to `path.join(...)` to address files inside the archive (Electron's `fs` patches make `app.asar` behave as both a file AND a directory containing its archived contents). Used by patch 11.
2. `app.getAppPath()` — the Electron-internal "app path" API, which on a wrapped build returns the asar path. Used by patch 08a.

Either works; pick whichever matches the existing code's idiom around the patch site to minimize regex churn.

**Subtle gotcha**: don't `path.dirname(process.argv[1])` thinking you need a "real" directory before `path.join`-ing — that strips off `app.asar` and leaves you pointing at the directory *next to* the archive, where the file doesn't exist on disk. The asar path itself is the right base.

## Version Update Workflow

1. Get new DMG URL from `https://claude.ai/download`
2. Update `claudeVersion`, `claudeDmgUrl`, `claudeDmgHash` in `flake.nix`
3. `nix build .` — if it succeeds, all patches are still valid
4. If a patch fails, the `grep -qP` check identifies which one — use the discovery patterns above to find the new code structure
