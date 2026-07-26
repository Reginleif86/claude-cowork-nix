# claude-cowork-nix

Enabling macOS-only Claude Desktop features on Linux via runtime patching.

## Architecture

- **Source**: macOS DMG fetched via `fetchurl` (currently v1.24012.9 — tracked by github-actions auto-update)
- **Extraction**: `7zz` (native LZFSE support) + `asar_tool.py`
- **Runtime**: `electron_41` from nixpkgs
- **Packaging**: Nix flake with `makeWrapper` + `buildFHSEnv`

### Where the patches land

As of v1.20186.1 the Electron main process is **code-split**, so the file the `perl`
patches rewrite is no longer `index.js`:

```
package.json main -> .vite/build/index.pre.js   (Sentry bootstrap + launch-failure dialog)
  -> require("./index.js")                      (~800-byte stub)
    -> require("./index.chunk-<hash>.js")       (5.3 MB — the app code formerly in index.js)
```

Every regex patch target lives in that one chunk. The hash is content-derived and
changes each release, so the build **discovers** it from index.js's `require()`
(`$INDEX` in `flake.nix`) and falls back to `index.js` for older monolithic builds. If a
bump makes every regex patch fail at once, check this resolution first — it means the
layout moved again, not that the regexes rotted.

v1.24012.9 splits the *rest* of the app into ~95 sibling `index.chunk-*.js` files, but
`index.js` still requires exactly one entry chunk and that chunk still holds every patch
target, so the discovery logic is unchanged. Don't assume "many chunks" means the patch
targets scattered — grep before re-deriving anything.

**Not everything lives in the main chunk.** Patch 19 targets a helper duplicated into
`shell-path-worker/shellPathWorker.js` and `file-index-worker/fileIndexWorker.js` as
well, and those copies are *pretty-printed* rather than minified. When a patch has to
cover both, match in `perl -0777` slurp mode with whitespace-flexible regexes (see patch
19) rather than writing two patches.

v1.24012.9 also moves the PTY into its own utility process
(`.vite/build/pty-host/ptyHostWorker.js`, forked via `getViteWorkerPath`). That resolver
branches on `app.isPackaged` and falls back to `app.getAppPath()`, which is correct under
our `makeWrapper` setup (`isPackaged` is false because the exec basename is `electron`),
so it needs no patch — unlike the `shellPathWorker` resolver that patch 11 fixes, which
hardcodes `process.resourcesPath` with no such branch.

## Key Commands

```bash
# Build
nix build .                     # Default (FHS wrapper with Cowork + MCP)
nix build .#claude-app          # Just the patched app.asar

# Run
nix run .

# Validate
nix flake check

# Dev shell
nix develop
```

## Patching Workflow

Patches use `perl -pe` regex with `\w+` (or `[\w\$]+` where minified names contain `$`) wildcards for minified identifiers, so version bumps should not require patch changes.

1. **Fetch DMG URL**: Get from `https://claude.ai/download` (inspect download link in browser)
2. **Update hash**: `nix-prefetch-url <url>` then `nix hash convert --hash-algo sha256 --to sri <hash>`
3. **Update version/hash/URL** in `flake.nix`
4. **Build**: `nix build .` — if it succeeds, patches are still valid
5. **If build fails**: Check the `grep -qP` verification errors to see which regex needs updating

See `docs/patching-architecture.md` for the full technical analysis.

## Patch Chain

