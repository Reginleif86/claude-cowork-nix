# claude-cowork-nix

Enabling macOS-only Claude Desktop features on Linux via runtime patching.

## Architecture

- **Source**: macOS DMG fetched via `fetchurl` (currently v1.3109.0 — tracked by github-actions auto-update)
- **Extraction**: `7zz` (native LZFSE support) + `asar_tool.py`
- **Runtime**: `electron_41` from nixpkgs
- **Packaging**: Nix flake with `makeWrapper` + `buildFHSEnv`

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
| 12 | `perl -pe` regex | Neutralize `[1m]` model-suffix feature flag (GrowthBook `3885610113`) — unblocks Code/LOCAL send button |
| 13 | `perl -pe` regex | `getHostPlatform()` returns `linux-x64`/`linux-arm64` instead of throwing — fixes Cowork chat error in v1.6608.x |
| 14 | `perl -pe` regex | Restore constructor's `CLAUDE_CODE_LOCAL_BINARY` → `initLocalBinary` wiring (minified into a dead expression in v1.6608.2) |

## Electron Gotchas

- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **App caching**: Kill all processes with `pkill -f claude-desktop` before testing
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
