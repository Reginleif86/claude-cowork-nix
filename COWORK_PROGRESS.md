# Cowork on Linux - Progress Report

## Current Status: v1.13576.4 — Cowork + Code/LOCAL Functional

Cowork is running on Linux via a fully declarative Nix flake. Claude Code spawns inside Cowork sessions, processes messages via the SDK wire protocol, streams responses, and persists transcripts across app restarts. Validated end-to-end on v1.13576.4 (live session: healthy agent cycle, turn succeeded).

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
11. **Shell PATH augmentation**: shellPathWorker resolves login-shell env vars into the app process (`[CCD] Resolved N CC env vars from login shell`)
12. **Code section → LOCAL mode**: works on Linux without any opt-in. As of v1.13576.4 `getHostPlatform()` returns `linux-x64`/`linux-arm64` natively (no throw), and CCD downloads/uses its own Linux `claude` binary (`~/.config/Claude/claude-code/<ver>/claude`). Patch 12 neutralizes the `[1m]` model-suffix that 404s model config requests, keeping the send button functional. `programs.claude-desktop.claudeCodePackage` is now an optional **override** (pin a specific `claude-code`) rather than a requirement.

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

1. Investigate bubblewrap sandboxing for the agent process (requires Nix store bind-mounts)
2. Patch `DesktopIntl` origin validation to accept the renderer's `file://app:///` origin (would fix find-in-page preload + locale init)

---

**Last Updated**: 2026-06-18
**Claude Desktop Version**: 1.13576.4