| # | Method | Purpose |
|---|--------|---------|
| 00 | File copy | Electron API stubs for Linux (`@ant/claude-native`). **Also implements the safe-fs containment API** (`openRootDir`, `openBeneath`, `mkdirBeneath`, `renameBeneath`, `unlinkBeneath`) that v1.20186.1 requires — the app refuses to fall back to path-based opens without it ("required for safe-fs containment", CC-2885) and throws `UnsafeRootError` at startup. Native uses `openat2(RESOLVE_BENEATH)`; the stub emulates the guarantee by rejecting `..`/separator/NUL segments and requiring the deepest existing ancestor to `realpath` beneath the root (symlink escape ⇒ `ELOOP`, which callers already treat as unsafe). `openBeneath` returns a **raw fd** (callers `fs.fstat`/`fs.close` it), and `mkdirBeneath` is **non-recursive** and must throw `EEXIST` — the app emulates recursion by walking each path prefix. |
| 01 | Append IIFE | Load Cowork module |
| 02 | _retired (v1.13576.4)_ | Was: route Linux through TS VM path via the `_o=…==="win32"` boolean. That boolean pair was inlined away; VM selection is gone (always `@ant/claude-swift`, substituted by patch 06) and availability moved to patch 03. No flag remains to flip. |
| 03 | `perl -pe` regex | Return "supported" for Linux availability — injects into the unified availability fn (codename "yukonSilver", e.g. `Hce`). Subsumes old patch 02's availability role. |
| 04 | `perl -pe` regex | Skip macOS VM bundle download |
| 05 | Node.js dynamic | Create Linux session at VM start (spawn, writeStdin, mounts, path translation) |
| 06 | `perl -pe` regex | Return Linux VM instance from getters |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" in **app chrome only**. Cosmetic, and deliberately narrow: the original observed `document.body` with `characterData:true`, so it also rewrote text the user typed and text the model streamed — typing "for Windows" in the composer mutated it mid-keystroke, and streamed responses were silently altered (issue #40). `scripts/branding-fix.js` now observes `childList` only (streamed/typed text arrives as `characterData`, so it is structurally unreachable), prunes content subtrees (`[contenteditable]`, `textarea`, `code`/`pre`, `[role=log/textbox]`, message/composer/conversation testids, `.font-claude-response`), and ignores text over 120 chars since platform labels are button-length. Trade-off: a chrome label re-textured in place after first render is no longer caught. **Covered by `tests/branding-fix.test.js`** (`node tests/branding-fix.test.js`) — if you widen the observer, that test is what catches the regression. |
| 08 | `perl -pe` regex | Tray icon. 08a resolves the resource path to the real filesystem (COSMIC's SNI can't read from an ASAR). 08b picks the filename: v1.20186.1 added a `case"png"` branch with real `TrayIconLinux{,-Dark}.png` assets + a GNOME check, but the icon-type const is baked to `"template-image"` in the macOS build, so 08b routes the template case to upstream's own Linux expression. **08a/08b are coupled to the installPhase icon copy** — it globs `TrayIcon*.png` (not just `TrayIconTemplate*`), since a tray image that is merely missing renders blank with no error. Asserted at build time. |
| 09 | `perl -pe` regex | DBus tray cleanup delay for stability |
| 11 | `perl -pe` regex | Resolve `shellPathWorker.js` from Claude's asar (not Electron runtime's) |
| 12 | _retired (v1.20186.1)_ | Was: neutralize the two chained `[1m]` model-suffixers whose suffixed id 404s `model_configs` and disabled the Code/LOCAL send button. Upstream no longer force-appends the suffix; `[1m]` survives only in the model *catalog* builders, which expand a 1M-capable model into two selectable entries (`[id, id[1m]]`, `supports_1m_context:!0`) — opt-in, and what the patch always left intact. Patch now asserts no forced suffixer returns. |
| 13 | _retired (v1.13576.4)_ | `getHostPlatform()` now ships a native `linux-x64`/`linux-arm64` branch upstream; patch asserts the branch is present instead of injecting it. |
| 14 | `perl -pe` regex | Restore constructor's `CLAUDE_CODE_LOCAL_BINARY` → `initLocalBinary` wiring (minified into a dead expression in v1.6608.2) |
| 15 | _retired (v1.13576.4)_ | Was: guard `files[process.platform][arch]` throwing `undefined['x64']` on Linux. v1.20186.1 makes **Linux a first-class VM platform key** — a mapper folds both unices into one bucket (`case"darwin":case"linux":return"unix"`) and the manifest ships `files.unix.{x64,arm64}` (a `rootfs.img`), plus a `downloads.claude.ai/vms/linux/<arch>/<sha>` URL builder. The crash is now structurally impossible; patch asserts the linux→unix mapping and the null-platform guard survive. (We still skip the download via patch 04 — see COWORK_PROGRESS.md for the native-Linux-VM opportunity this opens.) |
| 16 | `perl -pe` regex | Guard macOS-fork-only Electron **startup** APIs absent in stock `electron_41` — `systemPreferences.setUserDefault(…)` (darwin-guard) and `app.configureWebAuthn(…)` (existence-guard). Without these the app throws `… is not a function` at module load, before any window opens. |
| 17 | `perl -pe` regex | Guard macOS-only BrowserWindow chrome APIs (`setWindowButtonPosition`, `setHiddenInMissionControl`) via existence checks — these fire during window setup (async), surfacing as unhandled rejections + Sentry spam rather than blocking launch. |
| 18 | staged file + `--unpacked` header entry + installPhase overlay | Linux-native `node-pty`. The DMG ships only macOS Mach-O addons, so the in-app terminal/shell PTY fails to load (`Cannot find module .../pty.node`). node-pty 1.2.x moved to a **prebuildify layout** (`prebuilds/darwin-{x64,arm64}/`), so there is no `build/Release` to overlay. 18a stages the `nodePtyElectron` binary at `extracted/node_modules/node-pty/build/Release/pty.node` and the repack passes `--unpacked node_modules/node-pty/build/Release/pty.node`; 18b drops the same binary into the matching `app.asar.unpacked` path, asserts it is an ELF, **and asserts the packed ASAR header records it as `unpacked` with a matching size**. ⚠️ **An empty `build/Release` directory in the header is not enough** — that was the earlier approach and it silently never worked. Electron redirects a read into `app.asar.unpacked` only when the header holds the *file* entry with `"unpacked": true`; with just `"Release":{}` the require falls through every candidate and throws `Cannot find module './prebuilds/linux-x64/pty.node'` at runtime, with no build-time symptom. `tools/asar_tool.py pack` gained `--unpacked <relpath>` for this (it hard-fails if the path is absent, so a layout change can't drop the entry silently). Verify with `tests/pty-roundtrip`. `build/Release` is **first** in node-pty's search order (`lib/utils.js:loadNativeModule`) and arch-agnostic, so it wins over the darwin prebuilds with no linux-x64/arm64 split. `spawn-helper` is macOS-only (`pty.cc` execs it under `__APPLE__`), left untouched. **`nodePtyElectron.version` must track the node-pty the DMG bundles** — N-API keeps the ABI stable but not node-pty's own JS↔native API, so a mismatched `pty.node` loads fine and then throws on a method the JS expects. This drifted silently in the v1.24012.9 bump (DMG moved to `1.2.0-beta.14`, flake still built `beta.13`), so 18a now **asserts** the extracted `node_modules/node-pty/package.json` version equals the top-level `nodePtyVersion`. On a bump, read the version out of the new DMG and update `nodePtyVersion` + the tarball hash together. |
| 19 | `perl -0777` regex | Bypass the macOS **"disclaimer" spawn helper**. v1.24012.9 routes *every* `spawnAsync` through `<Contents>/Helpers/disclaimer` (macOS calls `responsibility_spawnattrs_setdisclaim` so children aren't attributed to Claude for TCC). The wrapper has **no platform guard** — `getDisclaimerBinaryPath` still carries the vestigial bare `{...}` block where a dead-code-eliminated `if(process.platform==="darwin")` used to be. The helper ships only inside the `.app`, so on Linux every spawn ENOENTs. Visible damage: login-shell env extraction retries 5× then falls back to bare `process.env`, so the user's PATH and exported vars (direnv, nvm, `.zshrc`) never reach Claude Code, MCP servers, or the terminal — a silent degradation, not a crash. Patch makes the wrapper a pass-through on non-darwin. Verify by grepping a launch log for `[CCD] Resolved N login-shell env vars` (good) vs `Shell environment extraction failed` (broken). **Three call sites in two textual shapes** — minified in the main chunk, pretty-printed in `shellPathWorker.js` and `fileIndexWorker.js` — hence slurp mode; each target is `node --check`ed after rewrite since a malformed edit would only surface at runtime. |

> **Custom Electron fork:** Anthropic's macOS build runs a patched Electron with extra native `app`/`systemPreferences`/`BrowserWindow` methods. Stock nixpkgs `electron_41` lacks them, so each top-level call to one throws on Linux. Patches 16–17 guard the ones hit on the launch path; if a future version adds more, the symptom is `TypeError: X.<method> is not a function` at startup — add an existence/darwin guard following the same pattern.

> **`@ant/claude-native` keeps growing:** the same symptom (`TypeError: X.<method> is not a function`) also appears when the app starts calling a *new* method on the native module we stub. v1.20186.1 added the safe-fs containment API this way. When it happens, find the call site in the chunk, derive the contract from how the return value is consumed (e.g. `fs.close(x)` ⇒ raw fd, not a FileHandle), and implement it in `modules/enhanced-claude-native-stub.js` — don't just return a no-op, since the app may guard against exactly that.

## Electron Gotchas

- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **ASAR unpacked files are a header contract, not a filesystem one.** `extract` *skips* files marked `unpacked` and keeps only their directories, so a plain repack loses every such entry — the header ends up with `"Release":{}`, `"darwin-x64":{}` and so on. Anything that must be reachable at `<asar>/…` but live on the real filesystem (native addons) needs `pack --unpacked <relpath>`, which emits `{"size":N,"unpacked":true}`. The upstream darwin prebuild entries are still dropped by our repack; that is inert on Linux (node-pty only probes `prebuilds/linux-x64`), but don't assume any other unpacked file survives a round-trip.
- **App caching**: Kill all processes before testing — but **not** with a bare `pkill -f claude-desktop`: that pattern also matches the shell command running it, killing your own session. Match the binary path instead.
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Testing Gotchas

- **Never launch a test build against the real `~/.config/Claude`.** On startup the app "preseeds" a pinned `claude-code` build into `~/.config/Claude/claude-code/<version>/` (v1.24012.9 pins 2.1.219; v1.20186.1 pinned 2.1.205; v1.13576.4 pinned 2.1.177) and writes a `.verified` marker holding the *manifest's expected checksum* — not a hash of the file. A test launch therefore mutates real user state, and an app version expecting a different pin reports **"The Claude Code binary is missing or damaged."** Run headless tests with an isolated `HOME`, copying in `.config/Claude/claude-code` to skip the 257 MB download.
- **Headless launch**: `HOME=$tmp xvfb-run -a ./result/bin/claude-desktop`; surviving a `timeout` (exit 124) is the pass signal. Grep the log for `is not a function`, `Cannot find module`, `UnsafeRootError`.
- **Two harness traps produce a fake failure (exit 139 / SIGSEGV), not an app bug:**
  1. `XDG_RUNTIME_DIR` must be **short**. A unix socket path is capped at 108 bytes, and the Wayland socket lives under it — a deep scratchpad path makes Ozone abort with `socket path … exceeds 108 bytes` before any window opens. Use something like `/tmp/cdt-$$`.
  2. The wrapper passes `--ozone-platform-hint=auto`, so an inherited `WAYLAND_DISPLAY` makes it prefer the *host's* Wayland session over Xvfb's X server and then fail. Clear the session vars: `env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_SESSION_TYPE`.
- **Read the log even when the exit code is 124.** v1.24012.9's disclaimer regression (patch 19) never crashed anything — it logged a warning, retried, and silently degraded. A pass/fail exit code would have shipped it.
- Expected-and-benign in a headless log: `accountId=null, orgId=null` (not signed in), `[wake-scheduler] DEV BUILD` (macOS LaunchDaemon), `@ant/claude-swift unavailable` (macOS pressure telemetry), `[Bundle:status] rootfs.img missing` (patch 04 skips the download), and no tray lines at all (Xvfb has no StatusNotifier host).
- One `getInitialLocale … did not pass origin validation` at startup is **upstream**, not ours. The guard is `senderFrame?.parent === null` — pure frame topology, nothing to do with our paths — and it races frame commit. Do not "fix" it: it is a renderer-origin security check, and weakening it to quiet one log line is a bad trade.
- **A green `nix build` is not a working app.** Every regex patch self-verifies, so the build catches *missing* patches — it cannot catch a patch that applies cleanly and names a file that isn't installed (see 08a/08b ↔ icon copy), or a native addon that loads but exports nothing. Launch it.
- **A clean launch is not a working app either.** Subsystems that fail are frequently caught, logged, retried, and degraded — the window still opens. Both v1.24012.9 regressions behaved this way: the disclaimer bug logged a warning and fell back to a bare env, and the missing ASAR `unpacked` entry only threw when something actually opened a terminal. Exercise the feature:
  - `node tests/branding-fix.test.js` — patch 07 stays scoped to chrome (issue #40).
  - `tests/pty-roundtrip` — patch 18 addon resolves, spawns, resizes, exits (see its README).
  - Grep a launch log for `[CCD] Resolved N login-shell env vars`; `Shell environment extraction failed` means patch 19 regressed.

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
