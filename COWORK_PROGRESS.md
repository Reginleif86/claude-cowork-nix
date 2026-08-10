# Cowork on Linux - Progress Report

## Current Status: v1.26832.0 — Cowork + Code/LOCAL Functional

Cowork is running on Linux via a fully declarative Nix flake. Claude Code spawns inside Cowork sessions, processes messages via the SDK wire protocol, streams responses, and persists transcripts across app restarts.

**v1.26832.0 bump** — the loudest structural bump so far. Two independent, simultaneous changes broke nearly the whole chain, and a third class of bug was found by launching rather than building:

- **The main process shattered.** `index.js` went from an ~800-byte stub with one `require()` to a 242 KB module requiring 159 of ~350 chunks, and the patch targets scattered across at least seven files. "Resolve the first require" — the discovery rule since v1.20186.1 — now lands on an unrelated 1.7 KB chunk. Patches are keyed on **anchors** now: `apply_patch` greps the tree, rewrites every file holding the anchor, and fails if the anchor is missing or the rewrite lands nowhere. Upstream re-chunking is a no-op for us from here.
- **The minifier changed shape twice over.** Every string literal became a backtick template literal, and `const` became `let`. That alone broke every regex matching a quoted string — i.e. all of them except patch 14, the only one that matches no string literal. Regexes now use ``[`"]`` and `(?:const|let)` throughout so a flip back costs nothing.
- **`{}` is truthy — two subsystems silently ran their macOS backend on Linux.** `@ant/claude-swift` exports `{}` on non-darwin, so `await import(...)` *succeeds* and every upstream `if (swiftModule)` check passes. The notification service took the Swift branch and threw `TypeError: e.on is not a function` (**patch 20**), leaving `useSwiftNotifications=true` with no working backend — desktop notifications never reached the Electron path that works on Linux. The VM module loader did `new Proxy(undefined, …)` and threw `Cannot create proxy with a non-object as target or handler` (**patch 21**). Both were *caught*: the window opened normally, the exit code was clean, and every existing grep passed. They showed up only as two Sentry events per launch. Sentry-event count is now a documented test signal, and it is 0.
- **Patches 06b and 09 retired.** 09's pattern is gone upstream *and* its payload was inert (an empty `setTimeout` delays nothing). 06b widened a getter that may only ever return null or a real EventEmitter — on Linux the module is `{}`, which is neither; with patch 21 the getter yields null either way, so the widening was provably dead. Both had the same failure mode the repo keeps hitting: a patch that applies (or silently doesn't) while doing nothing.
- **Post-patch syntax sweep.** All 357 build files are `node --check`ed after patching. A brace-mangling regex greps clean and only fails at runtime, inside a subsystem that may well catch and degrade.
- **Patch 19 site count changed** (3 → 2; the `shellPathWorker` copy is gone) and **patch 05's signature drifted** (`var` → `let` declarations, dotted status-dispatch enum). Both are now discovered rather than hardcoded.
- `claude-code` pin moved 2.1.219 → **2.1.222**. node-pty stayed at `1.2.0-beta.14`.

Validated on v1.26832.0: clean headless launch (exit 124), **0 Sentry events**, `NotificationService initialized with Electron notifications`, `[CCD] Resolved 47 login-shell env vars`, Cowork initialized via bubblewrap 0.11.0, full PTY round-trip green (`tests/pty-roundtrip`), branding-fix DOM tests green (13/13), `nix flake check` green. Remaining log noise is the documented benign set (logged-out `accountId=null`, `[wake-scheduler] DEV BUILD`, `@ant/claude-swift unavailable` pressure telemetry, hCaptcha permission denials on the login page).

Not re-verified this round (needs an interactive signed-in session, not headless): Cowork session creation end-to-end, directory picker, MCP-in-session, transcript persistence.

**v1.24012.9 bump** — structurally quiet (every regex patch applied unchanged), but testing the *features* rather than the build surfaced three silent breakages, one of them pre-existing:

- **All 17 regex patches applied unchanged.** The main process is now split into ~95 chunks (was 1), but `index.js` still requires a single entry chunk holding every patch target, so the existing discovery logic handled it with no edits.
- **New patch 19 — the macOS "disclaimer" spawn helper.** Upstream now routes *every* `spawnAsync` through `<Contents>/Helpers/disclaimer` (macOS TCC responsibility disclaiming) with **no platform guard**; the helper only exists inside the `.app`, so on Linux every spawn ENOENTs. It never crashed — login-shell env extraction just retried 5× and fell back to bare `process.env`, so the user's PATH and exported vars (direnv, nvm, `.zshrc`) silently never reached Claude Code, MCP servers, or the terminal. Fixed; a launch log now shows `[CCD] Resolved 47 login-shell env vars` where it previously showed `Shell environment extraction failed`.
- **node-pty version drift.** The DMG moved to `1.2.0-beta.14` while the flake still built `beta.13`. N-API keeps the ABI stable, so the mismatched addon would have loaded fine and then thrown on the first method the bundled JS called. Patch 18a now **asserts** the two match at build time, so this can't drift silently again.
- **The in-app terminal was broken — and had been.** Chasing the node-pty bump with a real round-trip test surfaced that the `pty.node` overlay was never reachable: patch 18a reserved an *empty* `build/Release` directory in the ASAR header, but Electron only redirects a read into `app.asar.unpacked` when the header carries the **file** entry with `"unpacked": true`. With `"Release":{}` the require fell through every candidate and threw `Cannot find module './prebuilds/linux-x64/pty.node'`. The binary was on disk the whole time; nothing could reach it. `asar_tool.py pack` gained `--unpacked <relpath>`, 18b now asserts the header entry and its size, and `tests/pty-roundtrip` exercises spawn → write → read → resize → exit. This is why the earlier "PTY round-trip validated" claim should be treated as unverified for v1.20186.1.
- **Issue #40 fixed (patch 07).** The branding relabel observed the whole document with `characterData:true`, so it rewrote user input and streamed model output — typing "for Windows" in the composer mutated it mid-keystroke. Now scoped to chrome: `childList` only, content subtrees pruned, long text ignored. Covered by `tests/branding-fix.test.js`.
- **PTY moved to its own utility process** (`pty-host/ptyHostWorker.js`). Its path resolver branches on `app.isPackaged` and falls back to `app.getAppPath()`, which is already correct under our wrapper — no patch needed.
- `claude-code` pin moved 2.1.205 → **2.1.219**.

Validated on v1.24012.9: clean headless launch (exit 124, no `is not a function` / `Cannot find module` / `UnsafeRootError`), `[CCD] Resolved 47 login-shell env vars`, Cowork initialized via bubblewrap 0.11.0 with the VM module loaded, full PTY round-trip green (`tests/pty-roundtrip`: resolve → spawn → write/read → resize → exit code), branding-fix DOM tests green, `nix flake check` green.

Not re-verified this round (needs an interactive signed-in session, not headless): Cowork session creation end-to-end, directory picker, MCP-in-session, transcript persistence.

**v1.20186.1 bump** — this release changed more structurally than any previous bump:

- **Main process is code-split.** `.vite/build/index.js` became an ~800-byte stub that requires `index.chunk-<hash>.js`; the entry point moved to `index.pre.js`. Every regex patch targeted `index.js`, so all of them "failed" at once. The build now discovers the chunk from index.js's `require()` (see CLAUDE.md → *Where the patches land*). The regexes themselves were almost all still correct.
- **New hard requirement: safe-fs containment.** The app now routes contained file access (document baselines, scratch roots) through `openRootDir`/`openBeneath`/`mkdirBeneath`/`renameBeneath`/`unlinkBeneath` on `@ant/claude-native`, and **refuses to fall back to path-based opens** (CC-2885) — it throws `UnsafeRootError` at startup instead. Implemented in the Linux stub (patch 00); 12 unit tests cover the contract, including symlink-escape containment.
- **node-pty moved to a prebuildify layout** (`prebuilds/darwin-*/`) — patch 18 was reworked, and `nodePtyElectron` now tracks the bundled node-pty version.
- **Upstream is warming to Linux.** Two patches got *retired* because upstream fixed the underlying issue, and one because the crash became structurally impossible:
  - Patch 12 (`[1m]` model suffix) — the forced suffixing is gone; `[1m]` is now an opt-in catalog entry.
  - Patch 15 — Linux is now a **first-class VM platform key**: `case"darwin":case"linux":return"unix"`, with a `files.unix.{x64,arm64}` manifest shipping a `rootfs.img`, and a `downloads.claude.ai/vms/linux/<arch>/<sha>` URL builder.
  - Tray icons: the DMG now ships real `TrayIconLinux{,-Dark}.png` assets and a GNOME-aware selection branch (patch 08b now delegates to it rather than inventing its own).

Validated on v1.20186.1: clean headless launch (no `is not a function` / `Cannot find module` / `UnsafeRootError`), Cowork session created (`VM instance ready`), `nix flake check` green. ⚠️ This section previously also claimed a PTY round-trip; that claim was **wrong** — the v1.24012.9 work proved the `pty.node` overlay was unreachable through the ASAR (see the missing `unpacked` header entry above), so the in-app terminal was broken on v1.20186.1 too.

### What Works

1. **Cowork end-to-end**: Session creation, Claude Code spawn, SDK handshake, MCP initialization, streaming responses
2. **Multi-turn conversations**: Sessions stay alive across multiple messages
3. **Session continuity**: Conversations persist and can be resumed after app restart
4. **File operations**: Read, write, and edit work via Claude Code's tools
5. **Directory picker**: Native folder picker works, directories mount correctly via symlinks
6. **VM path resolution**: `/sessions/<name>/mnt/...` paths resolve correctly inside FHS environment
7. **Transcript persistence**: Chat history written to desktop app's session storage
8. **MCP servers**: Initialize and function within Cowork sessions
9. **Persistent auth tokens**: `--password-store=gnome-libsecret` (KDE Wallet, GNOME Keyring)
10. **NixOS + Home Manager modules**: `programs.claude-desktop.enable`
11. **Shell PATH augmentation**: shellPathWorker resolves login-shell env vars into the app process (`[CCD] Resolved N login-shell env vars`). Requires **patch 19** as of v1.24012.9 — without it the spawn goes through the macOS-only disclaimer helper, fails ENOENT, and silently falls back to a bare `process.env`.
12. **Code section → LOCAL mode**: works on Linux without any opt-in. `getHostPlatform()` returns `linux-x64`/`linux-arm64` natively (no throw), and CCD preseeds/uses its own Linux `claude` binary (`~/.config/Claude/claude-code/<ver>/claude` — v1.24012.9 pins 2.1.219). The `[1m]` model-suffix that used to 404 model-config requests and disable the send button is gone upstream, so patch 12 is retired. `programs.claude-desktop.claudeCodePackage` is an optional **override** (pin a specific `claude-code`) rather than a requirement.
13. **In-app terminal / shell PTY**: Linux-native `pty.node` built against `electron_41.headers`, matching the bundled node-pty version, and reachable through the ASAR via an `unpacked` header entry (patch 18). Covered by `tests/pty-roundtrip`.

### Known Limitations

- **No bubblewrap sandboxing for the agent process**: the main Claude Code process spawns directly on the host via `child_process.spawn` (`patch-vm-start.js`), not inside a sandbox — NixOS paths are incompatible with simple bwrap bind-mounts. Ad-hoc `exec`/`executeCommand` calls do go through `spawnSandboxed` (bwrap).
- **Executable file preview blocked**: `.sh`, `.exe` etc. can't be opened in UI preview — upstream security behavior, not Linux-specific.
- **Plugin permission shim**: `cowork-plugin-shim.sh` is provided in the asar resources. The shim permission bridge starts and mounts `.cowork-lib`, `.cowork-perm-req`, `.cowork-perm-resp` into sessions.
- **Find-in-page preload origin error**: Cosmetic — `DesktopIntl` origin validation rejects the renderer's `file://app:///…` origin (`getInitialLocale` call). Pre-existing upstream behavior (present in earlier versions too), not introduced by the Linux port. Falls back to default English locale; in-app Ctrl+F search may be affected.
- **`BuddyBleTransport.reportState`**: Bluetooth IPC handler not registered on Linux. Fires once at startup; harmless.
- **"Claude for Windows" on the pre-login screen**: cosmetic. That screen is claude.ai's remote login page, which labels the desktop app by User-Agent and has no Linux branch (non-Mac → "Windows"). Kept as-is to preserve the genuine Linux UA; not fixable locally without UA spoofing.

**No longer a limitation (resolved in v1.13576.4):**
- *Code/LOCAL mode no longer requires `claudeCodePackage`.* `getHostPlatform()` now returns a Linux value natively (no throw → no polling-loop log noise), and CCD provisions its own Linux `claude` binary. SSH / Cloud Environment / Remote-control modes also continue to work.
- *node-pty terminal fixed.* The in-app terminal/shell PTY previously failed (`Cannot find module …/pty.node`, macOS-only binary); patch 18 overlays a Linux-native `pty.node` built against `electron_41.headers`.

## Architecture

### Patch Chain

All patches use version-resilient `\w+` (or `[\w\$]+` where minified names contain `$`) regex wildcards for minified identifiers. Function names are discovered at build time, not hardcoded.

The authoritative, up-to-date patch table lives in **`CLAUDE.md`** (`## Patch Chain`). v1.13576.4 highlights: patches **02 / 13 / 15 are retired** (upstream now handles these natively; the patches assert the upstream condition so a regression fails loudly), patches **03 / 08b / 12** got new regexes for the refactor, and patches **16 / 17 / 18** were added (guard macOS-fork-only Electron startup + window APIs; overlay a Linux-native node-pty `pty.node`).

### Session Flow

```
User sends message in Cowork UI
  → Sessions bridge creates session + environment
  → VM start function creates Linux vmInstance (patch 05)
  → Process manager calls vm.spawn() with command, args, cwd, env, mounts
  → spawn resolves claude binary, creates mnt/ symlinks, fixes env
  → Claude Code starts, SDK handshake + MCP init via stream-json stdin
  → User message processed, response streamed back
  → Transcript persisted to desktop app's session storage
```

### Session Directory Structure

```
/sessions/<name>/                     (symlink via FHS bwrap)
  → /tmp/sessions/<name>/             (symlink created at spawn)
    → /tmp/claude-cowork-sessions/<sessionId>/sessions/<name>/
       ├── mnt/
       │   ├── .claude  → desktop app session .claude dir
       │   ├── outputs  → desktop app session outputs dir
       │   ├── uploads  → desktop app session uploads dir
       │   └── Documents → /home/user/Documents (user-selected)
```

### Linux VM Instance Interface

| Method | Purpose |
|--------|---------|
| `spawn(id, name, cmd, args, cwd, env, mounts, ...)` | Spawn Claude Code with resolved paths and fixed env |
| `writeStdin(id, data)` | Write newline-terminated JSON to process stdin |
| `kill(id, signal)` | Kill a spawned process |
| `mountPath(processId, subpath, mountName, mode)` | Create directory for VM mount point |
| `readFile` / `writeFile` / `mkdir` / `rm` | File I/O with `/sessions/` path translation |
| `setEventCallbacks(stdout, stderr, exit, error)` | Forward process events to session manager |

## Next Steps

1. **Evaluate upstream's native Linux VM path.** v1.20186.1 maps `linux` to the `unix` bundle key, ships a `files.unix.{x64,arm64}` `rootfs.img` manifest, and builds `https://downloads.claude.ai/vms/linux/<arch>/<sha>` download URLs. That suggests Anthropic is provisioning a real Linux Cowork VM. We currently skip the download (patch 04) and substitute a bubblewrap-backed session (patch 05/06). If the upstream path works, much of patches 03–06 could be replaced by letting it run — and it would likely bring real sandboxing (item 2) with it. Worth probing before adding more emulation.
2. Investigate bubblewrap sandboxing for the agent process (requires Nix store bind-mounts)
3. Patch `DesktopIntl` origin validation to accept the renderer's `file://app:///` origin (would fix find-in-page preload + locale init)

---

**Last Updated**: 2026-08-10
**Claude Desktop Version**: 1.26832.0
