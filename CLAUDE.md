# claude-cowork-nix

Enabling macOS-only Claude Desktop features on Linux via runtime patching.

## Architecture

- **Source**: macOS DMG fetched via `fetchurl` (currently v1.34493.1 — tracked by github-actions auto-update)
- **Extraction**: `7zz` (native LZFSE support) + `asar_tool.py`
- **Runtime**: `electron_41` from nixpkgs
- **Packaging**: Nix flake with `makeWrapper` + `buildFHSEnv`

### Where the patches land

**Never key a patch to a filename or a chunk count — upstream reshuffles both, in both
directions.** Three consecutive releases, three different shapes:

| Version | `index.js` | JS files | Where targets live |
|---|---|---|---|
| ≤ v1.24012.9 | ~800 B stub, 1 require | ~95 | all in the one entry chunk |
| v1.26832.0 | 242 KB, 159 requires | ~350 | scattered over 7+ files |
| v1.32352.0 | 625 B stub, 2 requires | 140 | nearly all in one 6 MB chunk |
| v1.34493.1 | 638 B stub, 2 requires | 148 | unchanged — one 6 MB chunk |

The old rule ("resolve the first require from index.js, patch that file") happened to
work for the first shape, broke completely on the second, and would work again on the
third. Do not restore it.

```
package.json main -> .vite/build/index.pre.js   (Sentry bootstrap + launch-failure dialog)
  -> require("./index.js")                      (a stub again in v1.32352.0)
    -> index{,2}.chunk-<hash>.js                (count and grouping change every release)
```

Patches are therefore keyed on **anchors, not filenames**. `apply_patch <label> <anchor>
<perl-expr> <verify>` in `flake.nix` greps the whole build tree for the anchor, rewrites
every file containing it, and fails the build if the anchor is missing *or* the rewrite
lands nowhere. Upstream re-chunking is then a no-op for us; only a genuine shape change
fails. v1.32352.0 is the proof this was worth doing: the entire bundle was re-chunked
(350 files down to 140, nearly everything consolidated into one) and **13 of 16 patches
kept applying with no edit at all**. Only the three whose target *code* genuinely changed
needed work. Two consequences to read correctly in the build log:

- **`applied in 1/2` is a pass.** An anchor may legitimately match files the
  substitution must skip — patch 08a's anchor also matches the `resources/i18n`
  resolver, and redirecting that one would break locale loading, since installPhase
  copies only `TrayIcon*`/`icon.png` next to the asar.
- **`applied in 2/2` is required** where a target is duplicated (patches 17a/17b/19).
  One unguarded call site is one unhandled rejection.

**The minifier changed shape in v1.26832.0, twice over.** Every string literal is now a
backtick template literal rather than double-quoted, and declarations are emitted as
`let` rather than `const`. That is why every regex in the chain writes ``[`"]`` for
string delimiters and `(?:const|let)` for declarations. Keep writing them as wildcards —
it costs nothing and survives a flip back. A bump where *all* the string-matching
patches fail together but patch 14 (the only one matching no string literal) still
applies is this exact class of change, not rot.

**Not everything is minified.** Patch 19's target is duplicated into
`file-index-worker/fileIndexWorker.js`, which is *pretty-printed*. When a patch must
cover both shapes, match in `perl -0777` slurp mode with whitespace-flexible regexes
(see patch 19) rather than writing two patches. Site counts drift — patch 19 covered
three files through v1.24012.9 and two in v1.26832.0 (the `shellPathWorker` copy is
gone), which is why the file list is discovered rather than hardcoded. In v1.32352.0 the worker copy is minified too, but keep the whitespace-flexible form — the shapes have alternated before.

**After patching, every build file is `node --check`ed.** A regex that mis-balances a
brace still greps clean and only fails when Electron requires it — at runtime, possibly
inside a subsystem that catches and degrades. A few seconds for the whole tree.

**`{}` is truthy — the defining Linux bug class of this release.**
`@ant/claude-swift` ends with:

```js
if (process.platform === "darwin") module.exports = new SwiftAddon();
else                               module.exports = {};
```

so on Linux `await import("@ant/claude-swift")` *succeeds* and every `if (swiftModule)`
check upstream passes with an empty object. Two subsystems engaged their macOS backend
this way and then threw on the first method call (patches 20 and 21). When auditing a
new version, grep for `import("@ant/claude-swift")` and check each consumer: a bare
truthiness test is a bug, `process.platform === "darwin"` or `!m?.someProperty` is fine.
Fix at the *loader* by returning null, not at the call site — null is what upstream's own
catch block returns, and it routes the caller onto the path Linux actually has.

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

Patches use `perl` regex with `\w+` (or `[\w\$]+` where minified names contain `$`) wildcards for minified identifiers, plus ``[`"]`` for string delimiters and `(?:const|let)` for declarations, so version bumps should not require patch changes.

**Resolve the latest version** the same way the auto-update workflow does — the Squirrel
manifest is not behind Cloudflare and gives you the URL directly:

```bash
curl -s https://downloads.claude.ai/releases/darwin/universal/RELEASES.json | jq -r \
  '.currentRelease, (.releases[0].updateTo.url | sub("\\.zip$";".dmg"))'
```

**Don't debug a version bump one `nix build` at a time.** Each build re-extracts a ~600 MB
DMG and stops at the *first* failing patch, so a release that shifts several patterns
costs an hour of serial rebuilds. Extract the new `app.asar` to a scratch dir once, then
dry-run every regex against a throwaway copy in a single pass to get the full damage
report up front:

```bash
7zz x -y -odmg "$DMG" && python3 tools/asar_tool.py extract <path>/app.asar extracted
# then, per patch: grep -rlP <anchor>, perl -0777 -pe <subst>, grep -qP <verify>
```

That is how v1.26832.0's two independent breakages (multi-chunk scatter, backtick
minification) were separated from each other in one pass instead of eighteen builds.

