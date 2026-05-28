# Cowork on Linux - Progress Report

## Current Status: v1.9255.2 — Cowork + Code/LOCAL Functional

Cowork is running on Linux via a fully declarative Nix flake. Claude Code spawns inside Cowork sessions, processes messages via the SDK wire protocol, streams responses, and persists transcripts across app restarts.

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
12. **Code section → LOCAL mode** (opt-in via `programs.claude-desktop.claudeCodePackage`): uses CCD's official `CLAUDE_CODE_LOCAL_BINARY` escape hatch to short-circuit the `getHostPlatform` throw, combined with patch 12 to neutralize the `[1m]` GrowthBook feature flag that 404s model config requests. Send button functional; sessions spawn directly on the host without VM.

### Known Limitations

- **No bubblewrap sandboxing**: Claude Code runs directly on the host, not inside a sandbox. NixOS paths are incompatible with simple bwrap bind-mounts.
- **Executable file preview blocked**: `.sh`, `.exe` etc. can't be opened in UI preview — upstream security behavior, not Linux-specific.
- **Plugin permission shim**: `cowork-plugin-shim.sh` is now provided in the asar resources. The shim permission bridge starts and mounts `.cowork-lib`, `.cowork-perm-req`, `.cowork-perm-resp` into sessions.
- **Find-in-page preload origin error**: Cosmetic — `DesktopIntl` origin allowlist doesn't recognize `file:///nix/store/` paths. Falls back to default English locale; in-app Ctrl+F search may be affected.
- **`BuddyBleTransport.reportState`**: Bluetooth IPC handler not registered on Linux. Fires once at startup; harmless.
- **In-app Code section → LOCAL mode** requires opt-in: set `programs.claude-desktop.claudeCodePackage = <claude-code package>` (e.g. `pkgs.claude-code` or `inputs.claude-code.packages.${system}.default`). Without this, the Electron process has no `CLAUDE_CODE_LOCAL_BINARY` set, so CCD falls back to its built-in `getHostPlatform` path which still throws on Linux (producing polling-loop log noise but not crashing the app). The earlier `undefined.includes()` and `model_configs/[1m]` 404 blockers are resolved by patch 12 regardless. **SSH / Cloud Environment / Remote-control modes** continue to work (bypass CCD entirely).

## Architecture

### Patch Chain (v1.9255.2)

All patches use version-resilient `\w+` (or `[\w\$]+` where minified names contain `$`) regex wildcards for minified identifiers. Function names are discovered at build time, not hardcoded.

| # | Method | Purpose |
|---|--------|---------|
| 00 | File copy | Electron API stubs for Linux (`@ant/claude-native`) |
| 01 | Append IIFE | Load Cowork module |
| 02 | `perl -pe` regex | Route Linux through VM path (platform flag) |
| 03 | `perl -pe` regex | Return "supported" for Linux availability |
| 04 | `perl -pe` regex | Skip macOS VM bundle download |
| 05 | Node.js dynamic | Create Linux session at VM start (spawn, writeStdin, mounts, path translation) |
| 06 | `perl -pe` regex | Return Linux VM instance from getters |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" |
| 08 | `perl -pe` regex | Use theme-aware PNGs for tray icon |
| 09 | `perl -pe` regex | DBus tray cleanup delay for stability |
| 11 | `perl -pe` regex | Resolve `shellPathWorker.js` from Claude's asar (not Electron runtime's) |
| 12 | `perl -pe` regex | Neutralize `[1m]` model-suffix (GrowthBook flag `3885610113`); unblocks Code/LOCAL send button |
| 13 | `perl -pe` regex | `getHostPlatform()` returns `linux-x64`/`linux-arm64` instead of throwing |
| 14 | `perl -pe` regex | Restore constructor's `CLAUDE_CODE_LOCAL_BINARY` → `initLocalBinary` wiring |
| 15 | `perl -pe` regex | Make VM bundle file lookup return `[]` on Linux instead of throwing in `ClaudeVM.getDownloadStatus` |

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

1. Investigate bubblewrap sandboxing (requires Nix store bind-mounts)
2. Patch `DesktopIntl` origin allowlist to accept `file:///nix/store/` paths (would fix find-in-page preload + locale init)
3. Silence CCD polling-loop log noise when `claudeCodePackage` is unset — cheap stub returning `{status: "unsupported"}` from the IPC handler

---

**Last Updated**: 2026-05-28
**Claude Desktop Version**: 1.9255.2