**A lazy window is not a scope.** Any regex of the form `<head> .{0,N}? <unique-anchor>`
can begin at one function and run forward into a *later* function's anchor, silently
selecting the wrong target with a completely green build. Patch 05 shipped that shape for
several releases and was saved only by an incidental arity filter; when v1.32352.0 changed
the arity, it selected `deleteVMBundle` instead of the VM start function. When the anchor
is a unique string, find the anchor first and walk **backwards** to the enclosing
construct — `lastIndexOf` guarantees nothing of that kind lies in between, which no
forward lazy match can promise. Reserve the forward form for cases where head and anchor
are genuinely adjacent.
A small `ctx.js`-style helper that prints regex matches with surrounding context, tagged
by file, is worth writing first — the bundle is far too large to read.

1. **Fetch DMG URL**: `RELEASES.json` as above, or `https://claude.ai/download`
2. **Update hash**: `nix-prefetch-url <url>` then `nix hash convert --hash-algo sha256 --to sri <hash>`
3. **Update version/hash/URL** in `flake.nix`
4. **Build**: `nix build .` — if it succeeds, patches are still valid
5. **If build fails**: Check the `grep -qP` verification errors to see which regex needs updating

See `docs/patching-architecture.md` for the full technical analysis.

## Patch Chain

| # | Method | Purpose |
|---|--------|---------|
| 00 | File copy | Electron API stubs for Linux (`@ant/claude-native`). **Also implements the safe-fs containment API** (`openRootDir`, `openBeneath`, `mkdirBeneath`, `renameBeneath`, `unlinkBeneath`) that v1.20186.1 requires — the app refuses to fall back to path-based opens without it ("required for safe-fs containment", CC-2885) and throws `UnsafeRootError` at startup. Native uses `openat2(RESOLVE_BENEATH)`; the stub emulates the guarantee by rejecting `..`/separator/NUL segments and requiring the deepest existing ancestor to `realpath` beneath the root (symlink escape ⇒ `ELOOP`, which callers already treat as unsafe). `openBeneath` returns a **raw fd** (callers `fs.fstat`/`fs.close` it), and `mkdirBeneath` is **non-recursive** and must throw `EEXIST` — the app emulates recursion by walking each path prefix. **v1.26832.0 adds the DeviceRegistry hardware key** (`hardwareKeyGetOrCreate`, `hardwareKeySign`); **v1.32352.0 adds `readProcessFootprints`** — see below. |
| 01 | Append IIFE | Load Cowork module |
| 02 | _retired (v1.13576.4)_ | Was: route Linux through TS VM path via the `_o=…==="win32"` boolean. That boolean pair was inlined away; VM selection is gone (always `@ant/claude-swift`, substituted by patch 06) and availability moved to patch 03. No flag remains to flip. |
| 03 | `perl -pe` regex | Return "supported" for Linux availability — injects a Linux early-return as the first statement of the unified availability fn (codename "yukonSilver"). Subsumes old patch 02's availability role. **Anchored on the `CLAUDE_E2E_ASSUME_VM_SUPPORTED` string literal, not on the function's shape.** v1.32352.0 restructured the body (the two consecutive early-return `if`s became one `if` plus a cached-value `return c||(…)`), which killed a purely structural anchor. That env-var literal is unique to this function and has outlived two refactors. **v1.34493.1 broke both halves of that claim.** The body restructured again (`return b||(…)` became `if(!t){if(t=…)}`), *and* the literal is no longer unique — it now also appears in a sibling one-liner that returns a **boolean** ("probe finished or assume supported"), where injecting a status object would be wrong. The regex is therefore both **tempered and discriminating**: `(?:(?!function).)*?` between head and anchor makes it structurally impossible for a match to start in one function and end in another's anchor (the patch-05 failure mode, in regex form rather than `lastIndexOf` form), and a required intervening `if(` selects the status-object function, since the boolean sibling has no `if` at all. Prefer widening that discriminator over re-pinning the body's shape. |
| 04 | `perl -pe` regex | Skip macOS VM bundle download. Anchored on the `{yukonSilver:…}` destructure in the two-parameter entry point — the only function shaped `async function X(a,b){…let{yukonSilver:c}=…}` that logs `[downloadVM]`. v1.34493.1 inserted an `await …();` between the opening brace and that destructure, which broke a head-adjacent anchor; the anchor now tolerates a run of leading `await ident();` statements. The three-parameter *warm prefetch* in another chunk destructures the same field and is deliberately **not** patched: it bails on its own when no VM bundle is present, which on Linux is always, since patch 04 is what stops the bundle ever arriving. |
| 05 | Node.js dynamic | Create Linux session at VM start (spawn, writeStdin, mounts, path translation). Takes no file argument — `patch-vm-start.js` finds its own target by scanning for the `[VM:start]` anchor. **Discovery walks *backwards* from the log call to the nearest preceding `async function`, and must stay that way.** The obvious forward regex (`async function X(params){decl [\s\S]{0,4000}?[VM:start]`) is actively dangerous: the lazy window lets a match *start* at one function and *run into* a later function's log line. In v1.32352.0 `deleteVMBundle` sits 3957 chars before the log call — inside a 4000-char window — so the forward form silently selected it, and Cowork session creation would have been injected into the bundle-**deletion** routine with a green build. Earlier releases escaped only by accident: the signature hardcoded four parameters and `deleteVMBundle` takes none. v1.32352.0 dropped the VM start fn to three params, removing that accidental filter. `lastIndexOf` guarantees no other `async function` lies between head and log line — the property the forward regex cannot provide. Parameter list is captured as raw text (arity is not stable); declaration keyword and a **dotted** status-dispatch enum (`Y(s.d.Ready)`) stay wildcards. |
| 06a | `perl -pe` regex | Return the Linux VM instance from the VM getters. **Two sites**: the async getter (`async function X(){return(await load())?.vm??null}`) and its synchronous sibling `X.getCached=function(){return CACHED?.vm??null}`. Both must agree — `getCached` is on a live path (`[VM:start]` reads it), and patching only the async one leaves callers seeing null with a running session, i.e. a silent "Cowork not running" rather than an error. v1.26832.0 rewrote both with optional chaining, so the old `(a==null?void 0:a.vm)` shape is gone. |
| 06b | _retired (v1.26832.0)_ | Was: widen the platform-gated `@ant/claude-swift` getter (exported `.K`) past its darwin check. That getter returns the **raw Swift module**, not our VM instance, and its three consumers either test `=== null` or call `.on(…)` on it — so it may only ever yield null or a real EventEmitter. On Linux the module is `{}`: truthy, no `.on`. Patch 21 makes the loader return null on non-darwin, so the widening is provably inert. Cowork loses nothing — the instance the app actually drives comes through 06a. Restore only if upstream ships a real Linux Swift addon. |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" in **app chrome only**. Cosmetic, and deliberately narrow: the original observed `document.body` with `characterData:true`, so it also rewrote text the user typed and text the model streamed — typing "for Windows" in the composer mutated it mid-keystroke, and streamed responses were silently altered (issue #40). `scripts/branding-fix.js` now observes `childList` only (streamed/typed text arrives as `characterData`, so it is structurally unreachable), prunes content subtrees (`[contenteditable]`, `textarea`, `code`/`pre`, `[role=log/textbox]`, message/composer/conversation testids, `.font-claude-response`), and ignores text over 120 chars since platform labels are button-length. Trade-off: a chrome label re-textured in place after first render is no longer caught. **Covered by `tests/branding-fix.test.js`** (`node tests/branding-fix.test.js`) — if you widen the observer, that test is what catches the regression. |
| 08 | `perl -pe` regex | Tray icon. 08a resolves the resource path to the real filesystem (COSMIC's SNI can't read from an ASAR). 08b picks the filename: v1.20186.1 added a `case"png"` branch with real `TrayIconLinux{,-Dark}.png` assets + a GNOME check, but the icon-type const is baked to `"template-image"` in the macOS build, so 08b routes the template case to upstream's own Linux expression. v1.32352.0 changed the switch from assign-then-`break` to **direct `return`s**, and gave the `png` case an extra leading term (a force-dark flag the caller passes when retrying after a tray crash). The rewrite therefore captures that whole condition as one opaque group (`[^;]+?` — it contains no semicolon) and reuses it, so upstream can keep changing what feeds the dark/light choice without breaking us. **08a/08b are coupled to the installPhase icon copy** — it globs `TrayIcon*.png` (not just `TrayIconTemplate*`), since a tray image that is merely missing renders blank with no error. Asserted at build time. |
| 09 | _retired (v1.26832.0)_ | Was: append `setTimeout(()=>{},250)` to `X&&(X.destroy(),X=null)` as a "DBus tray cleanup delay". Retired for two independent reasons: the shape is gone (teardown is now `$&&!$.isDestroyed()&&$.destroy(),$=null,…`, which the old regex never matches), **and the payload was inert anyway** — queueing an empty timer does not delay the surrounding synchronous statement. It had no verification grep, so it would have silently no-opped exactly like the patch-18 ASAR-header bug. If an SNI re-registration race ever appears, defer the *recreate*, not the destroy. |
| 11 | `perl -pe` regex | Resolve `shellPathWorker.js` from Claude's asar (not Electron runtime's) |
| 12 | _retired (v1.20186.1)_ | Was: neutralize the two chained `[1m]` model-suffixers whose suffixed id 404s `model_configs` and disabled the Code/LOCAL send button. Upstream no longer force-appends the suffix; `[1m]` survives only in the model *catalog* builders, which expand a 1M-capable model into two selectable entries (`[id, id[1m]]`, `supports_1m_context:!0`) — opt-in, and what the patch always left intact. Patch now asserts no forced suffixer returns. |
| 13 | _retired (v1.13576.4)_ | `getHostPlatform()` now ships a native `linux-x64`/`linux-arm64` branch upstream; patch asserts the branch is present instead of injecting it. |
| 14 | `perl -pe` regex | Restore constructor's `CLAUDE_CODE_LOCAL_BINARY` → `initLocalBinary` wiring (minified into a dead expression in v1.6608.2) |
| 15 | _retired (v1.13576.4)_ | Was: guard `files[process.platform][arch]` throwing `undefined['x64']` on Linux. v1.20186.1 makes **Linux a first-class VM platform key** — a mapper folds both unices into one bucket (`case"darwin":case"linux":return"unix"`) and the manifest ships `files.unix.{x64,arm64}` (a `rootfs.img`), plus a `downloads.claude.ai/vms/linux/<arch>/<sha>` URL builder. The crash is now structurally impossible; patch asserts the linux→unix mapping and the null-platform guard survive. (We still skip the download via patch 04 — see COWORK_PROGRESS.md for the native-Linux-VM opportunity this opens.) |
| 16 | `perl -pe` regex | Guard macOS-fork-only Electron **startup** APIs absent in stock `electron_41` — `systemPreferences.setUserDefault(…)` (darwin-guard) and `app.configureWebAuthn(…)` (existence-guard). Without these the app throws `… is not a function` at module load, before any window opens. |
| 17 | `perl -pe` regex | Guard macOS-only BrowserWindow chrome APIs (`setWindowButtonPosition`, `setHiddenInMissionControl`) via existence checks — these fire during window setup (async), surfacing as unhandled rejections + Sentry spam rather than blocking launch. |
| 18 | staged file + `--unpacked` header entry + installPhase overlay | Linux-native `node-pty`. The DMG ships only macOS Mach-O addons, so the in-app terminal/shell PTY fails to load (`Cannot find module .../pty.node`). node-pty 1.2.x moved to a **prebuildify layout** (`prebuilds/darwin-{x64,arm64}/`), so there is no `build/Release` to overlay. 18a stages the `nodePtyElectron` binary at `extracted/node_modules/node-pty/build/Release/pty.node` and the repack passes `--unpacked node_modules/node-pty/build/Release/pty.node`; 18b drops the same binary into the matching `app.asar.unpacked` path, asserts it is an ELF, **and asserts the packed ASAR header records it as `unpacked` with a matching size**. ⚠️ **An empty `build/Release` directory in the header is not enough** — that was the earlier approach and it silently never worked. Electron redirects a read into `app.asar.unpacked` only when the header holds the *file* entry with `"unpacked": true`; with just `"Release":{}` the require falls through every candidate and throws `Cannot find module './prebuilds/linux-x64/pty.node'` at runtime, with no build-time symptom. `tools/asar_tool.py pack` gained `--unpacked <relpath>` for this (it hard-fails if the path is absent, so a layout change can't drop the entry silently). Verify with `tests/pty-roundtrip`. `build/Release` is **first** in node-pty's search order (`lib/utils.js:loadNativeModule`) and arch-agnostic, so it wins over the darwin prebuilds with no linux-x64/arm64 split. `spawn-helper` is macOS-only (`pty.cc` execs it under `__APPLE__`), left untouched. **`nodePtyElectron.version` must track the node-pty the DMG bundles** — N-API keeps the ABI stable but not node-pty's own JS↔native API, so a mismatched `pty.node` loads fine and then throws on a method the JS expects. This drifted silently in the v1.24012.9 bump (DMG moved to `1.2.0-beta.14`, flake still built `beta.13`), so 18a now **asserts** the extracted `node_modules/node-pty/package.json` version equals the top-level `nodePtyVersion`. On a bump, read the version out of the new DMG and update `nodePtyVersion` + the tarball hash together. |
| 19 | `perl -0777` regex | Bypass the macOS **"disclaimer" spawn helper**. v1.24012.9 routes *every* `spawnAsync` through `<Contents>/Helpers/disclaimer` (macOS calls `responsibility_spawnattrs_setdisclaim` so children aren't attributed to Claude for TCC). The wrapper has **no platform guard** — `getDisclaimerBinaryPath` still carries the vestigial bare `{...}` block where a dead-code-eliminated `if(process.platform==="darwin")` used to be. The helper ships only inside the `.app`, so on Linux every spawn ENOENTs. Visible damage: login-shell env extraction retries 5× then falls back to bare `process.env`, so the user's PATH and exported vars (direnv, nvm, `.zshrc`) never reach Claude Code, MCP servers, or the terminal — a silent degradation, not a crash. Patch makes the wrapper a pass-through on non-darwin. Verify by grepping a launch log for `[CCD] Resolved N login-shell env vars` (good) vs `Shell environment extraction failed` (broken). **Two call sites in two textual shapes** as of v1.26832.0 — minified in a chunk, pretty-printed in `fileIndexWorker.js` (the `shellPathWorker` copy is gone; it was three sites through v1.24012.9) — hence slurp mode. The site list is now *discovered* from the `Helpers`/`disclaimer` path join rather than hardcoded, so upstream dropping a copy is not a build break. The parameter-name backreference is load-bearing: a Windows PowerShell helper elsewhere in the tree also returns `{cmd:…,args:[…]}` and must not be rewritten. **v1.34493.1 changed the fix, and for the better.** Upstream now ships its own no-helper fallback in the wrapper — `if(!t)return{cmd:o.cmd,args:o.args,processGroupLeader:!1}` — so the patch no longer rewrites the wrapper at all. It makes the **resolver** return null on non-darwin and lets that fallback do the work: the same "fix at the loader, not the call site" principle as patches 20 and 21. Three things this buys. The wrapper's return shape had moved every single release (v1.32352.0 added process groups, a third key and a spread-prefix args array); the resolver's `dirname(resourcesPath)` + `join(…,"Helpers","disclaimer")` body has not. The fallback already sets `processGroupLeader:!1`, so that invariant is upstream's to maintain rather than ours to hand-write. And it also covers the **second** wrapper, the `--ports-only` variant, which reads the same resolver and returns its argument unchanged on null — the old call-site patch never touched it. The parameter backreference is gone too, and with it the reason for it: anchoring on the `Helpers`/`disclaimer` path join is inherently unique to this resolver, so the Windows PowerShell helper that also returns `{cmd,args}` is no longer even a candidate. Injection lands inside the vestigial bare `{…}` block; a `return` in a bare block still returns from the function. **`processGroupLeader` must be `!1` on Linux.** It selects the transport class: the process-group one arms a reaper calling `process.kill(-pid)`, which only works if the child really is a group leader — and on macOS it is one only because the helper was invoked with `--pgroup`. With the helper bypassed nothing creates the group, so claiming `true` would give a reaper whose kills silently fail. Consequence, and it is upstream's to give us: MCP server subtrees are not group-reaped on Linux. That capability arrived with this release and has never worked here, because it lives inside a macOS-only binary. |
| 20 | `perl -0777` regex | **Notifications: don't engage the Swift backend on Linux.** `NotificationService.initialize()` picks its backend by truthiness of the Swift addon, and `setupSwiftNotificationHandlers` ends in `m.on("notificationInteraction", …)`. Because the module resolves to `{}` on Linux, the Swift branch is taken and throws `TypeError: e.on is not a function` — an unhandled rejection plus a Sentry event on every launch, while leaving `useSwiftNotifications=true` and no working backend, so desktop notifications never reach the Electron path that *does* work. Patch returns null from the loader, which is what its own catch block does when the module is unavailable. Verify with `NotificationService initialized with Electron notifications` in a launch log (the Swift wording means it regressed). |
| 21 | `perl -0777` regex | **VM module loader: same fix, different subsystem.** The loader does `m.vm=wrapProxy(m.vm)`; with `m={}` that is `new Proxy(undefined,…)` → `[VM] Failed to load module: TypeError: Cannot create proxy with a non-object as target or handler`. Caught and null-returned (the right value) but only via a throw + `captureException`, so every Linux launch shipped a Sentry event for "not macOS". Note the bare `{…}` block wrapping the import inside the `try` — another dead-code-eliminated `if(process.platform==="darwin")`, the same fossil patch 19 found. Cowork is unaffected: its VM instance comes from `global.__linuxCowork` via patches 05/06a, never from this module. |
| 22 | Append IIFE | **Linux single-instance + `claude://` deep-link delivery.** Fixes #52 and #57; ported from PR #53 (thanks @stuckj), renumbered from that PR's "20" and re-anchored off the retired `$INDEX`. v1.24012.9 dropped the non-darwin arm of the deep-link setup, so the app now registers `open-url`, `will-continue-activity` and `continue-activity` unconditionally — all three macOS-only. `requestSingleInstanceLock` and `second-instance` are absent from the whole tree, and there is no cold-start argv scan for the scheme. On Linux every `xdg-open` of `claude://` therefore starts a **second full app** against one `--user-data-dir` with the URL sitting unread in its argv; since the in-process auth path (`ASWebAuthenticationSession`) is macOS-only, **OAuth sign-in cannot complete at all** — each attempt opens another window still showing the login screen. `scripts/linux-deep-link.js` restores the missing arm. It does not reimplement dispatch: the app's own `open-url` listener already owns mainView readiness, the pending-URL stash and window focus, so the patch re-emits that event and lets the app work. Appended (there is no surviving call site to rewrite — the arm is gone, not renamed) to `index.js`, for the same reason patch 01 is: it is the entry that requires every chunk, so it runs after the app's listeners exist but before `ready`, the only window in which `requestSingleInstanceLock()` is still useful. **`app.exit(0)`, not `app.quit()`, for the instance that loses the lock** — by append time the app has registered its `onQuitCleanup` handlers, and `quit()` runs them, including `flush-web-storage` and `plan-usage-history`, which write into the profile the *primary* owns; the argv handoff already completed inside `requestSingleInstanceLock()`, so exiting immediately loses nothing. **The listener assertion must accept a backtick** (`app.on(` + backtick + `open-url`): this build minifies every string to a template literal, and PR #53's double-quote-only grep would have failed here. The second assertion — `requestSingleInstanceLock` must be *absent* before appending — is the drop-this-patch tripwire for when upstream restores the arm itself. |

> **Custom Electron fork:** Anthropic's macOS build runs a patched Electron with extra native `app`/`systemPreferences`/`BrowserWindow` methods. Stock nixpkgs `electron_41` lacks them, so each top-level call to one throws on Linux. Patches 16–17 guard the ones hit on the launch path; if a future version adds more, the symptom is `TypeError: X.<method> is not a function` at startup — add an existence/darwin guard following the same pattern.

> **`@ant/claude-native` keeps growing:** the same symptom (`TypeError: X.<method> is not a function`) also appears when the app starts calling a *new* method on the native module we stub. v1.20186.1 added the safe-fs containment API this way; v1.26832.0 added the DeviceRegistry hardware key; v1.32352.0 added `readProcessFootprints`. v1.34493.1 added none — the invoked set is unchanged, which is worth re-checking each bump rather than assuming (enumerate the methods called on the `require("@ant/claude-native")` binding and diff against the stub's exports). When it happens, find the call site in the chunk, derive the contract from how the return value is consumed (e.g. `fs.close(x)` ⇒ raw fd, not a FileHandle), and implement it in `modules/enhanced-claude-native-stub.js` — don't just return a no-op, since the app may guard against exactly that.
>
> **This class of bug is invisible to every automated check we have,** and the two instances found so far needed *different* kinds of session to surface. The DeviceRegistry break lives behind renderer IPC and needed a **signed-in** session doing real work. `readProcessFootprints` is on a **once-a-minute timer**, so a 60-second headless run misses it entirely — it took a 15-minute session to accumulate 15 identical `TypeError`s. Neither produced a Sentry event or an `[error]` line. Budget one long, signed-in, interactive launch per bump, then read the whole log.

### Process footprints (v1.32352.0)

`readProcessFootprints(pids)` feeds the `[process-memory]` sampler, which runs on an
interval. Its guard is `if (!nativeModule) return nulls` — a bare truthiness test our
stub passes — so a missing method throws every tick, is caught, and degrades to
`children=unavailable`.

Contract, derived from the consumer:

- returns a **real Promise** (the caller does `.finally()` on it immediately)
- resolves to an **array parallel to `pids`**; each element is `null` or `{ footprintBytes, commitBytes }`
- must **never** resolve to the string `"timeout"` — that is the caller's 5s race sentinel

macOS reports `phys_footprint`; the honest Linux analogue is RSS. Read it from
`/proc/<pid>/status` (`VmRSS`, in kB) rather than `/proc/<pid>/statm`, which counts
**pages** and would need the page size — not 4096 everywhere this flake builds, since
aarch64 kernels commonly use 16K or 64K. `commitBytes` stays `null`: Linux has no clean
equivalent of the macOS/Windows commit charge, the consumer explicitly tolerates null,
and inventing a mapping would put wrong numbers into telemetry.
Covered by `tests/process-footprints.test.js`, which cross-checks the value against
`process.memoryUsage().rss` and asserts a path-shaped pid can never reach `/proc/<pid>/`.

### `procps` is required in the FHS env (v1.32352.0)

The app shells out to `ps` and `pgrep`, and neither was in `targetPkgs`. Three things
broke silently, all caught by empty `catch` blocks:

| Call | Consequence when it fails |
|---|---|
| `ps` (child enumeration) | `[process-memory] children=unavailable(ps-failed)` — telemetry only |
| `ps -o pgid= -o tpgid= -p <pid>` | bash PTY foreground/busy detection always reports "no busy shells" |
| `pgrep -P <pid>` | the **recursive process-tree killer** walks no children, so only the root is SIGKILLed and grandchildren are orphaned |

The third is the serious one, and it partially compensates for the process-group reaping
we cannot have (see patch 19). When auditing a bump, grep the bundle for spawned tool
names and check each against the FHS rootfs — `ls $ROOTFS/usr/bin/<tool>`. The other
`pgrep` call sites are darwin-gated (iOS Simulator, macOS app detection) and irrelevant.

### DeviceRegistry hardware key (v1.26832.0)

`DeviceRegistry.signAttestationPreimage` calls `hardwareKeyGetOrCreate(alias)` / `hardwareKeySign(alias, data)` on the native module. Missing them throws
`TypeError: r.hardwareKeyGetOrCreate is not a function` **on a retry loop**, and the app cannot fall back — the DEV software-key escape hatch is compiled out of release builds (its guard minifies to a literal `function $(){return!1}`).

The contract is pinned by how the values are consumed, not by any signature we can see:

| Method | Must return |
|---|---|
| `hardwareKeyGetOrCreate(alias)` | `{ isHardwareBacked, publicKeySpki }` — `publicKeySpki` a **Buffer of DER SPKI** (the app calls `.toString("base64")` on it) |
| `hardwareKeySign(alias, data)` | **Buffer, DER ECDSA signature** |

The signature encoding is the strict part: the app pipes it through a hand-written DER parser that requires `SEQUENCE{INTEGER r, INTEGER s}` with each integer 1–33 bytes, then left-pads to 32 to build P1363. So the curve must be **P-256** and the encoding **DER** — Node's `dsaEncoding:'ieee-p1363'` is rejected outright. Set `dsaEncoding` explicitly rather than relying on the default.

`isHardwareBacked: false` is reported **honestly, and must stay that way.** The app models exactly this state, tagging the device `software_shim` (vs `hardware_backed` / `unavailable`) and exposing a `no_tpm` availability reason. Claiming `true` would misreport the device's security posture to the server to buy a server-side behaviour — don't.

The key is **persisted** under `userData/device-keys/<sha256(alias)>.pem`, `0600` in a `0700` dir, created with `O_EXCL`. A per-launch key would defeat the point of a device registry. The alias is hashed rather than sanitized because it is caller-supplied and reaches a filename.

Covered by `tests/device-key.test.js`, which drives the **real stub module** (with a faked `electron`) and re-implements the app's DER parser verbatim to assert against it — 200 rounds, because short-`r`/short-`s` DER padding only appears intermittently.

**Known-remaining, not ours:** with the key in place the flow gets one step further and logs, once,
`DeviceRegistry: device not registered (no row-PK for this account)` from `signCreateSessionBind`. That is a local/server registration lookup returning nothing, not a missing native method. Whether the server will register a `software_shim` device is Anthropic's policy call — do not "fix" it by faking hardware backing.

## Electron Gotchas

- **Nix eats `$`-brace pairs anywhere in `buildPhase`, including shell comments.** The
  `''`-string lexer looks for the interpolation opener with no idea what a `#` comment
  is, so a regex or an explanatory comment containing one fails the build with
  `syntax error, unexpected invalid token` pointing at the comment. Write the brace as a
  character class (`\$[{]`) so the pair never appears literally — that also keeps the
  regex readable, unlike `''${`. Note `\$\{` is *fine* (the `$` is followed by a
  backslash, so there is no pair), which is why the pre-existing patch-12 grep worked.
- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **ASAR unpacked files are a header contract, not a filesystem one.** `extract` *skips* files marked `unpacked` and keeps only their directories, so a plain repack loses every such entry — the header ends up with `"Release":{}`, `"darwin-x64":{}` and so on. Anything that must be reachable at `<asar>/…` but live on the real filesystem (native addons) needs `pack --unpacked <relpath>`, which emits `{"size":N,"unpacked":true}`. The upstream darwin prebuild entries are still dropped by our repack; that is inert on Linux (node-pty only probes `prebuilds/linux-x64`), but don't assume any other unpacked file survives a round-trip.
- **App caching**: Kill all processes before testing — but **not** with a bare `pkill -f claude-desktop`: that pattern also matches the shell command running it, killing your own session. Match the binary path instead.
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Testing Gotchas

- **Never launch a test build against the real `~/.config/Claude`.** On startup the app "preseeds" a pinned `claude-code` build into `~/.config/Claude/claude-code/<version>/` (v1.34493.1 pins 2.1.237; v1.32352.0 pinned 2.1.229; v1.26832.0 pinned 2.1.222; v1.24012.9 pinned 2.1.219; v1.20186.1 pinned 2.1.205; v1.13576.4 pinned 2.1.177) and writes a `.verified` marker holding the *manifest's expected checksum* — not a hash of the file. A test launch therefore mutates real user state, and an app version expecting a different pin reports **"The Claude Code binary is missing or damaged."** Run headless tests with an isolated `HOME`, copying in `.config/Claude/claude-code` to skip the 257 MB download.
- **Headless launch**: `HOME=$tmp xvfb-run -a ./result/bin/claude-desktop`; surviving a `timeout` (exit 124) is the pass signal. Grep the log for `is not a function`, `Cannot find module`, `UnsafeRootError`.
- **Two harness traps produce a fake failure (exit 139 / SIGSEGV), not an app bug:**
  1. `XDG_RUNTIME_DIR` must be **short**. A unix socket path is capped at 108 bytes, and the Wayland socket lives under it — a deep scratchpad path makes Ozone abort with `socket path … exceeds 108 bytes` before any window opens. Use something like `/tmp/cdt-$$`.
  2. The wrapper passes `--ozone-platform-hint=auto`, so an inherited `WAYLAND_DISPLAY` makes it prefer the *host's* Wayland session over Xvfb's X server and then fail. Clear the session vars: `env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_SESSION_TYPE`.
- **Read the log even when the exit code is 124.** v1.24012.9's disclaimer regression (patch 19) never crashed anything — it logged a warning, retried, and silently degraded. A pass/fail exit code would have shipped it.
- Expected-and-benign in a headless log: `accountId=null, orgId=null` (not signed in), `[wake-scheduler] DEV BUILD` (macOS LaunchDaemon), `@ant/claude-swift unavailable` (macOS pressure telemetry), `[Bundle:status] rootfs.img missing` (patch 04 skips the download), and no tray lines at all (Xvfb has no StatusNotifier host). Also benign, and easy to mistake for ours: a burst of `Blocked permission check` warnings for `background-sync`/`sensors`/`payment-handler`/`notifications` with `requestingOrigin: https://newassets.hcaptcha.com`. That is the app's **own** permission handler denying the hCaptcha iframe on the login page — upstream policy working, and it only appears because a signed-out launch renders that page.
- One `getInitialLocale … did not pass origin validation` at startup is **upstream**, not ours. The guard is `senderFrame?.parent === null` — pure frame topology, nothing to do with our paths — and it races frame commit. Do not "fix" it: it is a renderer-origin security check, and weakening it to quiet one log line is a bad trade.
- **A green `nix build` is not a working app.** Every regex patch self-verifies, so the build catches *missing* patches — it cannot catch a patch that applies cleanly and names a file that isn't installed (see 08a/08b ↔ icon copy), or a native addon that loads but exports nothing. Launch it.
- **A signed-out headless launch is not a working app either.** Some subsystems are only reachable over IPC from a signed-in renderer doing real work. The v1.26832.0 DeviceRegistry break (missing `hardwareKeyGetOrCreate`) produced 17 `TypeError`s in an IPC handler while the headless test stayed completely green — 0 Sentry events, no fatal patterns, exit 124. Budget one interactive, signed-in session per bump, against an **isolated `HOME`** with the real Wayland/DBus session inherited (that also exercises the tray, which Xvfb cannot host), then read the log.
- **A clean launch is not a working app either.** Subsystems that fail are frequently caught, logged, retried, and degraded — the window still opens. Both v1.24012.9 regressions behaved this way: the disclaimer bug logged a warning and fell back to a bare env, and the missing ASAR `unpacked` entry only threw when something actually opened a terminal. Exercise the feature:
  - `node tests/branding-fix.test.js` — patch 07 stays scoped to chrome (issue #40).
  - `node tests/device-key.test.js` — the DeviceRegistry key contract (patch 00).
  - `node tests/process-footprints.test.js` — the process-footprint contract (patch 00).
  - `tests/pty-roundtrip` — patch 18 addon resolves, spawns, resizes, exits (see its README).
  - `tests/deep-link` — patch 22: lock held, second instance hands off and exits, URL reaches the app's `open-url` listener (see its README). Run its **negative control** too — `CDT_SCRIPT_OVERRIDE` pointed at an empty file must produce three FAILs. A test for a silent-no-op bug that passes with the fix removed is testing nothing.
  - Grep a launch log for `[CCD] Resolved N login-shell env vars`; `Shell environment extraction failed` means patch 19 regressed.
  - **Deep links (patch 22).** `ls $HOME/.config/Claude/Singleton*` must show a `SingletonLock`/`SingletonSocket` after launch — their absence is the patch-22 regression, and it is silent. Then launch a second instance with a `claude://` argv: it must exit 0 **without opening a window**, and the primary must act on the URL. This is the only check that covers issues #52/#57; a signed-out headless run cannot see it, because the damage is that a *second* process starts.
  - Grep for `NotificationService initialized with Electron notifications`. The Swift
    wording means patch 20 regressed and notifications are silently dead.
  - **Count Sentry events: `grep -c 'Sentry caught' log` must be 0.** This is the
    highest-value single check in the list. Both v1.26832.0 regressions (patches 20 and
    21) were caught exceptions that logged, degraded, and let the window open normally —
    invisible to the exit code and to every grep above, but each fired a Sentry event.
    A non-zero count is a subsystem that failed and gave up.

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
